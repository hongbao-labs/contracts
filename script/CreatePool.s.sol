// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoTokenFactory} from "../src/HongBao/token/HongBaoTokenFactory.sol";

/// @title CreatePool — deploy a HongBaoTokenPool via the factory
///
/// @notice Environment variables:
///           FACTORY    — HongBaoTokenFactory address
///           TOKEN      — ERC20 token to lock
///           INITIATOR  — sole depositor; pass 0x0 for open pools
///
/// @notice Usage:
///   FACTORY=0x... TOKEN=0x... INITIATOR=0x... \
///   forge script script/CreatePool.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract CreatePool is Script {
    function run() external returns (address pool) {
        HongBaoTokenFactory factory = HongBaoTokenFactory(vm.envAddress("FACTORY"));
        address token = vm.envAddress("TOKEN");
        address initiator = vm.envAddress("INITIATOR");

        address predicted = factory.computePoolAddress(token, initiator);

        console.log("=========================================");
        console.log("  HongBaoTokenFactory.createPool");
        console.log("=========================================");
        console.log("Factory:   ", address(factory));
        console.log("Token:     ", token);
        console.log("Initiator: ", initiator);
        console.log("Predicted: ", predicted);

        vm.startBroadcast();
        pool = factory.createPool(token, initiator);
        vm.stopBroadcast();

        require(pool == predicted, "deployed address diverges from prediction");
        console.log("Pool:      ", pool);
    }
}
