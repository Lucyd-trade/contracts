// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PartnerProgram.sol";
import "../src/ScoutProgram.sol";
import "./mocks/MockERC20.sol";

contract ScoutProgramTest is Test {
    PartnerProgram partners;
    ScoutProgram program;
    MockERC20 usdc;

    address treasury = makeAddr("treasury");
    address operator = makeAddr("operator");
    address scout = makeAddr("scout");
    address scout2 = makeAddr("scout2");
    address p1 = makeAddr("p1");
    address p2 = makeAddr("p2");
    address p3 = makeAddr("p3");
    address stranger = makeAddr("stranger");

    uint32 day;

    function setUp() public {
        vm.warp(100 days + 1 hours);
        day = uint32(block.timestamp / 1 days) - 1;
        usdc = new MockERC20();
        partners = new PartnerProgram(address(usdc), treasury, operator);
        program = new ScoutProgram(address(usdc), address(partners), treasury, operator);
        usdc.mint(address(program), 1_000e6);

        address[] memory ps = new address[](5);
        (ps[0], ps[1], ps[2], ps[3], ps[4]) = (p1, p2, p3, scout, scout2);
        vm.startPrank(operator);
        partners.addPartners(ps);
        address[] memory ss = new address[](2);
        (ss[0], ss[1]) = (scout, scout2);
        program.addScouts(ss);
        vm.stopPrank();
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _amounts(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _bindThree() internal {
        vm.startPrank(operator);
        program.bindPartner(p1, scout);
        program.bindPartner(p2, scout);
        program.bindPartner(p3, scout);
        vm.stopPrank();
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(ScoutProgram.ZeroAddress.selector);
        new ScoutProgram(address(usdc), address(0), treasury, operator);
    }

    // ---- scouts ----

    function test_addScouts_skipsExisting() public {
        vm.recordLogs();
        vm.prank(operator);
        program.addScouts(_one(scout));
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(program.isScout(scout));
    }

    function test_addScouts_rejectsZero() public {
        vm.prank(operator);
        vm.expectRevert(ScoutProgram.ZeroAddress.selector);
        program.addScouts(_one(address(0)));
    }

    function test_onlyOperatorAddsScouts() public {
        vm.expectRevert(ScoutProgram.NotOperator.selector);
        program.addScouts(_one(stranger));
    }

    // ---- binding ----

    function test_bindPartner() public {
        vm.prank(operator);
        program.bindPartner(p1, scout);
        assertEq(program.scoutOf(p1), scout);
        assertEq(program.boundAt(p1), block.timestamp);
        assertEq(program.partnerCount(scout), 1);
    }

    function test_bindPartner_isPermanent() public {
        vm.startPrank(operator);
        program.bindPartner(p1, scout);
        vm.expectRevert(abi.encodeWithSelector(ScoutProgram.AlreadyBound.selector, p1));
        program.bindPartner(p1, scout2);
        vm.stopPrank();
        assertEq(program.scoutOf(p1), scout);
        assertEq(program.partnerCount(scout2), 0);
    }

    function test_bindPartner_rejectsNonPartner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ScoutProgram.NotPartner.selector, stranger));
        program.bindPartner(stranger, scout);
    }

    function test_bindPartner_rejectsNonScout() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ScoutProgram.NotScout.selector, stranger));
        program.bindPartner(p1, stranger);
    }

    function test_bindPartner_rejectsSelf() public {
        // scout is also a partner, but can't be their own scout
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ScoutProgram.SelfReferral.selector, scout));
        program.bindPartner(scout, scout);
    }

    function test_bindPartner_rejectsCross() public {
        vm.startPrank(operator);
        program.bindPartner(scout2, scout); // scout brought scout2
        vm.expectRevert(abi.encodeWithSelector(ScoutProgram.CrossReferral.selector, scout, scout2));
        program.bindPartner(scout, scout2); // and scout2 would bring scout back
        vm.stopPrank();
        assertEq(program.scoutOf(scout), address(0));
    }

    function test_bindPartners_skipsInvalid() public {
        address[] memory ps = new address[](6);
        address[] memory ss = new address[](6);
        (ps[0], ss[0]) = (scout2, scout); // ok
        (ps[1], ss[1]) = (scout2, scout); // already bound by entry 0
        (ps[2], ss[2]) = (scout, scout2); // cross with entry 0
        (ps[3], ss[3]) = (p1, p1); // self, and p1 is no scout
        (ps[4], ss[4]) = (stranger, scout); // not a partner
        (ps[5], ss[5]) = (p2, stranger); // not a scout
        vm.prank(operator);
        uint256 bound = program.bindPartners(ps, ss);
        assertEq(bound, 1);
        assertEq(program.scoutOf(scout2), scout);
        assertEq(program.scoutOf(scout), address(0));
        assertEq(program.scoutOf(p1), address(0));
        assertEq(program.scoutOf(p2), address(0));
        assertEq(program.partnerCount(scout), 1);
    }

    function test_bindPartners_lengthMismatch() public {
        vm.prank(operator);
        vm.expectRevert(ScoutProgram.LengthMismatch.selector);
        program.bindPartners(_one(p1), new address[](0));
    }

    function test_onlyOperatorBinds() public {
        vm.prank(scout);
        vm.expectRevert(ScoutProgram.NotOperator.selector);
        program.bindPartner(p1, scout);
    }

    // ---- payouts ----

    function test_pay() public {
        _bindThree();
        vm.prank(operator);
        program.pay(day, _one(scout), _amounts(25e6));
        assertEq(usdc.balanceOf(scout), 25e6);
        assertTrue(program.dayPaid(day));
        assertEq(program.balance(), 1_000e6 - 25e6);
    }

    function test_pay_belowThreshold() public {
        vm.startPrank(operator);
        program.bindPartner(p1, scout);
        vm.expectRevert(abi.encodeWithSelector(ScoutProgram.BelowThreshold.selector, scout));
        program.pay(day, _one(scout), _amounts(10e6));
        vm.stopPrank();
        assertFalse(program.dayPaid(day));
        assertEq(usdc.balanceOf(scout), 0);
    }

    function test_pay_thresholdReached() public {
        assertEq(program.MIN_PARTNERS(), 2);
        _bindThree();
        assertEq(program.partnerCount(scout), 3);
        vm.prank(operator);
        program.pay(day, _one(scout), _amounts(10e6));
        assertEq(usdc.balanceOf(scout), 10e6);
    }

    function test_pay_onlyScouts() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ScoutProgram.NotScout.selector, stranger));
        program.pay(day, _one(stranger), _amounts(10e6));
    }

    function test_pay_oncePerDay() public {
        _bindThree();
        vm.startPrank(operator);
        program.pay(day, _one(scout), _amounts(10e6));
        vm.expectRevert(abi.encodeWithSelector(ScoutProgram.DayAlreadyPaid.selector, day));
        program.pay(day, _one(scout), _amounts(10e6));
        vm.stopPrank();
        assertEq(usdc.balanceOf(scout), 10e6);
    }

    function test_pay_noFutureDays() public {
        _bindThree();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ScoutProgram.FutureDay.selector, day + 2));
        program.pay(day + 2, _one(scout), _amounts(10e6));
    }

    function test_pay_revertsWholeBatchWithoutFunds() public {
        _bindThree();
        vm.prank(operator);
        vm.expectRevert();
        program.pay(day, _one(scout), _amounts(2_000e6));
        assertEq(usdc.balanceOf(scout), 0);
        assertFalse(program.dayPaid(day));
    }

    function test_pay_lengthMismatch() public {
        vm.prank(operator);
        vm.expectRevert(ScoutProgram.LengthMismatch.selector);
        program.pay(day, _one(scout), new uint256[](0));
    }

    function test_onlyOperatorPays() public {
        _bindThree();
        vm.prank(treasury);
        vm.expectRevert(ScoutProgram.NotOperator.selector);
        program.pay(day, _one(scout), _amounts(10e6));
    }

    // ---- treasury ----

    function test_withdraw() public {
        vm.prank(treasury);
        program.withdraw(treasury, 400e6);
        assertEq(usdc.balanceOf(treasury), 400e6);
    }

    function test_operatorCannotWithdraw() public {
        vm.prank(operator);
        vm.expectRevert(ScoutProgram.NotTreasury.selector);
        program.withdraw(operator, 1e6);
    }

    function test_setOperator() public {
        address next = makeAddr("next");
        vm.prank(treasury);
        program.setOperator(next);
        vm.prank(operator);
        vm.expectRevert(ScoutProgram.NotOperator.selector);
        program.addScouts(_one(stranger));
        vm.prank(next);
        program.addScouts(_one(stranger));
        assertTrue(program.isScout(stranger));
    }

    function test_setTreasury() public {
        address next = makeAddr("next");
        vm.prank(treasury);
        program.setTreasury(next);
        vm.prank(treasury);
        vm.expectRevert(ScoutProgram.NotTreasury.selector);
        program.withdraw(treasury, 1e6);
        vm.prank(next);
        program.withdraw(next, 1e6);
    }
}
