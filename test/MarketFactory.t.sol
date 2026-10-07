// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ConditionalTokens.sol";
import "../src/MarketFactory.sol";
import "./mocks/MockERC20.sol";

contract MarketFactoryTest is Test {
    ConditionalTokens ctf;
    MarketFactory factory;
    MockERC20 usdc;

    address treasury = makeAddr("treasury");
    address resolver = makeAddr("resolver");
    address owner = makeAddr("owner");

    bytes32 constant FEED_A = keccak256("BTC");
    bytes32 constant FEED_B = keccak256("ETH");

    uint256 refTs;
    uint256 settleTs;

    function setUp() public {
        usdc = new MockERC20();
        address factoryAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        ctf = new ConditionalTokens(address(usdc), treasury, 200, factoryAddr);
        factory = new MarketFactory(address(ctf), owner);

        refTs = block.timestamp;
        settleTs = block.timestamp + 1 days;

        vm.startPrank(owner);
        for (uint8 i = 0; i <= 5; i++) {
            factory.setResolverForType(i, resolver);
        }
        factory.addCreator(address(this));
        vm.stopPrank();
    }

    function test_createMarket_registersInCTF() public {
        bytes32 marketId = factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);

        (address mSettler, uint8 winningSide) = ctf.markets(marketId);
        assertEq(mSettler, resolver);
        assertEq(winningSide, 255);

        assertEq(factory.marketsCount(), 1);
        assertEq(factory.marketIds(0), marketId);
    }

    function test_invalidMarketTypeReverts() public {
        vm.expectRevert(MarketFactory.UnknownMarketType.selector);
        factory.createMarket(6, FEED_A, FEED_B, 1e8, refTs, settleTs);

        vm.expectRevert(MarketFactory.UnknownMarketType.selector);
        factory.createMarketShell(6, FEED_A, FEED_B, refTs, settleTs, 0);
    }

    function test_invalidTimestampsRevert() public {
        vm.expectRevert(MarketFactory.InvalidTimestamps.selector);
        factory.createMarket(0, FEED_A, FEED_B, 1e8, settleTs, refTs);

        vm.expectRevert(MarketFactory.InvalidTimestamps.selector);
        factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, block.timestamp);
    }

    function test_resolverNotSet_reverts() public {
        MarketFactory f2 = new MarketFactory(address(ctf), owner);
        vm.prank(owner);
        f2.addCreator(address(this));
        vm.expectRevert(MarketFactory.ResolverNotSet.selector);
        f2.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);
    }

    function test_setResolverForType_onlyOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(MarketFactory.NotOwner.selector);
        factory.setResolverForType(0, makeAddr("other"));
    }

    function test_duplicateMarketReverts() public {
        factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);
        vm.expectRevert(MarketFactory.MarketAlreadyExists.selector);
        factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);
    }

    function test_getMarketIds_pagination() public {
        factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);
        factory.createMarket(1, FEED_A, FEED_B, 2e8, refTs, settleTs);
        factory.createMarket(2, FEED_A, FEED_B, 3e8, refTs, settleTs);

        bytes32[] memory page = factory.getMarketIds(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], factory.marketIds(1));
        assertEq(page[1], factory.marketIds(2));
    }

    function test_getMarketIds_outOfBounds() public {
        factory.createMarket(0, FEED_A, FEED_B, 1e8, refTs, settleTs);
        bytes32[] memory page = factory.getMarketIds(10, 5);
        assertEq(page.length, 0);
    }

    function test_transferOwnership_twoStep() public {
        address safe = makeAddr("safe");
        vm.prank(owner);
        factory.transferOwnership(safe);
        assertEq(factory.owner(), owner);

        vm.prank(safe);
        factory.acceptOwnership();
        assertEq(factory.owner(), safe);
        assertEq(factory.pendingOwner(), address(0));

        vm.prank(owner);
        vm.expectRevert(MarketFactory.NotOwner.selector);
        factory.addCreator(owner);
        vm.prank(safe);
        factory.addCreator(owner);
        assertTrue(factory.creators(owner));
    }

    function test_transferOwnership_onlyOwnerAndPending() public {
        vm.expectRevert(MarketFactory.NotOwner.selector);
        factory.transferOwnership(address(this));

        vm.prank(owner);
        factory.transferOwnership(makeAddr("safe"));
        vm.expectRevert(MarketFactory.NotOwner.selector);
        factory.acceptOwnership();
    }
}
