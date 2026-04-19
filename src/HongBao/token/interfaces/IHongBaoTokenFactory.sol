// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHongBaoTokenFactory
/// @notice Deterministic registry-factory for `HongBaoTokenPool` instances.
///         Each (token, initiator) pair maps to at most one pool. The factory
///         is stateless beyond this registry — it does not administer pools.
///
/// @dev    Pools are deployed with CREATE2 using `salt = keccak256(token,
///         initiator)`, so their addresses are knowable off-chain before
///         deployment via `computePoolAddress`.
interface IHongBaoTokenFactory {
    /// @notice Emitted when a new pool is deployed.
    event PoolCreated(address indexed token, address indexed initiator, address pool);

    error ZeroAddress();
    error PoolExists(address token, address initiator, address existing);

    /// @notice Registered pool for a given (token, initiator) pair. Returns
    ///         `address(0)` if not yet deployed.
    function pools(address token, address initiator) external view returns (address);

    /// @notice Deploy a new pool for `(token, initiator)`. Reverts if one
    ///         already exists for that pair.
    /// @param token     ERC20 token address; must be non-zero.
    /// @param initiator Optional sole-depositor address. Zero means open.
    /// @return pool     The address of the newly deployed pool.
    function createPool(address token, address initiator) external returns (address pool);

    /// @notice Deterministic address a pool for `(token, initiator)` would
    ///         occupy, regardless of whether it has been deployed.
    function computePoolAddress(address token, address initiator) external view returns (address);
}
