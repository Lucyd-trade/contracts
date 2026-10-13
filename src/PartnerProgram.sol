// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IERC20.sol";

/// Partner (affiliate) program: partners, the traders they brought, and daily USDC payouts.
///
/// Partners earn a share of the volume their traders take from the market maker. The share is
/// computed off chain from Exchange fills (the formula and a script to re-check it are published);
/// this contract keeps the public record a partner can verify against: who is a partner, which
/// trader is bound to whom and since which block, and what was paid for which day.
///
/// Two keys. The operator (a server key) adds partners, binds traders and sends the daily payout;
/// it can move USDC only to partners and at most once per day. The treasury withdraws USDC and
/// replaces the operator. The contract holds about a week of payouts, so a stolen operator key
/// can lose at most the balance. A binding is permanent: no function changes or removes it.
contract PartnerProgram {
    IERC20 public immutable usdc;
    address public treasury;
    address public operator;

    mapping(address => bool) public isPartner;
    /// Partner a trader is bound to; zero if none.
    mapping(address => address) public partnerOf;
    /// Days (unix time / 1 days) already paid.
    mapping(uint32 => bool) public dayPaid;

    error NotOperator();
    error NotTreasury();
    error ZeroAddress();
    error NotPartner(address account);
    error AlreadyBound(address trader);
    error SelfReferral(address trader);
    error DayAlreadyPaid(uint32 day);
    error FutureDay(uint32 day);
    error LengthMismatch();
    error TransferFailed();

    event PartnerAdded(address indexed partner);
    event TraderBound(address indexed trader, address indexed partner);
    event Paid(uint32 indexed day, address indexed partner, uint256 amount);
    event DayPaid(uint32 indexed day, uint256 partners, uint256 total);
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

    constructor(address usdc_, address treasury_, address operator_) {
        if (usdc_ == address(0) || treasury_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        treasury = treasury_;
        operator = operator_;
        emit TreasuryChanged(treasury_);
        emit OperatorChanged(operator_);
    }

    // ---- Operator ----

    /// Adds partners; ones already added are skipped, so a re-sent batch is harmless.
    function addPartners(address[] calldata partners) external onlyOperator {
        for (uint256 i = 0; i < partners.length; i++) {
            address p = partners[i];
            if (p == address(0)) revert ZeroAddress();
            if (isPartner[p]) continue;
            isPartner[p] = true;
            emit PartnerAdded(p);
        }
    }

    /// Binds one trader to a partner for good. Reverts unless the partner exists, the trader is
    /// not bound yet and is not the partner itself.
    function bindTrader(address trader, address partner) external onlyOperator {
        if (trader == address(0)) revert ZeroAddress();
        if (!isPartner[partner]) revert NotPartner(partner);
        if (partnerOf[trader] != address(0)) revert AlreadyBound(trader);
        if (trader == partner) revert SelfReferral(trader);
        _bind(trader, partner);
    }

    /// Batch of bindTrader with the same checks, except that an entry failing them is skipped
    /// instead of reverting the batch. Returns how many were bound.
    function bindTraders(address[] calldata traders, address[] calldata partners) external onlyOperator returns (uint256 bound) {
        if (traders.length != partners.length) revert LengthMismatch();
        for (uint256 i = 0; i < traders.length; i++) {
            address t = traders[i];
            address p = partners[i];
            if (t == address(0) || t == p || !isPartner[p] || partnerOf[t] != address(0)) continue;
            _bind(t, p);
            bound++;
        }
    }

    /// Pays the partners for `day` in one go. Every recipient must be a partner, the day must be
    /// over or current and not paid yet. Amounts are USDC base units (6 decimals); the contract
    /// must hold their sum, otherwise nothing is paid.
    function pay(uint32 day, address[] calldata partners, uint256[] calldata amounts) external onlyOperator {
        if (partners.length != amounts.length) revert LengthMismatch();
        if (dayPaid[day]) revert DayAlreadyPaid(day);
        if (day > block.timestamp / 1 days) revert FutureDay(day);
        dayPaid[day] = true;

        uint256 total;
        for (uint256 i = 0; i < partners.length; i++) {
            address p = partners[i];
            if (!isPartner[p]) revert NotPartner(p);
            uint256 amount = amounts[i];
            total += amount;
            if (!usdc.transfer(p, amount)) revert TransferFailed();
            emit Paid(day, p, amount);
        }
        emit DayPaid(day, partners.length, total);
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

    function _bind(address trader, address partner) private {
        partnerOf[trader] = partner;
        emit TraderBound(trader, partner);
    }
}
