// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SettlementMatching} from "./SettlementMatching.sol";
import {SafeMath} from "./libraries/SafeMath.sol";
import {IV1ConditionalTokens, IV1MarketFactory} from "./interfaces/IV1MarketAssets.sol";

/// @notice CLOB matching and settlement against the supplied V1 market system.
/// @dev Users approve this exchange directly. V1 owns resolution and redemption.
contract ClobSettlement is SettlementMatching {
    using SafeMath for uint256;

    IV1MarketFactory public immutable marketFactory;

    constructor(address admin_, address collateral_, address conditionalTokens_, address marketFactory_)
        SettlementMatching(admin_, collateral_, conditionalTokens_)
    {
        if (marketFactory_.code.length == 0) revert InvalidConfiguration();
        marketFactory = IV1MarketFactory(marketFactory_);
        IV1ConditionalTokens ctf = IV1ConditionalTokens(conditionalTokens_);
        if (
            marketFactory.ctf() != conditionalTokens_ || ctf.usdc() != collateral_ || ctf.factory() != marketFactory_
        ) revert InvalidConfiguration();
    }

    /// @dev Register with (v1MarketId, v1MarketId): V1 has no separate condition ID.
    function _marketOutcomes(bytes32 marketId, bytes32 conditionId) internal view override returns (bytes32, bytes32) {
        if (marketId != conditionId) revert InvalidMarket();
        (,,,,,,, bool exists) = marketFactory.marketInfo(marketId);
        IV1ConditionalTokens ctf = IV1ConditionalTokens(address(conditionalTokens));
        (address settler,) = ctf.markets(marketId);
        if (!exists || settler == address(0)) revert InvalidMarket();
        return (bytes32(ctf.yesTokenId(marketId)), bytes32(ctf.noTokenId(marketId)));
    }

    function _transferOutcome(address from, address to, uint256 id, uint256 amount) internal override {
        IV1ConditionalTokens(address(conditionalTokens)).transferFrom(from, to, id, amount, "");
    }

    function _splitPosition(bytes32 marketId, uint256 amount) internal override {
        // V1 ignores ERC-20 return values, so check the vault's actual backing.
        uint256 beforeVault = collateral.balanceOf(address(conditionalTokens));
        IV1ConditionalTokens(address(conditionalTokens)).splitPosition(marketId, amount);
        if (collateral.balanceOf(address(conditionalTokens)) != beforeVault.add(amount)) revert UnexpectedBalance();
    }

    function _mergePositions(bytes32 marketId, uint256 amount) internal override {
        uint256 beforeVault = collateral.balanceOf(address(conditionalTokens));
        IV1ConditionalTokens(address(conditionalTokens)).mergePositions(marketId, amount);
        if (beforeVault < amount || collateral.balanceOf(address(conditionalTokens)) != beforeVault.sub(amount)) {
            revert UnexpectedBalance();
        }
    }
}
