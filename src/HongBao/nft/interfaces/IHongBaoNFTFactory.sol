// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHongBaoNFTFactory
/// @notice Deterministic registry-factory for `HongBaoNFTPool` instances.
///         Each `(collection, initiator)` pair maps to at most one pool, and
///         `initiator` must be non-zero (NFT pools are restricted-mode only).
///         The factory is stateless beyond this registry.
///
/// @dev    Pools are deployed with CREATE2 using
///         `salt = keccak256(collection, initiator)`, so their addresses are
///         knowable off-chain before deployment via `computePoolAddress`.
interface IHongBaoNFTFactory {
    /// @notice Emitted when a new pool is deployed.
    event PoolCreated(address indexed collection, address indexed initiator, address pool);

    error ZeroAddress();
    error ZeroInitiator();
    error PoolExists(address collection, address initiator, address existing);

    /// @notice Registered pool for a given (collection, initiator) pair.
    ///         Returns `address(0)` if not yet deployed.
    function pools(address collection, address initiator) external view returns (address);

    /// @notice Deploy a new pool for `(collection, initiator)`. Reverts if
    ///         `collection` or `initiator` is zero, or a pool already exists
    ///         for that pair.
    function createPool(address collection, address initiator) external returns (address pool);

    /// @notice Deterministic address a pool for `(collection, initiator)` would
    ///         occupy, regardless of whether it has been deployed.
    function computePoolAddress(address collection, address initiator) external view returns (address);
}
