// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoLens} from "../src/HongBao/lens/HongBaoLens.sol";

/// @title DeployLens — deploy `HongBaoLens` (one-time per chain)
/// @notice Stateless read-only aggregator. Deploy once, use against any
///         `HongBaoTokenPool` / `HongBaoNFTPool` on the same chain.
///
/// @notice Usage:
///   forge script script/DeployLens.s.sol \
///     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
contract DeployLens is Script {
    function run() external returns (HongBaoLens lens) {
        vm.startBroadcast();
        lens = new HongBaoLens();
        vm.stopBroadcast();

        console.log("=========================================");
        console.log("  HongBaoLens deployed");
        console.log("=========================================");
        console.log("Lens:", address(lens));
    }
}
