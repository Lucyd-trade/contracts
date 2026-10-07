// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IResolver {
    struct ResolvedPrice {
        int256 price;
        uint256 roundTs;
        uint80 roundId;
    }

    function resolve(bytes32 priceId, uint256 settlementTs, uint256 age) external view returns (ResolvedPrice memory);
}
