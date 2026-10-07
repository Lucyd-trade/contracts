// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IERC20.sol";

interface IConditionalTokens {
    function usdc() external view returns (address);
    function markets(bytes32 marketId) external view returns (address settler, uint8 winningSide);
    function yesTokenId(bytes32 marketId) external pure returns (uint256);
    function noTokenId(bytes32 marketId) external pure returns (uint256);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function isApprovedForAll(address account, address operator) external view returns (bool);
    function transferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data) external;
    function redeemPositions(bytes32 marketId, uint8 side, uint256 amount) external;
}

/// Redeems resolved positions on behalf of their owners, so payouts arrive without a user action.
/// Owners opt in once with ctf.setApprovalForAll(autoRedeemer, true) and can revoke it any time.
/// Anyone may call redeem; the USDC of each redemption goes only to the owner of the tokens.
/// Immutable: no admin, no withdrawal. The CTF fee applies as on a direct redeem.
contract AutoRedeemer {
    IConditionalTokens public immutable ctf;
    IERC20 public immutable usdc;

    uint8 private constant VOID = 2;
    uint8 private constant UNRESOLVED = 255;

    error MarketNotFound();
    error MarketNotResolved();
    error TransferFailed();

    event AutoRedeemed(address indexed user, bytes32 indexed marketId, uint256 tokenAmount, uint256 usdcPayout);

    constructor(address ctf_) {
        ctf = IConditionalTokens(ctf_);
        usdc = IERC20(IConditionalTokens(ctf_).usdc());
    }

    /// Redeems every approved user's payable tokens on a resolved market: the winning side,
    /// or both sides on a void. Users without approval or without such tokens are skipped.
    function redeem(bytes32 marketId, address[] calldata users) external {
        uint8 winningSide = _resolvedSide(marketId);
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (!ctf.isApprovedForAll(user, address(this))) continue;

            uint256 before = usdc.balanceOf(address(this));
            uint256 tokens;
            if (winningSide == VOID) {
                tokens = _redeemSide(user, marketId, 0) + _redeemSide(user, marketId, 1);
            } else {
                tokens = _redeemSide(user, marketId, winningSide);
            }
            if (tokens == 0) continue;

            uint256 payout = usdc.balanceOf(address(this)) - before;
            if (payout > 0 && !usdc.transfer(user, payout)) revert TransferFailed();
            emit AutoRedeemed(user, marketId, tokens, payout);
        }
    }

    /// Tokens redeem() would take from each user now; 0 if not approved or nothing to redeem.
    /// All zeros while the market is unresolved.
    function redeemable(bytes32 marketId, address[] calldata users) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](users.length);
        (address settler, uint8 winningSide) = ctf.markets(marketId);
        if (settler == address(0) || winningSide == UNRESOLVED) return amounts;

        uint256 yesId = ctf.yesTokenId(marketId);
        uint256 noId = ctf.noTokenId(marketId);
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (!ctf.isApprovedForAll(user, address(this))) continue;
            if (winningSide == VOID) {
                amounts[i] = ctf.balanceOf(user, yesId) + ctf.balanceOf(user, noId);
            } else {
                amounts[i] = ctf.balanceOf(user, winningSide == 0 ? yesId : noId);
            }
        }
    }

    function _resolvedSide(bytes32 marketId) internal view returns (uint8) {
        (address settler, uint8 winningSide) = ctf.markets(marketId);
        if (settler == address(0)) revert MarketNotFound();
        if (winningSide == UNRESOLVED) revert MarketNotResolved();
        return winningSide;
    }

    function _redeemSide(address user, bytes32 marketId, uint8 side) internal returns (uint256 amount) {
        uint256 id = side == 0 ? ctf.yesTokenId(marketId) : ctf.noTokenId(marketId);
        amount = ctf.balanceOf(user, id);
        if (amount == 0) return 0;
        ctf.transferFrom(user, address(this), id, amount, "");
        ctf.redeemPositions(marketId, side, amount);
    }
}
