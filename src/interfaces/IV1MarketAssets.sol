// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IOutcomeBalances} from "./ISettlementAssets.sol";

/// @dev Minimal ABI of the supplied V1 ConditionalTokens, not Gnosis CTF.
interface IV1ConditionalTokens is IOutcomeBalances {
    function usdc() external view returns (address);
    function factory() external view returns (address);
    function markets(bytes32 marketId) external view returns (address settler, uint8 winningSide);
    function yesTokenId(bytes32 marketId) external pure returns (uint256);
    function noTokenId(bytes32 marketId) external pure returns (uint256);
    function transferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function splitPosition(bytes32 marketId, uint256 amount) external;
    function mergePositions(bytes32 marketId, uint256 amount) external;
}

interface IV1MarketFactory {
    function ctf() external view returns (address);
    function marketInfo(bytes32 marketId)
        external
        view
        returns (
            uint8 marketType,
            bytes32 feedA,
            bytes32 feedB,
            int256 strike,
            int256 upperStrike,
            uint256 referenceTs,
            uint256 settlementTs,
            bool exists
        );
}
