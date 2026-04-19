// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoNFTFactory} from "../src/HongBao/nft/HongBaoNFTFactory.sol";

/// @title DeployNFTFactory — deploy a fresh HongBaoNFTFactory
/// @notice Usage:
///   forge script script/DeployNFTFactory.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract DeployNFTFactory is Script {
    function run() external returns (HongBaoNFTFactory factory) {
        vm.startBroadcast();
        factory = new HongBaoNFTFactory();
        vm.stopBroadcast();

        console.log("=========================================");
        console.log("  HongBaoNFTFactory deployed");
        console.log("=========================================");
        console.log("Factory:", address(factory));
    }
}
