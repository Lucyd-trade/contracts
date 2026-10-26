// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IERC20.sol";

interface IPartnerProgram {
    function isPartner(address account) external view returns (bool);
}

/// Scout program: scouts bring partners to the partner program and earn a share of what those
/// partners are paid, on top of it, in daily USDC payouts.
///
/// The share (50% of a partner's payouts for the first 180 days after binding, 10% after) is
/// computed off chain: PartnerProgram keeps no per-day amounts on chain, only its Paid events. This
/// contract keeps the record a scout or anyone can check it against: who is a scout, which partner
/// is bound to which scout and since when, and what was paid for which day. A published script
/// re-adds the PartnerProgram Paid events of each scout's partners and compares. On chain it holds
/// that a binding is permanent, that only scouts with at least MIN_PARTNERS bound partners are paid,
/// and that a day is paid once.
///
/// Two keys, as in PartnerProgram (the same operator key). The operator adds scouts, binds partners
/// and sends the daily payout; the treasury withdraws USDC and replaces the operator. The contract
/// holds about a week of payouts.
contract ScoutProgram {
    /// Bound partners a scout needs before being paid.
    uint256 public constant MIN_PARTNERS = 2;

    IERC20 public immutable usdc;
    IPartnerProgram public immutable partnerProgram;
    address public treasury;
    address public operator;

    mapping(address => bool) public isScout;
    /// Scout a partner is bound to; zero if none.
    mapping(address => address) public scoutOf;
    /// Time of a partner's binding (unix seconds); the 50% window runs from it.
    mapping(address => uint64) public boundAt;
    /// Partners bound to a scout.
    mapping(address => uint256) public partnerCount;
    /// Days (unix time / 1 days) already paid.
    mapping(uint32 => bool) public dayPaid;

    error NotOperator();
    error NotTreasury();
    error ZeroAddress();
    error NotScout(address account);
    error NotPartner(address account);
    error AlreadyBound(address partner);
    error SelfReferral(address partner);
    error CrossReferral(address partner, address scout);
    error BelowThreshold(address scout);
    error DayAlreadyPaid(uint32 day);
    error FutureDay(uint32 day);
    error LengthMismatch();
    error TransferFailed();

    event ScoutAdded(address indexed scout);
    event PartnerBound(address indexed partner, address indexed scout, uint64 boundAt);
    event Paid(uint32 indexed day, address indexed scout, uint256 amount);
    event DayPaid(uint32 indexed day, uint256 scouts, uint256 total);
    event OperatorChanged(address indexed operator);
    event TreasuryChanged(address indexed treasury);
    event Withdrawn(address indexed to, uint256 amount);

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(address usdc_, address partnerProgram_, address treasury_, address operator_) {
        if (usdc_ == address(0) || partnerProgram_ == address(0) || treasury_ == address(0) || operator_ == address(0)) {
            revert ZeroAddress();
        }
        usdc = IERC20(usdc_);
        partnerProgram = IPartnerProgram(partnerProgram_);
        treasury = treasury_;
        operator = operator_;
        emit TreasuryChanged(treasury_);
        emit OperatorChanged(operator_);
    }

    // ---- Operator ----

    /// Adds scouts; ones already added are skipped, so a re-sent batch is harmless.
    function addScouts(address[] calldata scouts) external onlyOperator {
        for (uint256 i = 0; i < scouts.length; i++) {
            address s = scouts[i];
            if (s == address(0)) revert ZeroAddress();
            if (isScout[s]) continue;
            isScout[s] = true;
            emit ScoutAdded(s);
        }
    }

    /// Binds a partner to a scout for good. Reverts unless the partner is in PartnerProgram, the
    /// scout exists, they are different, the partner is not bound yet and the scout is not bound to
    /// this partner (A scouting B while B scouts A).
    function bindPartner(address partner, address scout) external onlyOperator {
        if (partner == address(0)) revert ZeroAddress();
        if (!partnerProgram.isPartner(partner)) revert NotPartner(partner);
        if (!isScout[scout]) revert NotScout(scout);
        if (partner == scout) revert SelfReferral(partner);
        if (scoutOf[partner] != address(0)) revert AlreadyBound(partner);
        if (scoutOf[scout] == partner) revert CrossReferral(partner, scout);
        _bind(partner, scout);
    }

    /// Batch of bindPartner with the same checks, except that an entry failing them is skipped
    /// instead of reverting the batch. Returns how many were bound.
    function bindPartners(address[] calldata partners, address[] calldata scouts) external onlyOperator returns (uint256 bound) {
        if (partners.length != scouts.length) revert LengthMismatch();
        for (uint256 i = 0; i < partners.length; i++) {
            address p = partners[i];
            address s = scouts[i];
            if (
                p == address(0) || p == s || !isScout[s] || scoutOf[p] != address(0) || scoutOf[s] == p
                    || !partnerProgram.isPartner(p)
            ) continue;
            _bind(p, s);
            bound++;
        }
    }

    /// Pays the scouts for `day` in one go. Every recipient must be a scout with at least
    /// MIN_PARTNERS bound partners, the day must be over or current and not paid yet. Amounts are
    /// USDC base units (6 decimals); the contract must hold their sum, otherwise nothing is paid.
    function pay(uint32 day, address[] calldata scouts, uint256[] calldata amounts) external onlyOperator {
        if (scouts.length != amounts.length) revert LengthMismatch();
        if (dayPaid[day]) revert DayAlreadyPaid(day);
        if (day > block.timestamp / 1 days) revert FutureDay(day);
        dayPaid[day] = true;

        uint256 total;
        for (uint256 i = 0; i < scouts.length; i++) {
            address s = scouts[i];
            if (!isScout[s]) revert NotScout(s);
            if (partnerCount[s] < MIN_PARTNERS) revert BelowThreshold(s);
            uint256 amount = amounts[i];
            total += amount;
            if (!usdc.transfer(s, amount)) revert TransferFailed();
            emit Paid(day, s, amount);
        }
        emit DayPaid(day, scouts.length, total);
    }

    // ---- Treasury ----

    function withdraw(address to, uint256 amount) external onlyTreasury {
        if (to == address(0)) revert ZeroAddress();
        if (!usdc.transfer(to, amount)) revert TransferFailed();
        emit Withdrawn(to, amount);
    }

    function setOperator(address operator_) external onlyTreasury {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorChanged(operator_);
    }

    function setTreasury(address treasury_) external onlyTreasury {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryChanged(treasury_);
    }

    // ---- Views ----

    function balance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function _bind(address partner, address scout) private {
        uint64 at = uint64(block.timestamp);
        scoutOf[partner] = scout;
        boundAt[partner] = at;
        partnerCount[scout] += 1;
        emit PartnerBound(partner, scout, at);
    }
}
