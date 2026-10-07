// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PriceResolver.sol";
import "../src/ConditionalTokens.sol";
import "../src/MarketFactory.sol";
import "./mocks/MockPyth.sol";
import "./mocks/MockERC20.sol";

contract PricePipelineTest is Test {
    PriceResolver resolver;
    ConditionalTokens ctf;
    MarketFactory factory;
    MockPyth pyth;
    MockERC20 usdc;

    address treasury     = makeAddr("treasury");
    address factoryOwner = makeAddr("factoryOwner");
    address trader       = makeAddr("trader");
    address anyone       = makeAddr("anyone");

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
        factory = new MarketFactory(address(ctf), factoryOwner);
        resolver = new PriceResolver(address(pyth), address(ctf), address(factory));

        vm.startPrank(factoryOwner);
        for (uint8 i = 0; i <= 5; i++) {
            factory.setResolverForType(i, address(resolver));
        }
        factory.addCreator(address(this));
        vm.stopPrank();

        refTs   = T - 1 days;
        settleTs = T + 1 days;
    }

    function _splitFor(bytes32 mid) internal {
        usdc.mint(trader, 100e6);
        vm.startPrank(trader);
        usdc.approve(address(ctf), 100e6);
        ctf.splitPosition(mid, 100e6);
        vm.stopPrank();
    }

    function _checkRedeemBal(address who) internal view {
        uint256 bal = usdc.balanceOf(who);
        assertGt(bal, 0);
        assertLt(bal, 100e6);
        assertGe(bal, 98e6);
    }

    // ── Test 1: UpDown YES wins ───────────────────────────────────────────────

    function test_spread_yesWins() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);
        _splitFor(mid);

        vm.warp(settleTs + 1);
        pyth.setPrice(FEED_A, 1_100_000e8, -8, settleTs);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);
        // ratio = 1_100_000e8 * 1e8 / 1_000_000e8 = 1.1e8 > 1e8 → YES

        resolver.settle(mid, NO_UPDATES);
        (, uint8 winner) = ctf.markets(mid);
        assertEq(winner, 0);

        vm.prank(trader);
        ctf.redeemPositions(mid, 0, 100e6);
        _checkRedeemBal(trader);
    }

    // ── Test 2: UpDown NO wins ────────────────────────────────────────────────

    function test_spread_noWins() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 2e8, refTs, settleTs);
        _splitFor(mid);

        vm.warp(settleTs + 1);
        pyth.setPrice(FEED_A, 1_000_000e8, -8, settleTs);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);
        // ratio = 1e8 < 2e8 → NO

        resolver.settle(mid, NO_UPDATES);
        (, uint8 winner) = ctf.markets(mid);
        assertEq(winner, 1);

        vm.prank(trader);
        ctf.redeemPositions(mid, 1, 100e6);
        _checkRedeemBal(trader);
    }

    // ── Test 6: Late settle still uses settlement-time price ─────────────────

    function test_lateSettle_resolvesAndChargesFee() public {
        bytes32 mid = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);
        _splitFor(mid);

        vm.warp(settleTs + 3 days);
        pyth.setPrice(FEED_A, 1_100_000e8, -8, settleTs);
        pyth.setPrice(FEED_B, 1_000_000e8, -8, settleTs);
        resolver.settle(mid, NO_UPDATES);

        (, uint8 winner) = ctf.markets(mid);
        assertEq(winner, 0);

        vm.prank(trader);
        ctf.redeemPositions(mid, 0, 100e6);
        assertEq(usdc.balanceOf(trader), 98e6);
        assertEq(usdc.balanceOf(treasury), 2e6);
    }
}
