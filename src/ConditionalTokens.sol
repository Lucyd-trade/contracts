// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IERC20.sol";

contract ConditionalTokens {
    IERC20 public immutable usdc;
    uint256 public constant MAX_FEE_BPS = 300; // 3%
    address public treasury;
    /// Fee on winning redemptions for markets registered from now on; existing markets keep theirs.
    uint256 public feeBps;
    address public factory;
    address public owner;
    address public pendingOwner;

    struct MarketInfo {
        address settler;
        uint8 winningSide; // 0=YES, 1=NO, 2=VOID, 255=unresolved
    }

    mapping(bytes32 => MarketInfo) public markets;
    /// Fee fixed at registration. Separate from MarketInfo so the markets() ABI stays (settler, winningSide).
    mapping(bytes32 => uint256) public marketFeeBps;
    uint256 public totalLiability;

    // ERC-1155 storage
    mapping(uint256 => mapping(address => uint256)) private _balances;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    error MarketNotFound();
    error MarketAlreadyExists();
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error NotSettler();
    error WrongSide();
    error ZeroAmount();
    error InsufficientBalance();
    error NotApproved();
    error ZeroAddress();
    error LengthMismatch();
    error NotFactory();
    error NotOwner();
    error FeeTooHigh();

    event PositionSplit(address indexed user, bytes32 indexed marketId, uint256 amount);
    event PositionMerged(address indexed user, bytes32 indexed marketId, uint256 amount);
    event PositionRedeemed(address indexed user, bytes32 indexed marketId, uint8 side, uint256 tokenAmount, uint256 usdcPayout);
    event WinnerReported(bytes32 indexed marketId, uint8 winningSide, int256 resolvedValue);
    event FeeCollected(address indexed user, uint256 amount);

    // ERC-1155 events
    event TransferSingle(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 value);
    event TransferBatch(address indexed operator, address indexed from, address indexed to, uint256[] ids, uint256[] values);
    event ApprovalForAll(address indexed account, address indexed operator, bool approved);

    event FactoryUpdated(address indexed newFactory);
    event FeeUpdated(uint256 feeBps);
    event TreasuryUpdated(address indexed newTreasury);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address usdc_, address treasury_, uint256 feeBps_, address factory_) {
        if (usdc_ == address(0) || treasury_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        usdc = IERC20(usdc_);
        treasury = treasury_;
        feeBps = feeBps_;
        factory = factory_;
        owner = msg.sender;
    }

    /// Two-step: the new owner (e.g. a Safe) must call acceptOwnership. address(0) cancels a pending transfer.
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function setFactory(address factory_) external {
        if (msg.sender != owner) revert NotOwner();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactoryUpdated(factory_);
    }

    function setFeeBps(uint256 feeBps_) external {
        if (msg.sender != owner) revert NotOwner();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeUpdated(feeBps_);
    }

    function setTreasury(address treasury_) external {
        if (msg.sender != owner) revert NotOwner();
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function yesTokenId(bytes32 marketId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(marketId, uint8(0))));
    }

    function noTokenId(bytes32 marketId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(marketId, uint8(1))));
    }

    function registerMarket(bytes32 marketId, address settler) external {
        if (msg.sender != factory) revert NotFactory();
        if (markets[marketId].settler != address(0)) revert MarketAlreadyExists();
        markets[marketId] = MarketInfo({ settler: settler, winningSide: 255 });
        marketFeeBps[marketId] = feeBps;
    }

    function splitPosition(bytes32 marketId, uint256 amount) external {
        MarketInfo storage m = markets[marketId];
        if (m.settler == address(0)) revert MarketNotFound();
        if (m.winningSide != 255) revert MarketAlreadyResolved();
        if (amount == 0) revert ZeroAmount();

        address sender = msg.sender;
        uint256 yesId = yesTokenId(marketId);
        uint256 noId = noTokenId(marketId);
        _balances[yesId][sender] += amount;
        _balances[noId][sender] += amount;

        emit TransferSingle(sender, address(0), sender, yesId, amount);
        emit TransferSingle(sender, address(0), sender, noId, amount);
        totalLiability += amount;
        emit PositionSplit(sender, marketId, amount);
        usdc.transferFrom(sender, address(this), amount);
    }

    function mergePositions(bytes32 marketId, uint256 amount) external {
        MarketInfo storage m = markets[marketId];
        if (m.settler == address(0)) revert MarketNotFound();
        if (m.winningSide != 255) revert MarketAlreadyResolved();
        if (amount == 0) revert ZeroAmount();

        address sender = msg.sender;
        uint256 yesId = yesTokenId(marketId);
        uint256 noId = noTokenId(marketId);
        if (_balances[yesId][sender] < amount) revert InsufficientBalance();
        if (_balances[noId][sender] < amount) revert InsufficientBalance();

        _balances[yesId][sender] -= amount;
        _balances[noId][sender] -= amount;

        emit TransferSingle(sender, sender, address(0), yesId, amount);
        emit TransferSingle(sender, sender, address(0), noId, amount);
        totalLiability -= amount;
        emit PositionMerged(sender, marketId, amount);

        usdc.transfer(sender, amount);
    }

    function redeemPositions(bytes32 marketId, uint8 side, uint256 amount) external {
        MarketInfo storage m = markets[marketId];
        if (m.settler == address(0)) revert MarketNotFound();
        if (m.winningSide == 255) revert MarketNotResolved();
        if (amount == 0) revert ZeroAmount();

        address sender = msg.sender;
        uint256 tokenId = side == 0 ? yesTokenId(marketId) : noTokenId(marketId);
        if (_balances[tokenId][sender] < amount) revert InsufficientBalance();
        _balances[tokenId][sender] -= amount;
        emit TransferSingle(sender, sender, address(0), tokenId, amount);

        if (m.winningSide == 2) {
            // Void: 0.5 USDC per token, no fee
            uint256 payout = amount / 2;
            totalLiability -= payout;
            usdc.transfer(sender, payout);
            emit PositionRedeemed(sender, marketId, side, amount, payout);
        } else {
            if (side != m.winningSide) revert WrongSide();
            uint256 fee = amount * marketFeeBps[marketId] / 10000;
            totalLiability -= amount;
            if (fee > 0) {
                usdc.transfer(treasury, fee);
                emit FeeCollected(sender, fee);
            }
            usdc.transfer(sender, amount - fee);
            emit PositionRedeemed(sender, marketId, side, amount, amount - fee);
        }
    }

    function reportWinner(bytes32 marketId, uint8 winningSide, int256 resolvedValue) external {
        MarketInfo storage m = markets[marketId];
        if (m.settler == address(0)) revert MarketNotFound();
        if (msg.sender != m.settler) revert NotSettler();
        if (m.winningSide != 255) revert MarketAlreadyResolved();
        m.winningSide = winningSide;
        emit WinnerReported(marketId, winningSide, resolvedValue);
    }

    function sweepDust(address to) external {
        if (msg.sender != owner) revert NotOwner();
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > totalLiability) usdc.transfer(to, bal - totalLiability);
    }

    // ── ERC-1155 ──────────────────────────────────────────────────────────────

    function balanceOf(address account, uint256 id) external view returns (uint256) {
        return _balances[id][account];
    }

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external view returns (uint256[] memory)
    {
        if (accounts.length != ids.length) revert LengthMismatch();
        uint256[] memory out = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            out[i] = _balances[ids[i]][accounts[i]];
        }
        return out;
    }

    function setApprovalForAll(address operator, bool approved) external {
        address sender = msg.sender;
        _operatorApprovals[sender][operator] = approved;
        emit ApprovalForAll(sender, operator, approved);
    }

    function isApprovedForAll(address account, address operator) external view returns (bool) {
        return _operatorApprovals[account][operator];
    }

    function transferFrom(address from, address to, uint256 id, uint256 value, bytes calldata) external {
        address sender = msg.sender;
        if (from != sender && !_operatorApprovals[from][sender]) revert NotApproved();
        if (to == address(0)) revert ZeroAddress();
        if (_balances[id][from] < value) revert InsufficientBalance();
        _balances[id][from] -= value;
        _balances[id][to] += value;
        emit TransferSingle(sender, from, to, id, value);
    }

    function batchTransferFrom(
        address from, address to, uint256[] calldata ids, uint256[] calldata values, bytes calldata
    ) external {
        address sender = msg.sender;
        if (from != sender && !_operatorApprovals[from][sender]) revert NotApproved();
        if (to == address(0)) revert ZeroAddress();
        if (ids.length != values.length) revert LengthMismatch();
        for (uint256 i = 0; i < ids.length; i++) {
            if (_balances[ids[i]][from] < values[i]) revert InsufficientBalance();
            _balances[ids[i]][from] -= values[i];
            _balances[ids[i]][to] += values[i];
        }
        emit TransferBatch(sender, from, to, ids, values);
    }


    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0xd9b67a26 || interfaceId == 0x01ffc9a7;
    }
}
