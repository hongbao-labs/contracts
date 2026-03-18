// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/SignTest.sol";

/// @notice End-to-end test script: deploy contract, then verify device signature
/// Usage: forge script script/E2ETest.s.sol --sig "run(address,uint8,bytes32,bytes32)"
///        <signer> <v> <r> <s>
contract E2ETest is Script {
    function run(address signer, uint8 v, bytes32 r, bytes32 s) external {
        vm.startBroadcast();
        SignTest signTest = new SignTest();
        vm.stopBroadcast();

        // Step 1: Get digest from contract
        string memory message = signTest.getMessage();
        bytes32 digest = signTest.getDigest();
        console.log("Message:", message);
        console.log("Digest:");
        console.logBytes32(digest);

        // Step 2: Verify device signature on-chain
        console.log("Signer address:", signer);
        console.log("v:", v);
        console.log("r:");
        console.logBytes32(r);
        console.log("s:");
        console.logBytes32(s);

        bool valid = signTest.verify(signer, digest, v, r, s);
        console.log("Verification result:", valid);

        require(valid, "Signature verification FAILED");
        console.log("SUCCESS: Device signature verified on-chain!");
    }
}
