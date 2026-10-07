// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PriceResolver.sol";
import "../src/ConditionalTokens.sol";
import "../src/MarketFactory.sol";
import "./mocks/MockPyth.sol";
import "./mocks/MockERC20.sol";

contract PriceResolverTest is Test {
    PriceResolver resolver;
    ConditionalTokens ctf;
    MarketFactory factory;
    MockPyth pyth;
    MockERC20 usdc;

    address treasury = makeAddr("treasury");
    address owner = makeAddr("owner");

    bytes32 constant FEED_A = keccak256("BTC");
    bytes32 constant FEED_B = keccak256("ETH");

    uint256 constant T = 1_000_000;
    uint256 refTs;
    uint256 settleTs;
    bytes[] NO_UPDATES;

    function setUp() public {
        vm.warp(T);
        pyth = new MockPyth();
        usdc = new MockERC20();
        address factoryAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        ctf = new ConditionalTokens(address(usdc), treasury, 200, factoryAddr);
        factory = new MarketFactory(address(ctf), owner);
        resolver = new PriceResolver(address(pyth), address(ctf), address(factory));

        vm.startPrank(owner);
        for (uint8 i = 0; i <= 5; i++) {
            factory.setResolverForType(i, address(resolver));
        }
        factory.addCreator(address(this));
        vm.stopPrank();

        refTs = T - 1 days;
        settleTs = T + 1 days;
    }

    // ── legacy resolve() ───────────────────────────────────────────────────────

    function test_resolve_returnsNormalizedPrice() public {
        pyth.setPrice(FEED_A, 50_000e8, -8, T);
        IResolver.ResolvedPrice memory r = resolver.resolve(FEED_A, T, 1 days);
        assertEq(r.price, 50_000e8);
        assertEq(r.roundTs, T);
    }

    function test_resolve_revertsStalePrice() public {
        pyth.setPrice(FEED_A, 50_000e8, -8, T - 2 days);
        vm.expectRevert();
        resolver.resolve(FEED_A, T, 1 days);
    }

    // ── settle: SpreadMarket ───────────────────────────────────────────────────

    function test_settle_spread_yesWins() public {
        // refRatio = 1e8, BTC/ETH ratio at settle = 1.1e8 > 1e8 → YES wins
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        vm.warp(settleTs + 1);
        uint256 age = settleTs - refTs;
        pyth.setPrice(FEED_A, 1_100_000e8, -8, settleTs);  // BTC = 1,100,000
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);  // ETH = 1,000,000
        // ratio = 1_100_000e8 * 1e8 / 1_000_000e8 = 1.1e8 > 1e8

        resolver.settle(mid, NO_UPDATES);

        (, uint8 winningSide) = ctf.markets(mid);
        assertEq(winningSide, 0); // YES
    }

    function test_settle_spread_noWins() public {
        // refSpread = 2e8, actual ratio = 1e8 < 2e8 → NO wins
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 2e8, refTs, settleTs);

        vm.warp(settleTs + 1);
        pyth.setPrice(FEED_A, 1_000_000e8, -8, settleTs);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);

        resolver.settle(mid, NO_UPDATES);

        (, uint8 winningSide) = ctf.markets(mid);
        assertEq(winningSide, 1); // NO
    }

    // ── publish window ─────────────────────────────────────────────────────────

    function test_settle_after24h_stillUsesSettlementPrice() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        vm.warp(settleTs + 3 days);
        pyth.setPrice(FEED_A, 1_100_000e8, -8, settleTs);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);

        resolver.settle(mid, NO_UPDATES);
        (, uint8 w) = ctf.markets(mid);
        assertEq(w, 0); // YES, not VOID
    }

    function test_settle_revertsWithoutPrice() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        vm.warp(settleTs + 1);
        vm.expectRevert("PriceFeedNotFoundWithinRange");
        resolver.settle(mid, NO_UPDATES);

        (, uint8 w) = ctf.markets(mid);
        assertEq(w, 255); // still unresolved, retry later
    }

    function test_settle_priceAtWindowEdge_settles() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        uint256 edge = settleTs + resolver.MAX_PUBLISH_DELAY();
        vm.warp(edge);
        pyth.setPriceWithPrev(FEED_A, 1_100_000e8, -8, edge, settleTs - 1);
        pyth.setPriceWithPrev(FEED_B, 1_000_000e8, -8, edge, settleTs - 1);

        resolver.settle(mid, NO_UPDATES);
        (, uint8 w) = ctf.markets(mid);
        assertEq(w, 0);
    }

    function test_settle_gapInPyth_provablyVoids() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        // First BTC update after settleTs came 11s later → no price in the window.
        uint256 late = settleTs + resolver.MAX_PUBLISH_DELAY() + 1;
        vm.warp(late);
        pyth.setPriceWithPrev(FEED_A, 1_100_000e8, -8, late, settleTs - 1);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);

        vm.expectEmit(true, false, false, true, address(ctf));
        emit ConditionalTokens.WinnerReported(mid, 2, 0);
        resolver.settle(mid, NO_UPDATES);
    }

    function test_settle_revertsIfNotFirstPriceAfterSettlement() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        // A later update inside the window, but an earlier one at/after settleTs exists.
        vm.warp(settleTs + 30);
        pyth.setPriceWithPrev(FEED_A, 1_100_000e8, -8, settleTs + 30, settleTs + 29);
        pyth.setPriceWithPrev(FEED_B, 1_000_000e8, -8, settleTs + 30, settleTs + 29);

        vm.expectRevert("PriceFeedNotFoundWithinRange");
        resolver.settle(mid, NO_UPDATES);
    }

    function test_settle_singleFeed_usesFeedAPrice() public {
        bytes32 mid = factory.createMarket(0, FEED_A, bytes32(0), 50_000e8, refTs, settleTs);

        vm.warp(settleTs + 1);
        pyth.setPrice(FEED_A, 60_000e8, -8, settleTs);

        vm.expectEmit(true, false, false, true, address(ctf));
        emit ConditionalTokens.WinnerReported(mid, 0, int256(60_000e8));
        resolver.settle(mid, NO_UPDATES);
    }

    // ── voidExpired ────────────────────────────────────────────────────────────

    function test_voidExpired_revertsBeforeGrace() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        vm.warp(settleTs + resolver.VOID_GRACE());
        vm.expectRevert(PriceResolver.GraceNotOver.selector);
        resolver.voidExpired(mid);
    }

    function test_voidExpired_voidsAfterGrace() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        vm.warp(settleTs + resolver.VOID_GRACE() + 1);
        vm.prank(makeAddr("anyone"));
        resolver.voidExpired(mid);

        (, uint8 w) = ctf.markets(mid);
        assertEq(w, 2);
    }

    function test_voidExpired_revertsIfAlreadySettled() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        vm.warp(settleTs + 1);
        pyth.setPrice(FEED_A, 1_100_000e8, -8, settleTs);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);
        resolver.settle(mid, NO_UPDATES);

        vm.warp(settleTs + resolver.VOID_GRACE() + 1);
        vm.expectRevert(PriceResolver.AlreadySettled.selector);
        resolver.voidExpired(mid);
    }

    // ── pyth fee ───────────────────────────────────────────────────────────────

    function test_settle_paysFeeAndRefundsRest() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);
        pyth.setFee(1 gwei);

        vm.warp(settleTs + 1);
        pyth.setPrice(FEED_A, 1_100_000e8, -8, settleTs);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);

        address caller = makeAddr("caller");
        vm.deal(caller, 1 ether);
        vm.prank(caller);
        resolver.settle{ value: 1 ether }(mid, NO_UPDATES);

        assertEq(address(pyth).balance, 1 gwei);
        assertEq(caller.balance, 1 ether - 1 gwei);
    }

    function test_settle_revertsIfFeeNotPaid() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);
        pyth.setFee(1 gwei);

        vm.warp(settleTs + 1);
        pyth.setPrice(FEED_A, 1_100_000e8, -8, settleTs);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);

        vm.expectRevert(PriceResolver.InsufficientFee.selector);
        resolver.settle(mid, NO_UPDATES);
    }

    // ── guard checks ───────────────────────────────────────────────────────────

    function test_settle_revertsIfTooEarly() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        vm.expectRevert(PriceResolver.TooEarly.selector);
        resolver.settle(mid, NO_UPDATES);
    }

    function test_settle_revertsIfAlreadySettled() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        vm.warp(settleTs + 1);
        pyth.setPrice(FEED_A, 1_100_000e8, -8, settleTs);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);
        resolver.settle(mid, NO_UPDATES);

        vm.expectRevert(PriceResolver.AlreadySettled.selector);
        resolver.settle(mid, NO_UPDATES);
    }

    // ── resolvedValue in event ────────────────────────────────────────────────

    function test_settle_emitsResolvedValue_yesWins() public {
        // ratio = 1_100_000e8 * 1e8 / 1_000_000e8 = 110_000_000
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);
        vm.warp(settleTs + 1);
        pyth.setPrice(FEED_A, 1_100_000e8, -8, settleTs);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);

        vm.expectEmit(true, false, false, true, address(ctf));
        emit ConditionalTokens.WinnerReported(mid, 0, int256(110_000_000));
        resolver.settle(mid, NO_UPDATES);
    }

    function test_settle_emitsResolvedValue_noWins() public {
        // ratio = 1e8 * 1e8 / 1e8 = 1e8, not > 2e8 → NO
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 2e8, refTs, settleTs);
        vm.warp(settleTs + 1);
        pyth.setPrice(FEED_A, 1_000_000e8, -8, settleTs);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);

        vm.expectEmit(true, false, false, true, address(ctf));
        emit ConditionalTokens.WinnerReported(mid, 1, int256(1e8));
        resolver.settle(mid, NO_UPDATES);
    }

    function test_settle_anyoneCanCall() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        vm.warp(settleTs + 1);
        pyth.setPrice(FEED_A, 1_100_000e8, -8, settleTs);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);

        vm.prank(makeAddr("anyone"));
        resolver.settle(mid, NO_UPDATES); // no revert
    }
}
