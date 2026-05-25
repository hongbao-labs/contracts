// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {HongBaoNFTPool} from "./HongBaoNFTPool.sol";
import {IHongBaoNFTFactory} from "./interfaces/IHongBaoNFTFactory.sol";

/// @title HongBaoNFTFactory
/// @notice Deterministic registry-factory for `HongBaoNFTPool` instances.
///         NFT pools are restricted-mode only — `initiator` must be non-zero.
///
/// @dev    Each `(collection, initiator)` pair maps to a unique pool. Pools
///         are deployed with CREATE2 using `salt = keccak256(collection,
///         initiator)` and their addresses may be precomputed via
///         `computePoolAddress` before deployment.
///
///         TRUST ASSUMPTION — the factory does NOT vet `collection`. A
///         malicious or upgradeable ERC721 implementation can register
///         phantom cards (no NFT actually held) and permanently brick
///         `unlockAddress` slots, since cards on `HongBaoNFTPool` are
///         one-shot. See `HongBaoNFTPool` doc header for the full trust
///         model. Callers and integrators MUST independently audit
///         `collection` (preferably non-upgradeable, audited, standard
///         ERC721 behavior) before relying on a pool returned by this
///         factory.
contract HongBaoNFTFactory is IHongBaoNFTFactory {
    /// @inheritdoc IHongBaoNFTFactory
    mapping(address => mapping(address => address)) public pools;

    /// @inheritdoc IHongBaoNFTFactory
    function createPool(address collection, address initiator) external returns (address pool) {
        if (collection == address(0)) revert ZeroAddress();
        if (initiator == address(0)) revert ZeroInitiator();

        address existing = pools[collection][initiator];
        if (existing != address(0)) revert PoolExists(collection, initiator, existing);

        bytes32 salt = keccak256(abi.encode(collection, initiator));
        pool = address(new HongBaoNFTPool{salt: salt}(collection, initiator));

        pools[collection][initiator] = pool;

        emit PoolCreated(collection, initiator, pool);
    }

    /// @inheritdoc IHongBaoNFTFactory
    function computePoolAddress(address collection, address initiator) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(collection, initiator));
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(HongBaoNFTPool).creationCode, abi.encode(collection, initiator)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
