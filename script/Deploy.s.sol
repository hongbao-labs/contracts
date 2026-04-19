// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoFactory} from "../src/HongBao/HongBaoFactory.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @title Deploy — 部署 HongBaoFactory（以及可选的首个 HongBaoPool）
///
/// @notice 部署流程：
///           1. 若未指定 TOKEN，则部署 MockERC20 并给部署者 mint 测试币
///           2. 部署 HongBaoFactory
///           3. 若 CREATE_POOL=true（默认），通过 factory 创建一个
///              (token, initiator) pool
///
/// @notice 环境变量:
///           TOKEN       — 已有 ERC20 地址（可选，留空则部署 MockERC20）
///           INITIATOR   — Pool 的 initiator；留空默认为部署者；
///                         显式传 0x000...0 表示开放池（任何人可存入）
///           CREATE_POOL — 是否顺带创建首个 pool（可选，默认 true）
///
/// @notice 用法:
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

        HongBaoFactory factory = new HongBaoFactory();
        console.log("HongBaoFactory deployed:", address(factory));

        address pool;
        if (createPool) {
            pool = factory.createPool(token, initiator);
            console.log("HongBaoPool deployed:", pool);
        }

        vm.stopBroadcast();

        console.log("=========================================");
        console.log("  Deployment Summary");
        console.log("=========================================");
        console.log("Token:          ", token);
        console.log("HongBaoFactory: ", address(factory));
        if (createPool) {
            console.log("HongBaoPool:    ", pool);
            console.log("Pool.initiator: ", initiator);
        }
    }
}
