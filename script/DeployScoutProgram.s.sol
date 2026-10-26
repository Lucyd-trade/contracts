// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Sepolia (Sepolia overestimates creation gas in simulation, hence --skip-simulation):
// PRIVATE_KEY=... USDC_ADDRESS=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 \
// PARTNER_PROGRAM_ADDRESS=0xf1552eEBe261c0438a31DcbC39c57d31Fa7b0A25 \
// TREASURY_ADDRESS=... OPERATOR_ADDRESS=<key of contracts-partners, same as PartnerProgram's operator> \
// forge script script/DeployScoutProgram.s.sol --rpc-url sepolia --broadcast --skip-simulation
//
// Then fund it with about a week of payouts (plain USDC transfer to the contract).

import "forge-std/Script.sol";
import "../src/ScoutProgram.sol";

contract DeployScoutProgram is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address partnerProgram = vm.envAddress("PARTNER_PROGRAM_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");

        vm.startBroadcast(privateKey);
        ScoutProgram program = new ScoutProgram(usdc, partnerProgram, treasury, operator);
        vm.stopBroadcast();

        console.log("ScoutProgram:", address(program));
    }
}
