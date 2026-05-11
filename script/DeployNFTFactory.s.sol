// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoNFTFactory} from "../src/HongBao/nft/HongBaoNFTFactory.sol";
import {MockERC721} from "../test/mocks/MockERC721.sol";

/// @title DeployNFTFactory — 部署 HongBaoNFTFactory（以及可选的首个 HongBaoNFTPool）
///
/// @notice 部署流程：
///           1. 若未指定 COLLECTION，则部署 MockERC721 并调用一次 freeMint()
///              给部署者发一个 tokenId（其他参与者后续也可自助 freeMint）
///           2. 部署 HongBaoNFTFactory
///           3. 若 CREATE_POOL=true（默认），通过 factory 创建一个
///              (collection, initiator) pool
///
/// @notice 环境变量：
///           COLLECTION  — 已有 ERC721 地址（可选，留空则部署 MockERC721）
///           INITIATOR   — Pool 的 initiator（可选，留空默认为部署者）；
///                         NFT pool 没有开放模式，initiator 必须非零
///           CREATE_POOL — 是否顺带创建首个 pool（可选，默认 true）
///
/// @notice 用法：
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
