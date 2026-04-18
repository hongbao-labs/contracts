// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {HongBaoPool} from "./HongBaoPool.sol";
import {IHongBaoFactory} from "./interfaces/IHongBaoFactory.sol";

/// @title HongBaoFactory
/// @notice Deterministic registry-factory for `HongBaoPool` instances. The
///         factory holds no privileges over deployed pools — it is a standard
///         publication point so that callers can discover and verify pools
///         through on-chain events and the `pools` registry.
///
/// @dev    Each `(token, initiator)` pair maps to a unique pool. Pools are
///         deployed with CREATE2 using `salt = keccak256(token, initiator)`,
///         and their addresses may be precomputed via `computePoolAddress`
///         before deployment.
contract HongBaoFactory is IHongBaoFactory {
    /// @inheritdoc IHongBaoFactory
    mapping(address => mapping(address => address)) public pools;

    /// @inheritdoc IHongBaoFactory
    function createPool(address token, address initiator) external returns (address pool) {
        if (token == address(0)) revert ZeroAddress();

        address existing = pools[token][initiator];
        if (existing != address(0)) revert PoolExists(token, initiator, existing);

        bytes32 salt = keccak256(abi.encode(token, initiator));
        pool = address(new HongBaoPool{salt: salt}(token, initiator));

        pools[token][initiator] = pool;

        emit PoolCreated(token, initiator, pool);
    }

    /// @inheritdoc IHongBaoFactory
    function computePoolAddress(address token, address initiator) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(token, initiator));
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(HongBaoPool).creationCode, abi.encode(token, initiator)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))))
        );
    }
}
