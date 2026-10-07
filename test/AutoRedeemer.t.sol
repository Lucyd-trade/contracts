// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ConditionalTokens.sol";
import "../src/AutoRedeemer.sol";
import "./mocks/MockERC20.sol";

contract AutoRedeemerTest is Test {
    ConditionalTokens ctf;
    AutoRedeemer redeemer;
    MockERC20 usdc;

    address treasury = makeAddr("treasury");
    address settler = makeAddr("settler");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    bytes32 constant MARKET = keccak256("market1");
    uint256 constant AMOUNT = 1_000_000; // 1 USDC

    function setUp() public {
        usdc = new MockERC20();
        ctf = new ConditionalTokens(address(usdc), treasury, 200, address(this));
        ctf.registerMarket(MARKET, settler);
        redeemer = new AutoRedeemer(address(ctf));

        _fund(alice);
        _fund(bob);
    }

    function _fund(address user) internal {
        usdc.mint(user, 10 * AMOUNT);
        vm.startPrank(user);
        usdc.approve(address(ctf), type(uint256).max);
        ctf.splitPosition(MARKET, AMOUNT);
        vm.stopPrank();
    }

    function _approve(address user) internal {
        vm.prank(user);
        ctf.setApprovalForAll(address(redeemer), true);
    }

    function _users(address a, address b) internal pure returns (address[] memory u) {
        u = new address[](2);
        u[0] = a;
        u[1] = b;
    }

    function test_redeemWinningSide_paysOwnerMinusFee() public {
        _approve(alice);
        vm.prank(settler);
        ctf.reportWinner(MARKET, 0, 0);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(keeper);
        redeemer.redeem(MARKET, _users(alice, alice));

        assertEq(usdc.balanceOf(alice) - before, AMOUNT * 98 / 100);
        assertEq(usdc.balanceOf(treasury), AMOUNT * 2 / 100);
        assertEq(ctf.balanceOf(alice, ctf.yesTokenId(MARKET)), 0);
        assertEq(ctf.balanceOf(alice, ctf.noTokenId(MARKET)), AMOUNT, "losing side untouched");
        assertEq(usdc.balanceOf(address(redeemer)), 0);
        assertEq(usdc.balanceOf(keeper), 0);
    }

    function test_redeemVoid_redeemsBothSides() public {
        _approve(alice);
        vm.prank(settler);
        ctf.reportWinner(MARKET, 2, 0);

        uint256 before = usdc.balanceOf(alice);
        redeemer.redeem(MARKET, _users(alice, bob));

        assertEq(usdc.balanceOf(alice) - before, AMOUNT);
        assertEq(ctf.balanceOf(alice, ctf.yesTokenId(MARKET)), 0);
        assertEq(ctf.balanceOf(alice, ctf.noTokenId(MARKET)), 0);
    }

    function test_redeem_skipsUnapprovedUsers() public {
        _approve(alice);
        vm.prank(settler);
        ctf.reportWinner(MARKET, 1, 0);

        uint256 bobBefore = usdc.balanceOf(bob);
        redeemer.redeem(MARKET, _users(alice, bob));

        assertEq(usdc.balanceOf(bob), bobBefore);
        assertEq(ctf.balanceOf(bob, ctf.noTokenId(MARKET)), AMOUNT);
        assertEq(ctf.balanceOf(alice, ctf.noTokenId(MARKET)), 0);
    }

    function test_redeem_revokedApprovalSkipped() public {
        _approve(alice);
        vm.prank(alice);
        ctf.setApprovalForAll(address(redeemer), false);
        vm.prank(settler);
        ctf.reportWinner(MARKET, 0, 0);

        redeemer.redeem(MARKET, _users(alice, alice));
        assertEq(ctf.balanceOf(alice, ctf.yesTokenId(MARKET)), AMOUNT);
    }

    function test_redeem_revertsWhenUnresolved() public {
        _approve(alice);
        vm.expectRevert(AutoRedeemer.MarketNotResolved.selector);
        redeemer.redeem(MARKET, _users(alice, alice));
    }

    function test_redeem_revertsForUnknownMarket() public {
        vm.expectRevert(AutoRedeemer.MarketNotFound.selector);
        redeemer.redeem(keccak256("nope"), _users(alice, alice));
    }

    function test_redeemable_reportsApprovedPayableTokens() public {
        _approve(alice);
        address[] memory users = _users(alice, bob);

        uint256[] memory amounts = redeemer.redeemable(MARKET, users);
        assertEq(amounts[0], 0, "unresolved");

        vm.prank(settler);
        ctf.reportWinner(MARKET, 2, 0);
        amounts = redeemer.redeemable(MARKET, users);
        assertEq(amounts[0], 2 * AMOUNT);
        assertEq(amounts[1], 0, "not approved");

        redeemer.redeem(MARKET, users);
        amounts = redeemer.redeemable(MARKET, users);
        assertEq(amounts[0], 0, "drained");
    }

    function test_redeem_ignoresStrayUsdc() public {
        _approve(alice);
        usdc.mint(address(redeemer), 5 * AMOUNT);
        vm.prank(settler);
        ctf.reportWinner(MARKET, 0, 0);

        uint256 before = usdc.balanceOf(alice);
        redeemer.redeem(MARKET, _users(alice, bob));
        assertEq(usdc.balanceOf(alice) - before, AMOUNT * 98 / 100);
        assertEq(usdc.balanceOf(address(redeemer)), 5 * AMOUNT);
    }
}
