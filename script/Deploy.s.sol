// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoTokenFactory} from "../src/HongBao/token/HongBaoTokenFactory.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @title Deploy — Deploys HongBaoTokenFactory (and optionally the first HongBaoTokenPool)
///
/// @notice Deployment flow:
///           1. If TOKEN is not specified, deploy MockERC20 and mint test tokens to the deployer
///           2. Deploy HongBaoTokenFactory
///           3. If CREATE_POOL=true (default), create a
///              (token, initiator) pool via the factory
///
/// @notice Environment variables:
///           TOKEN       — Existing ERC20 address (optional, leave empty to deploy MockERC20)
///           INITIATOR   — The pool's initiator; leave empty to default to the deployer;
///                         explicitly pass 0x000...0 for an open pool (anyone can deposit)
///           CREATE_POOL — Whether to also create the first pool (optional, default true)
///
/// @notice Usage:
///   forge script script/Deploy.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract Deploy is Script {
    function run() external {
        address token = vm.envOr("TOKEN", address(0));
        address initiator = vm.envOr("INITIATOR", msg.sender);
        bool createPool = vm.envOr("CREATE_POOL", true);

        vm.startBroadcast();

        if (token == address(0)) {
            MockERC20 mockToken = new MockERC20("Test USDC", "USDC", 6);
            token = address(mockToken);
            console.log("MockERC20 deployed:", token);

            mockToken.mint(msg.sender, 1_000_000 * 1e6);
            console.log("Minted 1,000,000 USDC to deployer");
        }

        HongBaoTokenFactory factory = new HongBaoTokenFactory();
        console.log("HongBaoTokenFactory deployed:", address(factory));

        address pool;
        if (createPool) {
            pool = factory.createPool(token, initiator);
            console.log("HongBaoTokenPool deployed:", pool);
        }

        vm.stopBroadcast();

        console.log("=========================================");
        console.log("  Deployment Summary");
        console.log("=========================================");
        console.log("Token:          ", token);
        console.log("HongBaoTokenFactory: ", address(factory));
        if (createPool) {
            console.log("HongBaoTokenPool:    ", pool);
            console.log("Pool.initiator: ", initiator);
        }
    }
}
