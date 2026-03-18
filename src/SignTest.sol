// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract SignTest {
    event SignatureVerified(address indexed signer, bytes32 indexed digest, bool valid);

    function getMessage() external pure returns (string memory) {
        return "hello world";
    }

    function getDigest() external pure returns (bytes32) {
        return keccak256("hello world");
    }

    function verify(address signer, bytes32 digest, uint8 v, bytes32 r, bytes32 s) external returns (bool) {
        address recovered = ecrecover(digest, v, r, s);
        bool valid = (recovered != address(0)) && (recovered == signer);
        emit SignatureVerified(signer, digest, valid);
        return valid;
    }
}
