// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Sepolia (Sepolia overestimates creation gas in simulation, hence --skip-simulation):
// PRIVATE_KEY=... USDC_ADDRESS=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 \
// TREASURY_ADDRESS=... OPERATOR_ADDRESS=<key of contracts-partners> \
// forge script script/DeployPartnerProgram.s.sol --rpc-url sepolia --broadcast --skip-simulation
//
// Then fund it with about a week of payouts (plain USDC transfer to the contract).

import "forge-std/Script.sol";
import "../src/PartnerProgram.sol";

contract DeployPartnerProgram is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");

        vm.startBroadcast(privateKey);
        PartnerProgram program = new PartnerProgram(usdc, treasury, operator);
        vm.stopBroadcast();

        console.log("PartnerProgram:", address(program));
    }
}
