// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    struct PriceFeed {
        bytes32 id;
        Price price;
        Price emaPrice;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory);
    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
    function updatePriceFeeds(bytes[] calldata updateData) external payable;
    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PriceFeed[] memory priceFeeds);
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);
}
