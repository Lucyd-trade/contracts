// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Signed intent matching crates/api's SettlementOrderV1 exactly.
/// @dev Amounts are integer asset units; no decimal conversion occurs here.
struct SettlementOrderV1 {
    uint16 protocolVersion;
    address maker;
    address signer;
    address taker;
    bytes32 outcomeId;
    bytes32 marketId;
    uint8 side;
    uint8 timeInForce;
    uint64 makerAmount;
    uint64 takerAmount;
    uint64 minFillAmount;
    uint64 expiration;
    uint64 nonceEpoch;
    bytes32 salt;
}

/// @notice Shared order identity for CLOB settlement.
/// @dev Hashing does not validate signatures, authorize transfers, or settle orders.
abstract contract SettlementOrderHashing {
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "SettlementOrderV1(uint16 protocolVersion,address maker,address signer,address taker,bytes32 outcomeId,bytes32 marketId,uint8 side,uint8 timeInForce,uint64 makerAmount,uint64 takerAmount,uint64 minFillAmount,uint64 expiration,uint64 nonceEpoch,bytes32 salt)"
    );
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("Exchange");
    bytes32 private constant VERSION_HASH = keccak256("1");

    /// @notice Domain for this deployment and current chain, including after a chain-ID change.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    /// @notice Canonical orderId used by the existing Rust API.
    function hashOrder(SettlementOrderV1 calldata order) public view returns (bytes32) {
        return _hashOrder(order, domainSeparator());
    }

    function _hashOrder(SettlementOrderV1 calldata order, bytes32 domain) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domain, keccak256(abi.encode(ORDER_TYPEHASH, order))));
    }
}
