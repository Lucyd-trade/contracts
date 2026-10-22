// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SettlementOrderHashing, SettlementOrderV1} from "./SettlementOrderHashing.sol";
import {SafeMath} from "./libraries/SafeMath.sol";
import {IERC20Settlement, IOutcomeBalances} from "./interfaces/ISettlementAssets.sol";

/// @notice Operator-submitted atomic settlement of signed binary-outcome matches.
/// @dev No order book, fees, deposits, upgradeability, or administrative withdrawals.
abstract contract SettlementMatching is SettlementOrderHashing {
    using SafeMath for uint256;

    enum MatchType {
        Direct,
        Mint,
        Merge
    }

    struct Market {
        bytes32 conditionId;
        bytes32 left;
        bytes32 right;
        bool registered;
    }

    /// @dev Exact offered/received asset units for each side of a maker/taker leg.
    struct Fill {
        uint64 makerAmount;
        uint64 takerAmount;
        uint64 makerReceiveAmount;
        uint64 takerReceiveAmount;
    }

    /// @dev One taker and its maker fills. Multiple entries settle atomically.
    struct TakerMatch {
        SettlementOrderV1 taker;
        bytes takerSignature;
        SettlementOrderV1[] makers;
        bytes[] makerSignatures;
        Fill[] fills;
    }

    // Amounts cannot exceed the signed uint64 makerAmount. Keep cancellation in
    // the same slot so validation reads one cold slot and FAK needs one write.
    struct OrderState {
        uint64 paid;
        bool isCancelled;
    }

    address public admin;
    address public pendingAdmin;
    IERC20Settlement public immutable collateral;
    IOutcomeBalances public immutable conditionalTokens;
    uint256 public constant MAX_MAKERS = 64;
    uint256 private constant HALF_CURVE_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;
    mapping(address => bool) public operators;
    // May only register markets, so a hot creator key need not be the admin.
    mapping(address => bool) public registrars;
    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => OrderState) private orderStates;
    mapping(address => uint64) public nonceEpoch;
    mapping(address => mapping(address => bool)) public authorizedSigners;
    bool public paused;
    // EIP-1153: the guard is transaction-local, but must still be cleared on
    // successful return so another settlement can run in the same transaction.
    bool private transient entered;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidMarket();
    error InvalidOrder();
    error InvalidSignature();
    error OrderUnavailable();
    error InvalidMatch();
    error InvalidFill();
    error PriceViolation();
    error TransferFailed();
    error UnexpectedBalance();
    error ReentrantCall();
    error TradingPaused();

    event OperatorSet(address indexed operator, bool enabled);
    event RegistrarSet(address indexed registrar, bool enabled);
    event AdminTransferStarted(address indexed previousAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event PauseSet(bool paused);
    event MarketRegistered(bytes32 indexed marketId, bytes32 indexed conditionId, bytes32 left, bytes32 right);
    event SignerSet(address indexed maker, address indexed signer, bool enabled);
    event OrderCancelled(bytes32 indexed orderId, address indexed maker);
    event NonceEpochSet(address indexed maker, uint64 epoch);
    event OrderFilled(
        bytes32 indexed orderId, address indexed maker, uint256 paid, uint256 received, uint256 totalPaid
    );
    event OrdersMatched(bytes32 indexed takerOrderId, bytes32 indexed makerOrderId, MatchType matchType, Fill fill);

    constructor(address admin_, address collateral_, address conditionalTokens_) {
        if (
            admin_ == address(0) || collateral_.code.length == 0 || conditionalTokens_.code.length == 0
                || collateral_ == conditionalTokens_
        ) revert InvalidConfiguration();
        admin = admin_;
        collateral = IERC20Settlement(collateral_);
        conditionalTokens = IOutcomeBalances(conditionalTokens_);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }
    modifier nonReentrant() {
        if (entered) revert ReentrantCall();
        entered = true;
        _;
        entered = false;
    }

    function setOperator(address operator, bool enabled) external onlyAdmin {
        if (operator == address(0)) revert InvalidConfiguration();
        operators[operator] = enabled;
        emit OperatorSet(operator, enabled);
    }

    function setRegistrar(address registrar, bool enabled) external onlyAdmin {
        if (registrar == address(0)) revert InvalidConfiguration();
        registrars[registrar] = enabled;
        emit RegistrarSet(registrar, enabled);
    }

    /// @notice Two-step: the new admin (e.g. a Safe) must call acceptAdmin. address(0) cancels.
    function transferAdmin(address newAdmin) external onlyAdmin {
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert Unauthorized();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }

    function setPaused(bool value) external onlyAdmin {
        paused = value;
        emit PauseSet(value);
    }

    /// @notice Register a market once; the concrete asset implementation validates its IDs.
    function registerMarket(bytes32 marketId, bytes32 conditionId) external {
        if (msg.sender != admin && !registrars[msg.sender]) revert Unauthorized();
        if (marketId == bytes32(0) || markets[marketId].registered) revert InvalidMarket();
        (bytes32 left, bytes32 right) = _marketOutcomes(marketId, conditionId);
        if (left == right) revert InvalidMarket();
        markets[marketId] = Market(conditionId, left, right, true);
        emit MarketRegistered(marketId, conditionId, left, right);
    }

    function _marketOutcomes(bytes32 marketId, bytes32 conditionId) internal view virtual returns (bytes32, bytes32);

    function setSigner(address signer, bool enabled) external {
        if (signer == address(0)) revert InvalidConfiguration();
        authorizedSigners[msg.sender][signer] = enabled;
        emit SignerSet(msg.sender, signer, enabled);
    }

    function cancelOrder(SettlementOrderV1 calldata order) external {
        if (msg.sender != order.maker) revert Unauthorized();
        bytes32 id = hashOrder(order);
        orderStates[id].isCancelled = true;
        emit OrderCancelled(id, msg.sender);
    }

    /// @notice Cumulative offered-asset fill; retains the original getter ABI.
    function filled(bytes32 id) external view returns (uint256) {
        return orderStates[id].paid;
    }

    function cancelled(bytes32 id) external view returns (bool) {
        return orderStates[id].isCancelled;
    }

    function setNonceEpoch(uint64 epoch) external {
        if (epoch <= nonceEpoch[msg.sender]) revert InvalidOrder();
        nonceEpoch[msg.sender] = epoch;
        emit NonceEpochSet(msg.sender, epoch);
    }

    /// @notice Validate all matches and commit fills before transferring any assets.
    /// @dev A taker may match several makers, including different settlement paths.
    function matchOrders(
        SettlementOrderV1 calldata taker,
        bytes calldata takerSignature,
        SettlementOrderV1[] calldata makers,
        bytes[] calldata makerSignatures,
        Fill[] calldata fills
    ) external nonReentrant {
        _requireTradingOperator();
        _matchOrders(taker, takerSignature, makers, makerSignatures, fills, domainSeparator());
    }

    /// @notice Atomically settle several takers, with at most 64 maker fills in total.
    /// @dev A failure in any entry reverts every order-state update and asset transfer.
    function matchOrdersBatch(TakerMatch[] calldata matches) external nonReentrant {
        _requireTradingOperator();
        uint256 count = matches.length;
        if (count == 0 || count > MAX_MAKERS) revert InvalidMatch();
        uint256 totalFills = 0;
        for (uint256 i = 0; i < count; ++i) {
            TakerMatch calldata entry = matches[i];
            uint256 makerCount = entry.makers.length;
            if (makerCount == 0 || makerCount != entry.makerSignatures.length || makerCount != entry.fills.length) {
                revert InvalidMatch();
            }
            totalFills = totalFills.add(makerCount);
            if (totalFills > MAX_MAKERS) revert InvalidMatch();
        }
        bytes32 domain = domainSeparator();
        for (uint256 i = 0; i < count; ++i) {
            TakerMatch calldata entry = matches[i];
            _matchOrders(entry.taker, entry.takerSignature, entry.makers, entry.makerSignatures, entry.fills, domain);
        }
    }

    function _requireTradingOperator() private view {
        if (!operators[msg.sender]) revert Unauthorized();
        if (paused) revert TradingPaused();
    }

    function _matchOrders(
        SettlementOrderV1 calldata taker,
        bytes calldata takerSignature,
        SettlementOrderV1[] calldata makers,
        bytes[] calldata makerSignatures,
        Fill[] calldata fills,
        bytes32 domain
    ) private {
        uint256 count = makers.length;
        if (count == 0 || count > MAX_MAKERS || count != makerSignatures.length || count != fills.length) {
            revert InvalidMatch();
        }
        // Registered markets are immutable, so every order in the batch can
        // share this snapshot even across contract-signature static calls.
        Market memory market = markets[taker.marketId];
        bytes32 takerId = _validateOrder(taker, takerSignature, market, domain);
        bytes32[] memory makerIds = new bytes32[](count);
        MatchType[] memory kinds = new MatchType[](count);
        // Small batches need no extra table. Larger batches use open addressing
        // at <= 50% occupancy; entries are maker indexes + 1, so zero hashes work.
        uint256[] memory seen = new uint256[](count > 16 ? count.mul(2) : 0);
        uint256 paid = 0;
        uint256 received = 0;
        for (uint256 i = 0; i < count; ++i) {
            SettlementOrderV1 calldata maker = makers[i];
            if (maker.marketId != taker.marketId) revert InvalidMatch();
            if (maker.maker == taker.maker) revert InvalidMatch();
            bytes32 makerId = _validateOrder(maker, makerSignatures[i], market, domain);
            if (makerId == takerId) revert InvalidMatch();
            _recordMaker(makerIds, seen, i, makerId);
            kinds[i] = _validateMatch(taker, maker, fills[i]);
            _consume(maker, makerId, fills[i].makerAmount, fills[i].makerReceiveAmount);
            paid = paid.add(fills[i].takerAmount);
            received = received.add(fills[i].takerReceiveAmount);
        }
        _consume(taker, takerId, paid, received);
        _settle(taker, makers, fills, kinds, market.conditionId);
        for (uint256 i = 0; i < count; ++i) {
            emit OrdersMatched(takerId, makerIds[i], kinds[i], fills[i]);
        }
    }

    function _recordMaker(bytes32[] memory ids, uint256[] memory seen, uint256 index, bytes32 id) private pure {
        uint256 size = seen.length;
        if (size == 0) {
            for (uint256 j = 0; j < index; ++j) {
                if (ids[j] == id) revert InvalidMatch();
            }
        } else {
            uint256 slot = uint256(id).mod(size);
            while (seen[slot] != 0) {
                if (ids[seen[slot].sub(1)] == id) revert InvalidMatch();
                slot = slot.add(1);
                if (slot == size) slot = 0;
            }
            seen[slot] = index.add(1);
        }
        ids[index] = id;
    }

    function _validateOrder(
        SettlementOrderV1 calldata order,
        bytes calldata signature,
        Market memory market,
        bytes32 domain
    ) private view returns (bytes32 id) {
        if (!market.registered || (order.outcomeId != market.left && order.outcomeId != market.right)) {
            revert InvalidMarket();
        }
        if (
            order.protocolVersion != 1 || order.maker == address(0) || order.maker == address(this)
                || order.signer == address(0) || order.side > 1 || order.timeInForce > 3 || order.makerAmount == 0
                || order.takerAmount == 0 || order.minFillAmount > order.makerAmount
        ) revert InvalidOrder();
        if (order.timeInForce == 0 ? order.expiration != 0 : order.expiration == 0) revert InvalidOrder();
        if (order.expiration != 0 && block.timestamp >= order.expiration) revert OrderUnavailable();
        id = _hashOrder(order, domain);
        OrderState memory state = orderStates[id];
        if (state.isCancelled || state.paid >= order.makerAmount || order.nonceEpoch != nonceEpoch[order.maker]) {
            revert OrderUnavailable();
        }
        if (order.signer != order.maker && !authorizedSigners[order.maker][order.signer]) revert Unauthorized();
        if (order.signer.code.length != 0) {
            (bool ok, bytes memory result) =
                order.signer.staticcall(abi.encodeWithSelector(bytes4(0x1626ba7e), id, signature));
            if (!ok || result.length < 32 || bytes4(result) != 0x1626ba7e) revert InvalidSignature();
        } else {
            if (signature.length != 65) revert InvalidSignature();
            bytes32 r = bytes32(signature[:32]);
            bytes32 s = bytes32(signature[32:64]);
            uint8 v = uint8(signature[64]);
            if (v < 2) v = v == 0 ? 27 : 28;
            if ((v != 27 && v != 28) || uint256(s) > HALF_CURVE_ORDER || ecrecover(id, v, r, s) != order.signer) {
                revert InvalidSignature();
            }
        }
    }

    function _consume(SettlementOrderV1 calldata order, bytes32 id, uint256 paid, uint256 received) private {
        uint256 previous = orderStates[id].paid;
        uint256 remaining = uint256(order.makerAmount).sub(previous);
        if (
            paid == 0 || received == 0 || paid > remaining || (paid < order.minFillAmount && paid != remaining)
                || (order.timeInForce == 3 && paid != remaining)
        ) revert InvalidFill();
        if (received.mul(order.makerAmount) < paid.mul(order.takerAmount)) revert PriceViolation();
        uint256 total = previous.add(paid);
        // paid <= remaining proves total <= order.makerAmount <= uint64.max.
        // FAK records its terminal state in this same storage write.
        // forge-lint: disable-next-line(unsafe-typecast)
        orderStates[id] = OrderState(uint64(total), order.timeInForce == 2);
        emit OrderFilled(id, order.maker, paid, received, total);
    }

    function _validateMatch(SettlementOrderV1 calldata taker, SettlementOrderV1 calldata maker, Fill calldata fill)
        private
        pure
        returns (MatchType)
    {
        if (
            (taker.taker != address(0) && taker.taker != maker.maker)
                || (maker.taker != address(0) && maker.taker != taker.maker)
        ) revert InvalidMatch();
        if (
            fill.makerAmount == 0 || fill.takerAmount == 0 || fill.makerReceiveAmount == 0
                || fill.takerReceiveAmount == 0
        ) revert InvalidFill();
        if (taker.side != maker.side) {
            if (
                taker.outcomeId != maker.outcomeId || fill.makerAmount != fill.takerReceiveAmount
                    || fill.takerAmount != fill.makerReceiveAmount
            ) revert InvalidMatch();
            return MatchType.Direct;
        }
        if (taker.outcomeId == maker.outcomeId) revert InvalidMatch();
        if (taker.side == 0) {
            uint256 quantity = uint256(fill.makerAmount).add(fill.takerAmount);
            if (fill.makerReceiveAmount != quantity || fill.takerReceiveAmount != quantity) revert InvalidMatch();
            return MatchType.Mint;
        }
        if (
            fill.makerAmount != fill.takerAmount
                || uint256(fill.makerReceiveAmount).add(fill.takerReceiveAmount) != fill.makerAmount
        ) revert InvalidMatch();
        return MatchType.Merge;
    }

    /// @dev Direct legs move peer to peer. Mint/merge legs pool through the
    /// exchange, so the taker moves once and the vault is called once per call.
    function _settle(
        SettlementOrderV1 calldata taker,
        SettlementOrderV1[] calldata makers,
        Fill[] calldata fills,
        MatchType[] memory kinds,
        bytes32 condition
    ) private {
        uint256 count = makers.length;
        uint256 pooled = 0;
        uint256 quantity = 0;
        for (uint256 i = 0; i < count; ++i) {
            SettlementOrderV1 calldata maker = makers[i];
            Fill calldata fill = fills[i];
            if (kinds[i] == MatchType.Direct) {
                if (maker.side == 0) {
                    _moveCollateral(maker.maker, taker.maker, fill.makerAmount);
                    _moveOutcome(taker.maker, maker.maker, maker.outcomeId, fill.takerAmount);
                } else {
                    _moveOutcome(maker.maker, taker.maker, maker.outcomeId, fill.makerAmount);
                    _moveCollateral(taker.maker, maker.maker, fill.takerAmount);
                }
                continue;
            }
            if (kinds[i] == MatchType.Mint) {
                _moveCollateral(maker.maker, address(this), fill.makerAmount);
                quantity = quantity.add(fill.makerReceiveAmount);
            } else {
                _moveOutcome(maker.maker, address(this), maker.outcomeId, fill.makerAmount);
                quantity = quantity.add(fill.makerAmount);
            }
            pooled = pooled.add(fill.takerAmount);
        }
        if (quantity == 0) return;
        // _validateMatch ties Mint to a taker BUY and Merge to a taker SELL, so
        // one call never mixes them. Per fill, Mint pays in exactly the minted
        // quantity and Merge pays out exactly the merged one, so pooled legs net
        // to zero on the exchange.
        if (taker.side == 0) {
            _moveCollateral(taker.maker, address(this), pooled);
            _callCollateral(abi.encodeCall(IERC20Settlement.approve, (address(conditionalTokens), quantity)));
            _splitPosition(condition, quantity);
            _callCollateral(abi.encodeCall(IERC20Settlement.approve, (address(conditionalTokens), 0)));
            _moveOutcome(address(this), taker.maker, taker.outcomeId, quantity);
        } else {
            _moveOutcome(taker.maker, address(this), taker.outcomeId, pooled);
            _mergePositions(condition, quantity);
        }
        uint256 takerOut = 0;
        for (uint256 i = 0; i < count; ++i) {
            if (kinds[i] == MatchType.Mint) {
                _moveOutcome(address(this), makers[i].maker, makers[i].outcomeId, fills[i].makerReceiveAmount);
            } else if (kinds[i] == MatchType.Merge) {
                _moveCollateral(address(this), makers[i].maker, fills[i].makerReceiveAmount);
                takerOut = takerOut.add(fills[i].takerReceiveAmount);
            }
        }
        if (takerOut != 0) _moveCollateral(address(this), taker.maker, takerOut);
    }

    function _callCollateral(bytes memory data) private {
        (bool ok, bytes memory result) = address(collateral).call(data);
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TransferFailed();
        }
    }

    // Collateral and outcome tokens are trusted to move exact amounts and revert
    // on failure (USDC, V1 ConditionalTokens), so balances are not re-checked.
    function _moveCollateral(address from, address to, uint256 amount) private {
        if (from == to) return;
        if (from == address(this)) _callCollateral(abi.encodeCall(IERC20Settlement.transfer, (to, amount)));
        else _callCollateral(abi.encodeCall(IERC20Settlement.transferFrom, (from, to, amount)));
    }

    function _moveOutcome(address from, address to, bytes32 outcome, uint256 amount) private {
        if (from == to) return;
        _transferOutcome(from, to, uint256(outcome), amount);
    }

    function _transferOutcome(address from, address to, uint256 id, uint256 amount) internal virtual;
    function _splitPosition(bytes32 marketId, uint256 amount) internal virtual;
    function _mergePositions(bytes32 marketId, uint256 amount) internal virtual;

    function onERC1155Received(address operator, address, uint256, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        _checkReceiver(operator);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address operator, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        _checkReceiver(operator);
        return this.onERC1155BatchReceived.selector;
    }

    function _checkReceiver(address operator) private view {
        if (msg.sender != address(conditionalTokens) || !entered || operator != address(this)) revert Unauthorized();
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x4e2312e0;
    }
}
