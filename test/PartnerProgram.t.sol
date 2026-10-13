// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PartnerProgram.sol";
import "./mocks/MockERC20.sol";

contract PartnerProgramTest is Test {
    PartnerProgram program;
    MockERC20 usdc;

    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice"); // partner
    address bob = makeAddr("bob"); // partner
    address trader = makeAddr("trader");
    address trader2 = makeAddr("trader2");

    uint32 day;

    function setUp() public {
        vm.warp(100 days + 1 hours);
        day = uint32(block.timestamp / 1 days) - 1;
        usdc = new MockERC20();
        program = new PartnerProgram(address(usdc), treasury, operator);
        usdc.mint(address(program), 1_000e6);
        _addPartner(alice);
        _addPartner(bob);
    }

    function _addPartner(address p) internal {
        address[] memory ps = new address[](1);
        ps[0] = p;
        vm.prank(operator);
        program.addPartners(ps);
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _amounts(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    // ---- partners ----

    function test_addPartners_skipsExisting() public {
        vm.recordLogs();
        _addPartner(alice);
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(program.isPartner(alice));
    }

    function test_onlyOperatorAddsPartners() public {
        vm.expectRevert(PartnerProgram.NotOperator.selector);
        program.addPartners(_one(trader));
    }

    // ---- binding ----

    function test_bindTrader() public {
        vm.prank(operator);
        program.bindTrader(trader, alice);
        assertEq(program.partnerOf(trader), alice);
    }

    function test_bindTrader_isPermanent() public {
        vm.startPrank(operator);
        program.bindTrader(trader, alice);
        vm.expectRevert(abi.encodeWithSelector(PartnerProgram.AlreadyBound.selector, trader));
        program.bindTrader(trader, bob);
        vm.stopPrank();
        assertEq(program.partnerOf(trader), alice);
    }

    function test_bindTrader_rejectsNonPartnerAndSelf() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(PartnerProgram.NotPartner.selector, trader2));
        program.bindTrader(trader, trader2);
        vm.expectRevert(abi.encodeWithSelector(PartnerProgram.SelfReferral.selector, alice));
        program.bindTrader(alice, alice);
        vm.stopPrank();
    }

    function test_bindTraders_skipsInvalid() public {
        address[] memory ts = new address[](4);
        address[] memory ps = new address[](4);
        (ts[0], ps[0]) = (trader, alice);
        (ts[1], ps[1]) = (trader, bob); // already bound by entry 0
        (ts[2], ps[2]) = (bob, bob); // self
        (ts[3], ps[3]) = (trader2, trader); // not a partner
        vm.prank(operator);
        uint256 bound = program.bindTraders(ts, ps);
        assertEq(bound, 1);
        assertEq(program.partnerOf(trader), alice);
        assertEq(program.partnerOf(bob), address(0));
        assertEq(program.partnerOf(trader2), address(0));
    }

    function test_onlyOperatorBinds() public {
        vm.prank(alice);
        vm.expectRevert(PartnerProgram.NotOperator.selector);
        program.bindTrader(trader, alice);
    }

    // ---- payouts ----

    function test_pay() public {
        address[] memory ps = new address[](2);
        uint256[] memory am = new uint256[](2);
        (ps[0], am[0]) = (alice, 12e6);
        (ps[1], am[1]) = (bob, 30e6);
        vm.prank(operator);
        program.pay(day, ps, am);
        assertEq(usdc.balanceOf(alice), 12e6);
        assertEq(usdc.balanceOf(bob), 30e6);
        assertTrue(program.dayPaid(day));
        assertEq(program.balance(), 1_000e6 - 42e6);
    }

    function test_pay_oncePerDay() public {
        vm.startPrank(operator);
        program.pay(day, _one(alice), _amounts(10e6));
        vm.expectRevert(abi.encodeWithSelector(PartnerProgram.DayAlreadyPaid.selector, day));
        program.pay(day, _one(alice), _amounts(10e6));
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 10e6);
    }

    function test_pay_onlyPartners() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PartnerProgram.NotPartner.selector, trader));
        program.pay(day, _one(trader), _amounts(10e6));
        assertFalse(program.dayPaid(day));
    }

    function test_pay_noFutureDays() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PartnerProgram.FutureDay.selector, day + 2));
        program.pay(day + 2, _one(alice), _amounts(10e6));
    }

    function test_pay_revertsWholeBatchWithoutFunds() public {
        address[] memory ps = new address[](2);
        uint256[] memory am = new uint256[](2);
        (ps[0], am[0]) = (alice, 10e6);
        (ps[1], am[1]) = (bob, 2_000e6);
        vm.prank(operator);
        vm.expectRevert();
        program.pay(day, ps, am);
        assertEq(usdc.balanceOf(alice), 0);
        assertFalse(program.dayPaid(day));
    }

    function test_onlyOperatorPays() public {
        vm.prank(treasury);
        vm.expectRevert(PartnerProgram.NotOperator.selector);
        program.pay(day, _one(alice), _amounts(10e6));
    }

    // ---- treasury ----

    function test_withdraw() public {
        vm.prank(treasury);
        program.withdraw(treasury, 400e6);
        assertEq(usdc.balanceOf(treasury), 400e6);
    }

    function test_operatorCannotWithdraw() public {
        vm.prank(operator);
        vm.expectRevert(PartnerProgram.NotTreasury.selector);
        program.withdraw(operator, 1e6);
    }

    function test_setOperator() public {
        address next = makeAddr("next");
        vm.prank(treasury);
        program.setOperator(next);
        vm.prank(operator);
        vm.expectRevert(PartnerProgram.NotOperator.selector);
        program.addPartners(_one(trader));
        vm.prank(next);
        program.addPartners(_one(trader));
        assertTrue(program.isPartner(trader));
    }

    function test_setTreasury() public {
        address next = makeAddr("next");
        vm.prank(treasury);
        program.setTreasury(next);
        vm.prank(treasury);
        vm.expectRevert(PartnerProgram.NotTreasury.selector);
        program.withdraw(treasury, 1e6);
        vm.prank(next);
        program.withdraw(next, 1e6);
    }
}
