// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SignTest.sol";

contract SignTestTest is Test {
    SignTest public signTest;

    function setUp() public {
        signTest = new SignTest();
    }

    function test_getMessage() public view {
        assertEq(signTest.getMessage(), "hello world");
    }

    function test_getDigest() public view {
        bytes32 expected = keccak256("hello world");
        assertEq(signTest.getDigest(), expected);
    }

    function test_verify_with_foundry_key() public {
        // Use a foundry test private key to verify the contract logic works
        uint256 pk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address signer = vm.addr(pk);

        bytes32 digest = signTest.getDigest();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        bool valid = signTest.verify(signer, digest, v, r, s);
        assertTrue(valid);
    }

    function test_verify_wrong_signer() public {
        uint256 pk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address wrongSigner = address(0xdead);

        bytes32 digest = signTest.getDigest();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        bool valid = signTest.verify(wrongSigner, digest, v, r, s);
        assertFalse(valid);
    }
}
