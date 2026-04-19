// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoTokenFactory} from "../src/HongBao/token/HongBaoTokenFactory.sol";

/// @title DeployFactory — deploy a fresh HongBaoTokenFactory
/// @notice Usage:
///   forge script script/DeployFactory.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract DeployFactory is Script {
    function run() external returns (HongBaoTokenFactory factory) {
        vm.startBroadcast();
        factory = new HongBaoTokenFactory();
        vm.stopBroadcast();

        console.log("=========================================");
        console.log("  HongBaoTokenFactory deployed");
        console.log("=========================================");
        console.log("Factory:", address(factory));
    }
}
