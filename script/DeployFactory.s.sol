// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoFactory} from "../src/HongBao/HongBaoFactory.sol";

/// @title DeployFactory — deploy a fresh HongBaoFactory
/// @notice Usage:
///   forge script script/DeployFactory.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract DeployFactory is Script {
    function run() external returns (HongBaoFactory factory) {
        vm.startBroadcast();
        factory = new HongBaoFactory();
        vm.stopBroadcast();

        console.log("=========================================");
        console.log("  HongBaoFactory deployed");
        console.log("=========================================");
        console.log("Factory:", address(factory));
    }
}
