// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Script, console2 } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";

contract TenderlyVerifyScript is Script {
  using stdJson for string;

  string[] public chains = ["sepolia", "mainnet", "optimism", "arbitrum", "polygon", "base", "celo", "gnosis"];

  // Assumes the contract is deployed to the same address on all chains
  address constant DEPLOYED_ADDRESS = address(1); // TODO: Change this to the actual address of the contract
  string constant CONTRACT_NAME = "Counter"; // TODO: Change this to the actual name of the contract

  function verifyChain(string memory chain) internal returns (bool) {
    console2.log("\nVerifying on", chain);

    try vm.createSelectFork(vm.rpcUrl(chain)) returns (uint256) {
      string memory account = vm.envString("TENDERLY_ACCOUNT");
      string memory project = vm.envString("TENDERLY_PROJECT");

      string memory verifierUrl = string.concat(
        "https://api.tenderly.co/api/v1/account/",
        account,
        "/project/",
        project,
        "/etherscan/verify/network/",
        vm.toString(block.chainid),
        "/public"
      );

      console2.log("Chain ID:", block.chainid);
      console2.log("Verifying contract at:", DEPLOYED_ADDRESS);
      console2.log("Verifier URL:", verifierUrl);

      // Create the verification command
      string[] memory inputs = new string[](9);
      inputs[0] = "forge";
      inputs[1] = "verify-contract";
      inputs[2] = vm.toString(DEPLOYED_ADDRESS);
      inputs[3] = CONTRACT_NAME;
      inputs[4] = "--etherscan-api-key";
      inputs[5] = vm.envString("TENDERLY_ACCESS_KEY");
      inputs[6] = "--verifier-url";
      inputs[7] = verifierUrl;
      inputs[8] = "--watch";

      try vm.ffi(inputs) {
        console2.log("Verification successful on", chain);
        return true;
      } catch Error(string memory reason) {
        console2.log("Verification failed on", chain, ":", reason);
        return false;
      }
    } catch Error(string memory reason) {
      console2.log("Failed to fork", chain, ":", reason);
      return false;
    }
  }

  function run() external {
    for (uint256 i = 0; i < chains.length; i++) {
      verifyChain(chains[i]);
    }
  }

  // forge script script/TenderlyVerify.s.sol --ffi
}
