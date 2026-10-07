// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/IPyth.sol";

/// updateData is ignored: parse* reads the prices stored via setPrice, mimicking a Hermes update
/// for that publishTime. prevPublishTime defaults to publishTime - 1 (Pyth's ~1s cadence).
contract MockPyth {
    mapping(bytes32 => IPyth.Price) private _prices;
    mapping(bytes32 => uint256) private _prevPublishTime;
    uint256 public fee;

    function setPrice(bytes32 id, int64 price, int32 expo, uint256 publishTime) external {
        setPriceWithPrev(id, price, expo, publishTime, publishTime - 1);
    }

    function setPriceWithPrev(bytes32 id, int64 price, int32 expo, uint256 publishTime, uint256 prevPublishTime)
        public
    {
        _prices[id] = IPyth.Price({ price: price, conf: 0, expo: expo, publishTime: publishTime });
        _prevPublishTime[id] = prevPublishTime;
    }

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (IPyth.Price memory) {
        IPyth.Price memory p = _prices[id];
        require(p.publishTime + age >= block.timestamp, "PriceFeedNotFoundWithinRange");
        return p;
    }

    function getPriceUnsafe(bytes32 id) external view returns (IPyth.Price memory) {
        return _prices[id];
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return fee;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {}

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (IPyth.PriceFeed[] memory feeds) {
        require(msg.value >= fee, "InsufficientFee");
        feeds = new IPyth.PriceFeed[](priceIds.length);
        for (uint256 i = 0; i < priceIds.length; i++) {
            IPyth.Price memory p = _prices[priceIds[i]];
            require(
                p.publishTime != 0 && _prevPublishTime[priceIds[i]] < minPublishTime
                    && p.publishTime >= minPublishTime && p.publishTime <= maxPublishTime,
                "PriceFeedNotFoundWithinRange"
            );
            feeds[i] = IPyth.PriceFeed({ id: priceIds[i], price: p, emaPrice: p });
        }
    }
}
