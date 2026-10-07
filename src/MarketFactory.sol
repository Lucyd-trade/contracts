// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ConditionalTokens.sol";

contract MarketFactory {
    enum MarketType {
        UpDownDaily,              // 0
        UpDown5m,                 // 1
        UpDown15m,                // 2
        UpDown30m,                // 3
        UpDown1h,                 // 4
        UpDown4h                  // 5
    }

    uint8 internal constant MAX_MARKET_TYPE = 5;

    struct MarketInfo {
        uint8 marketType;
        bytes32 feedA;
        bytes32 feedB;
        int256 strike;        // reference price at referenceTs
        int256 upperStrike;   // unused, kept so the marketInfo/MarketActivated layout stays stable
        uint256 referenceTs;
        uint256 settlementTs;
        bool exists;
        bool active;
    }

    ConditionalTokens public immutable ctf;
    address public owner;
    address public pendingOwner;

    mapping(uint8 => address) public resolverForType;
    mapping(bytes32 => MarketInfo) public marketInfo;
    bytes32[] public marketIds;
    mapping(address => bool) public creators;

    error UnknownMarketType();
    error InvalidTimestamps();
    error MarketAlreadyExists();
    error MarketNotFound();
    error MarketAlreadyActive();
    error NotOwner();
    error NotCreator();
    error ResolverNotSet();
    error ZeroAddress();

    event MarketCreated(bytes32 indexed marketId, uint8 marketType, uint256 indexed index);
    event MarketActivated(bytes32 indexed marketId, int256 strike, int256 upperStrike);
    event ResolverTypeSet(uint8 indexed marketType, address indexed resolver);
    event CreatorAdded(address indexed creator);
    event CreatorRemoved(address indexed creator);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address ctf_, address owner_) {
        if (ctf_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        ctf = ConditionalTokens(ctf_);
        owner = owner_;
    }

    /// Two-step: the new owner (e.g. a Safe) must call acceptOwnership. address(0) cancels a pending transfer.
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function addCreator(address c) external {
        if (msg.sender != owner) revert NotOwner();
        creators[c] = true;
        emit CreatorAdded(c);
    }

    function removeCreator(address c) external {
        if (msg.sender != owner) revert NotOwner();
        creators[c] = false;
        emit CreatorRemoved(c);
    }

    function setResolverForType(uint8 marketType, address resolver_) external {
        if (msg.sender != owner) revert NotOwner();
        if (resolver_ == address(0)) revert ZeroAddress();
        resolverForType[marketType] = resolver_;
        emit ResolverTypeSet(marketType, resolver_);
    }

    // Phase 1: register shell (no strike yet, active=false)
    function createMarketShell(
        uint8 marketType,
        bytes32 feedA,
        bytes32 feedB,
        uint256 referenceTs,
        uint256 settlementTs,
        uint256 index
    ) external returns (bytes32 marketId) {
        if (!creators[msg.sender] && msg.sender != owner) revert NotCreator();
        if (marketType > MAX_MARKET_TYPE) revert UnknownMarketType();
        _checkTs(referenceTs, settlementTs);
        marketId = keccak256(abi.encode(marketType, feedA, feedB, referenceTs, settlementTs, index));
        _registerShell(marketId, marketType, feedA, feedB, referenceTs, settlementTs);
    }

    // Phase 2: set strike and flip active=true
    function activateMarket(bytes32 marketId, int256 strike, int256 upperStrike) external {
        if (!creators[msg.sender] && msg.sender != owner) revert NotCreator();
        MarketInfo storage info = marketInfo[marketId];
        if (!info.exists) revert MarketNotFound();
        if (info.active) revert MarketAlreadyActive();
        info.strike = strike;
        info.upperStrike = upperStrike;
        info.active = true;
        emit MarketActivated(marketId, strike, upperStrike);
    }

    // Returns true for unknown marketIds (backwards compat) or active markets.
    function isMarketActive(bytes32 marketId) external view returns (bool) {
        MarketInfo storage info = marketInfo[marketId];
        if (!info.exists) return true;
        return info.active;
    }

    // Legacy one-shot creation (active=true immediately) — kept for compatibility
    function createMarket(
        uint8 marketType,
        bytes32 feedA,
        bytes32 feedB,
        int256 referenceRatio,
        uint256 referenceTs,
        uint256 settlementTs
    ) external returns (bytes32 marketId) {
        if (!creators[msg.sender] && msg.sender != owner) revert NotCreator();
        if (marketType > MAX_MARKET_TYPE) revert UnknownMarketType();
        _checkTs(referenceTs, settlementTs);
        marketId = keccak256(abi.encode(marketType, feedA, feedB, referenceRatio, referenceTs, settlementTs));
        _register(marketId, marketType, feedA, feedB, referenceRatio, 0, referenceTs, settlementTs);
    }

    function _checkTs(uint256 referenceTs, uint256 settlementTs) internal view {
        if (settlementTs <= referenceTs) revert InvalidTimestamps();
        if (settlementTs <= block.timestamp) revert InvalidTimestamps();
    }

    function _registerShell(
        bytes32 marketId,
        uint8 marketType,
        bytes32 feedA,
        bytes32 feedB,
        uint256 referenceTs,
        uint256 settlementTs
    ) internal {
        address resolver = resolverForType[marketType];
        if (resolver == address(0)) revert ResolverNotSet();
        if (marketInfo[marketId].exists) revert MarketAlreadyExists();

        marketInfo[marketId] = MarketInfo({
            marketType: marketType,
            feedA: feedA,
            feedB: feedB,
            strike: 0,
            upperStrike: 0,
            referenceTs: referenceTs,
            settlementTs: settlementTs,
            exists: true,
            active: false
        });

        marketIds.push(marketId);
        ctf.registerMarket(marketId, resolver);
        emit MarketCreated(marketId, marketType, marketIds.length - 1);
    }

    function _register(
        bytes32 marketId,
        uint8 marketType,
        bytes32 feedA,
        bytes32 feedB,
        int256 strike,
        int256 upperStrike,
        uint256 referenceTs,
        uint256 settlementTs
    ) internal {
        address resolver = resolverForType[marketType];
        if (resolver == address(0)) revert ResolverNotSet();
        if (marketInfo[marketId].exists) revert MarketAlreadyExists();

        marketInfo[marketId] = MarketInfo({
            marketType: marketType,
            feedA: feedA,
            feedB: feedB,
            strike: strike,
            upperStrike: upperStrike,
            referenceTs: referenceTs,
            settlementTs: settlementTs,
            exists: true,
            active: true
        });

        marketIds.push(marketId);
        ctf.registerMarket(marketId, resolver);
        emit MarketCreated(marketId, marketType, marketIds.length - 1);
    }

    function marketsCount() external view returns (uint256) {
        return marketIds.length;
    }

    function getMarketIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory result) {
        uint256 total = marketIds.length;
        if (offset >= total) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        result = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = marketIds[i];
        }
    }
}
