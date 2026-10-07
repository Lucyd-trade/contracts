// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ConditionalTokens.sol";
import "./mocks/MockERC20.sol";

contract ConditionalTokensTest is Test {
    ConditionalTokens ctf;
    MockERC20 usdc;

    address treasury = makeAddr("treasury");
    address settler = makeAddr("settler");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes32 constant MARKET = keccak256("market1");
    uint256 constant AMOUNT = 1_000_000; // 1 USDC

    function setUp() public {
        usdc = new MockERC20();
        ctf = new ConditionalTokens(address(usdc), treasury, 200, address(this));
        ctf.registerMarket(MARKET, settler);

        usdc.mint(alice, 10 * AMOUNT);
        vm.prank(alice);
        usdc.approve(address(ctf), type(uint256).max);

        usdc.mint(bob, 10 * AMOUNT);
        vm.prank(bob);
        usdc.approve(address(ctf), type(uint256).max);
    }

    // ── split / merge ──────────────────────────────────────────────────────────

    function test_split_mintsYesAndNo() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);

        assertEq(ctf.balanceOf(alice, ctf.yesTokenId(MARKET)), AMOUNT);
        assertEq(ctf.balanceOf(alice, ctf.noTokenId(MARKET)), AMOUNT);
        assertEq(usdc.balanceOf(address(ctf)), AMOUNT);
    }

    function test_merge_returnsUsdc() public {
        vm.startPrank(alice);
        ctf.splitPosition(MARKET, AMOUNT);
        ctf.mergePositions(MARKET, AMOUNT);
        vm.stopPrank();

        assertEq(ctf.balanceOf(alice, ctf.yesTokenId(MARKET)), 0);
        assertEq(ctf.balanceOf(alice, ctf.noTokenId(MARKET)), 0);
        assertEq(usdc.balanceOf(alice), 10 * AMOUNT);
        assertEq(usdc.balanceOf(address(ctf)), 0);
    }

    function test_merge_revertsIfResolved() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);
        vm.prank(settler);
        ctf.reportWinner(MARKET, 0, 0);

        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.MarketAlreadyResolved.selector);
        ctf.mergePositions(MARKET, AMOUNT);
    }

    function test_split_revertsAfterResolution() public {
        vm.prank(settler);
        ctf.reportWinner(MARKET, 0, 0);

        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.MarketAlreadyResolved.selector);
        ctf.splitPosition(MARKET, AMOUNT);
    }

    // ── redeem: normal settlement ──────────────────────────────────────────────

    function test_redeem_yesWins_winnerGetsPayout() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);

        vm.prank(settler);
        ctf.reportWinner(MARKET, 0, 0); // YES wins

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        ctf.redeemPositions(MARKET, 0, AMOUNT); // redeem YES

        uint256 fee = AMOUNT * 200 / 10000;
        assertEq(usdc.balanceOf(alice), aliceBefore + AMOUNT - fee);
        assertEq(usdc.balanceOf(treasury), treasuryBefore + fee);
        assertEq(ctf.balanceOf(alice, ctf.yesTokenId(MARKET)), 0);
    }

    function test_redeem_losingTokenReverts() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);

        vm.prank(settler);
        ctf.reportWinner(MARKET, 0, 0); // YES wins

        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.WrongSide.selector);
        ctf.redeemPositions(MARKET, 1, AMOUNT); // try redeem NO (losing)
    }

    function test_redeem_revertsIfNotResolved() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);

        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.MarketNotResolved.selector);
        ctf.redeemPositions(MARKET, 0, AMOUNT);
    }

    function test_fee_is_2pct() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);
        vm.prank(settler);
        ctf.reportWinner(MARKET, 0, 0);

        vm.prank(alice);
        ctf.redeemPositions(MARKET, 0, AMOUNT);

        uint256 expectedFee = AMOUNT * 200 / 10000; // 2%
        assertEq(usdc.balanceOf(treasury), expectedFee);
    }

    // ── fee config ─────────────────────────────────────────────────────────────

    function test_setFeeBps_appliesOnlyToNewMarkets() public {
        ctf.setFeeBps(0);
        bytes32 newMarket = keccak256("market2");
        ctf.registerMarket(newMarket, settler);
        assertEq(ctf.marketFeeBps(MARKET), 200);
        assertEq(ctf.marketFeeBps(newMarket), 0);

        vm.startPrank(alice);
        ctf.splitPosition(MARKET, AMOUNT);
        ctf.splitPosition(newMarket, AMOUNT);
        vm.stopPrank();
        vm.startPrank(settler);
        ctf.reportWinner(MARKET, 0, 0);
        ctf.reportWinner(newMarket, 0, 0);
        vm.stopPrank();

        vm.startPrank(alice);
        ctf.redeemPositions(MARKET, 0, AMOUNT);
        ctf.redeemPositions(newMarket, 0, AMOUNT);
        vm.stopPrank();

        assertEq(usdc.balanceOf(treasury), AMOUNT * 200 / 10000);
    }

    function test_setFeeBps_capAndOwner() public {
        ctf.setFeeBps(300);
        assertEq(ctf.feeBps(), 300);

        vm.expectRevert(ConditionalTokens.FeeTooHigh.selector);
        ctf.setFeeBps(301);

        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.NotOwner.selector);
        ctf.setFeeBps(100);
    }

    function test_constructor_rejectsFeeAboveCap() public {
        vm.expectRevert(ConditionalTokens.FeeTooHigh.selector);
        new ConditionalTokens(address(usdc), treasury, 301, address(this));
    }

    function test_setTreasury_redirectsFees() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.NotOwner.selector);
        ctf.setTreasury(newTreasury);
        vm.expectRevert(ConditionalTokens.ZeroAddress.selector);
        ctf.setTreasury(address(0));
        ctf.setTreasury(newTreasury);

        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);
        vm.prank(settler);
        ctf.reportWinner(MARKET, 0, 0);
        vm.prank(alice);
        ctf.redeemPositions(MARKET, 0, AMOUNT);

        assertEq(usdc.balanceOf(newTreasury), AMOUNT * 200 / 10000);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    // ── void ───────────────────────────────────────────────────────────────────

    function test_void_yesTokenHalfUsdc() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);

        vm.prank(settler);
        ctf.reportWinner(MARKET, 2, 0); // void

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ctf.redeemPositions(MARKET, 0, AMOUNT); // redeem YES

        assertEq(usdc.balanceOf(alice), aliceBefore + AMOUNT / 2);
        assertEq(ctf.balanceOf(alice, ctf.yesTokenId(MARKET)), 0);
    }

    function test_void_noFeeOnVoidRedeem() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);
        vm.prank(settler);
        ctf.reportWinner(MARKET, 2, 0);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.startPrank(alice);
        ctf.redeemPositions(MARKET, 0, AMOUNT);
        ctf.redeemPositions(MARKET, 1, AMOUNT);
        vm.stopPrank();

        // treasury receives nothing on void
        assertEq(usdc.balanceOf(treasury), treasuryBefore);
    }

    function test_void_bothTokensRedeemable() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, 2 * AMOUNT);
        vm.prank(settler);
        ctf.reportWinner(MARKET, 2, 0);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.startPrank(alice);
        ctf.redeemPositions(MARKET, 0, 2 * AMOUNT); // YES
        ctf.redeemPositions(MARKET, 1, 2 * AMOUNT); // NO
        vm.stopPrank();

        // gets back 0.5 per YES + 0.5 per NO = full USDC
        assertEq(usdc.balanceOf(alice), aliceBefore + 2 * AMOUNT);
    }

    // ── reportWinner ───────────────────────────────────────────────────────────

    function test_reportWinner_onlySettler() public {
        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.NotSettler.selector);
        ctf.reportWinner(MARKET, 0, 0);
    }

    function test_reportWinner_cannotReportTwice() public {
        vm.prank(settler);
        ctf.reportWinner(MARKET, 0, 0);

        vm.prank(settler);
        vm.expectRevert(ConditionalTokens.MarketAlreadyResolved.selector);
        ctf.reportWinner(MARKET, 1, 0);
    }

    function test_reportWinner_emitsResolvedValue() public {
        vm.expectEmit(true, false, false, true);
        emit ConditionalTokens.WinnerReported(MARKET, 0, 12345);
        vm.prank(settler);
        ctf.reportWinner(MARKET, 0, 12345);
    }

    function test_reportWinner_emitsZeroResolvedValueOnVoid() public {
        vm.expectEmit(true, false, false, true);
        emit ConditionalTokens.WinnerReported(MARKET, 2, 0);
        vm.prank(settler);
        ctf.reportWinner(MARKET, 2, 0);
    }

    // ── ERC-1155 transfer ─────────────────────────────────────────────────────

    function test_transferFrom_requiresApproval() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);

        uint256 yesId = ctf.yesTokenId(MARKET); // cache before prank
        vm.prank(bob);
        vm.expectRevert(ConditionalTokens.NotApproved.selector);
        ctf.transferFrom(alice, bob, yesId, AMOUNT, "");
    }

    function test_transferFrom_withApproval() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);

        vm.prank(alice);
        ctf.setApprovalForAll(bob, true);

        uint256 yesId = ctf.yesTokenId(MARKET); // cache before prank
        vm.prank(bob);
        ctf.transferFrom(alice, bob, yesId, AMOUNT, "");

        assertEq(ctf.balanceOf(bob, yesId), AMOUNT);
    }

    // ── registerMarket ────────────────────────────────────────────────────────

    function test_registerMarket_duplicateReverts() public {
        vm.expectRevert(ConditionalTokens.MarketAlreadyExists.selector);
        ctf.registerMarket(MARKET, settler);
    }

    function test_registerMarket_onlyFactory() public {
        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.NotFactory.selector);
        ctf.registerMarket(keccak256("other"), settler);
    }

    function test_totalLiability_tracksOnSplitAndRedeem() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);
        assertEq(ctf.totalLiability(), AMOUNT);

        vm.prank(settler);
        ctf.reportWinner(MARKET, 0, 0); // YES wins

        vm.prank(alice);
        ctf.redeemPositions(MARKET, 0, AMOUNT);
        assertEq(ctf.totalLiability(), 0);
    }

    function test_sweepDust_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.NotOwner.selector);
        ctf.sweepDust(alice);
    }

    function test_sweepDust_doesNotDrainActiveLiability() public {
        vm.prank(alice);
        ctf.splitPosition(MARKET, AMOUNT);

        // active liability = AMOUNT, no dust → sweep takes 0
        uint256 before = usdc.balanceOf(address(this));
        ctf.sweepDust(address(this)); // called as owner (test contract deployed ctf)
        assertEq(usdc.balanceOf(address(this)), before);
        assertEq(usdc.balanceOf(address(ctf)), AMOUNT);
    }


    // ── ownership ──────────────────────────────────────────────────────────────

    function test_transferOwnership_twoStep() public {
        address safe = makeAddr("safe");
        ctf.transferOwnership(safe);
        assertEq(ctf.owner(), address(this));
        assertEq(ctf.pendingOwner(), safe);

        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.NotOwner.selector);
        ctf.acceptOwnership();

        vm.prank(safe);
        ctf.acceptOwnership();
        assertEq(ctf.owner(), safe);
        assertEq(ctf.pendingOwner(), address(0));

        vm.expectRevert(ConditionalTokens.NotOwner.selector);
        ctf.sweepDust(address(this));
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(ConditionalTokens.NotOwner.selector);
        ctf.transferOwnership(alice);
    }
}
