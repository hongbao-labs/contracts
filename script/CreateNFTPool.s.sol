// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoNFTFactory} from "../src/HongBao/nft/HongBaoNFTFactory.sol";

/// @title CreateNFTPool — deploy a HongBaoNFTPool via the factory
///
/// @notice Environment variables:
///           FACTORY     — HongBaoNFTFactory address
///           COLLECTION  — ERC721 collection to lock
///           INITIATOR   — sole depositor; required (NFT pools have no open mode)
///
/// @notice Usage:
///   FACTORY=0x... COLLECTION=0x... INITIATOR=0x... \
///   forge script script/CreateNFTPool.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract CreateNFTPool is Script {
    function run() external returns (address pool) {
        HongBaoNFTFactory factory = HongBaoNFTFactory(vm.envAddress("FACTORY"));
        address collection = vm.envAddress("COLLECTION");
        address initiator = vm.envAddress("INITIATOR");

        require(initiator != address(0), "INITIATOR required (NFT pools are restricted-mode only)");

        address predicted = factory.computePoolAddress(collection, initiator);

        console.log("=========================================");
        console.log("  HongBaoNFTFactory.createPool");
        console.log("=========================================");
        console.log("Factory:    ", address(factory));
        console.log("Collection: ", collection);
        console.log("Initiator:  ", initiator);
        console.log("Predicted:  ", predicted);

        vm.startBroadcast();
        pool = factory.createPool(collection, initiator);
        vm.stopBroadcast();

        require(pool == predicted, "deployed address diverges from prediction");
        console.log("Pool:       ", pool);
    }
}
