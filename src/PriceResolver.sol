// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IPyth.sol";
import "./IResolver.sol";
import "./ConditionalTokens.sol";
import "./MarketFactory.sol";

contract PriceResolver is IResolver {
    IPyth public immutable pyth;
    ConditionalTokens public immutable ctf;
    MarketFactory public immutable factory;

    // Settlement uses the first Pyth price published at or after settlementTs. If that price was
    // published more than MAX_PUBLISH_DELAY later, Pyth had no price in the window → VOID.
    uint64 public constant MAX_PUBLISH_DELAY = 10;
    // No Pyth data at all (Hermes / feed down) for this long after settlementTs → anyone may void.
    uint256 public constant VOID_GRACE = 24 hours;

    error InvalidTimestamp();
    error InvalidPrice();
    error ExpoOutOfRange();
    error TooEarly();
    error AlreadySettled();
    error MarketNotFound();
    error InsufficientFee();
    error RefundFailed();
    error GraceNotOver();

    constructor(address pyth_, address ctf_, address factory_) {
        pyth = IPyth(pyth_);
        ctf = ConditionalTokens(ctf_);
        factory = MarketFactory(factory_);
    }

    function resolve(bytes32 priceId, uint256 settlementTs, uint256 age)
        external view returns (ResolvedPrice memory)
    {
        if (settlementTs == 0) revert InvalidTimestamp();
        IPyth.Price memory p = pyth.getPriceNoOlderThan(priceId, age);
        int256 normalized = _normalize(p.price, p.expo);
        if (normalized <= 0) revert InvalidPrice();
        return ResolvedPrice({ price: normalized, roundTs: p.publishTime, roundId: 0 });
    }

    /// @param updateData Pyth price updates (Hermes `/v2/updates/price/{settlementTs}`) for the
    ///        market's feeds. Pays the Pyth update fee from msg.value, refunds the rest.
    function settle(bytes32 marketId, bytes[] calldata updateData) external payable {
        (address settler, uint8 winningSide) = ctf.markets(marketId);
        if (settler == address(0)) revert MarketNotFound();
        if (winningSide != 255) revert AlreadySettled();

        (
            ,
            bytes32 feedA,
            bytes32 feedB,
            int256 strike,
            ,
            ,
            uint256 settlementTs,
            ,
        ) = factory.marketInfo(marketId);

        if (block.timestamp < settlementTs) revert TooEarly();

        uint256 fee = pyth.getUpdateFee(updateData);
        if (msg.value < fee) revert InsufficientFee();
        (bool inWindow, int256 value) = _priceAt(updateData, feedA, feedB, uint64(settlementTs), fee);

        if (!inWindow) {
            ctf.reportWinner(marketId, 2, 0);
        } else {
            ctf.reportWinner(marketId, value > strike ? 0 : 1, value);
        }

        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{ value: msg.value - fee }("");
            if (!ok) revert RefundFailed();
        }
    }

    /// Fallback when no Pyth update after settlementTs can be obtained at all.
    function voidExpired(bytes32 marketId) external {
        (address settler, uint8 winningSide) = ctf.markets(marketId);
        if (settler == address(0)) revert MarketNotFound();
        if (winningSide != 255) revert AlreadySettled();
        (,,,,,, uint256 settlementTs,,) = factory.marketInfo(marketId);
        if (block.timestamp <= settlementTs + VOID_GRACE) revert GraceNotOver();
        ctf.reportWinner(marketId, 2, 0);
    }

    /// feedA / feedB ratio (8 decimals), or the feedA price when feedB is unset.
    /// inWindow = false when any feed's first price at/after ts came later than ts + MAX_PUBLISH_DELAY.
    function _priceAt(bytes[] calldata updateData, bytes32 feedA, bytes32 feedB, uint64 ts, uint256 fee)
        internal returns (bool inWindow, int256)
    {
        bytes32[] memory ids = new bytes32[](feedB == bytes32(0) ? 1 : 2);
        ids[0] = feedA;
        if (ids.length == 2) ids[1] = feedB;

        // "Unique" = the update whose previous publish is before ts, i.e. the first one at or after ts.
        // The caller can neither pick a price inside the window nor fake a gap to force a void.
        IPyth.PriceFeed[] memory feeds =
            pyth.parsePriceFeedUpdatesUnique{ value: fee }(updateData, ids, ts, type(uint64).max);

        for (uint256 i = 0; i < feeds.length; i++) {
            if (feeds[i].price.publishTime > ts + MAX_PUBLISH_DELAY) return (false, 0);
        }

        int256 normA = _normalize(feeds[0].price.price, feeds[0].price.expo);
        if (normA <= 0) revert InvalidPrice();
        if (ids.length == 1) return (true, normA);

        int256 normB = _normalize(feeds[1].price.price, feeds[1].price.expo);
        if (normB <= 0) revert InvalidPrice();
        return (true, normA * 1e8 / normB);
    }

    function _normalize(int64 price, int32 expo) internal pure returns (int256) {
        int32 adj = expo + 8;
        if (adj < -18 || adj > 38) revert ExpoOutOfRange();
        if (adj == 0) return int256(price);
        if (adj > 0) return int256(price) * int256(10 ** uint32(adj));
        return int256(price) / int256(10 ** uint32(-adj));
    }
}
