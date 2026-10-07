// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Sepolia:
// PRIVATE_KEY=... USDC_ADDRESS=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 \
// PYTH_ADDRESS=0xBb86bCc951A62DF86826219d9251Ee05F2c1e286 TREASURY_ADDRESS=... \
// forge script script/DeployAll.s.sol --rpc-url sepolia --broadcast
//
// The CLOB exchange (ClobSettlement) is deployed afterwards from the Exchange repo against the new factory.

import "forge-std/Script.sol";
import "../src/ConditionalTokens.sol";
import "../src/MarketFactory.sol";
import "../src/PriceResolver.sol";
import "../src/AutoRedeemer.sol";

contract DeployAll is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(privateKey);

        address usdc      = vm.envAddress("USDC_ADDRESS");
        address pyth      = vm.envAddress("PYTH_ADDRESS");
        address treasury  = vm.envAddress("TREASURY_ADDRESS");
        // Fee on winning redemptions, bps (max 300). Changeable later via ctf.setFeeBps for new markets.
        uint256 feeBps    = vm.envOr("FEE_BPS", uint256(0));
        // Optional Safe: ownership is offered to it at the end; the Safe must call acceptOwnership on each contract.
        address newOwner  = vm.envOr("NEW_OWNER", address(0));

        // Precompute factory address: nonce+0=CTF, nonce+1=Factory.
        address factoryAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);

        vm.startBroadcast(privateKey);

        ConditionalTokens ctf      = new ConditionalTokens(usdc, treasury, feeBps, factoryAddr);
        MarketFactory     factory  = new MarketFactory(address(ctf), deployer);

        require(address(factory) == factoryAddr, "factory address mismatch");

        PriceResolver priceResolver = new PriceResolver(pyth, address(ctf), address(factory));
        for (uint8 i = 0; i <= 5; i++) {
            factory.setResolverForType(i, address(priceResolver));
        }

        AutoRedeemer autoRedeemer = new AutoRedeemer(address(ctf));

        if (newOwner != address(0)) {
            ctf.transferOwnership(newOwner);
            factory.transferOwnership(newOwner);
        }

        vm.stopBroadcast();

        console.log("USDC:              ", usdc);
        console.log("ConditionalTokens: ", address(ctf));
        console.log("MarketFactory:     ", address(factory));
        console.log("PriceResolver:     ", address(priceResolver));
        console.log("AutoRedeemer:      ", address(autoRedeemer));
        if (newOwner != address(0)) console.log("Pending owner (must acceptOwnership):", newOwner);
    }
}
