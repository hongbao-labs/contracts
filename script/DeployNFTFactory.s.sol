// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoNFTFactory} from "../src/HongBao/nft/HongBaoNFTFactory.sol";
import {MockERC721} from "../test/mocks/MockERC721.sol";

/// @title DeployNFTFactory — Deploys HongBaoNFTFactory (and optionally the first HongBaoNFTPool)
///
/// @notice Deployment flow:
///           1. If COLLECTION is not specified, deploy MockERC721 and call freeMint() once
///              to issue a tokenId to the deployer (other participants can also self-serve freeMint later)
///           2. Deploy HongBaoNFTFactory
///           3. If CREATE_POOL=true (default), create a
///              (collection, initiator) pool via the factory
///
/// @notice Environment variables:
///           COLLECTION  — Existing ERC721 address (optional, leave empty to deploy MockERC721)
///           INITIATOR   — The pool's initiator (optional, leave empty to default to the deployer);
///                         NFT pools have no open mode, so initiator must be non-zero
///           CREATE_POOL — Whether to also create the first pool (optional, default true)
///
/// @notice Usage:
///   forge script script/DeployNFTFactory.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract DeployNFTFactory is Script {
    function run() external {
        address collection = vm.envOr("COLLECTION", address(0));
        address initiator = vm.envOr("INITIATOR", msg.sender);
        bool createPool = vm.envOr("CREATE_POOL", true);

        require(initiator != address(0), "INITIATOR required (NFT pools are restricted-mode only)");

        vm.startBroadcast();

        if (collection == address(0)) {
            MockERC721 mockNFT = new MockERC721("Test HongBao NFT", "HBNFT");
            collection = address(mockNFT);
            console.log("MockERC721 deployed:", collection);

            uint256 tokenId = mockNFT.freeMint();
            console.log("freeMint -> deployer, tokenId:", tokenId);
        }

        HongBaoNFTFactory factory = new HongBaoNFTFactory();
        console.log("HongBaoNFTFactory deployed:", address(factory));

        address pool;
        if (createPool) {
            pool = factory.createPool(collection, initiator);
            console.log("HongBaoNFTPool deployed:", pool);
        }

        vm.stopBroadcast();

        console.log("=========================================");
        console.log("  Deployment Summary");
        console.log("=========================================");
        console.log("Collection:        ", collection);
        console.log("HongBaoNFTFactory: ", address(factory));
        if (createPool) {
            console.log("HongBaoNFTPool:    ", pool);
            console.log("Pool.initiator:    ", initiator);
        }
    }
}
