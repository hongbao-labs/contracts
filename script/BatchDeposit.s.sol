// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Agora/ForgePool.sol";
import {IERC20} from "../src/Agora/IERC20.sol";

/// @title BatchDeposit — 项目方批量 mint 脚本
/// @notice 从 JSON 文件读取设备公钥地址列表，批量调用 ForgePool.batchDeposit
///
/// 环境变量:
///   FORGEPOOL       — ForgePool 合约地址
///   AMOUNT_ETHER    — 每张卡片锁定数量（整数，单位 ether，如 100）
///   LOCK_DAYS       — 锁定天数（如 180）
///   ADDRESSES_JSON  — 地址列表 JSON 文件路径（相对于 contract/ 目录）
///
/// JSON 文件格式:
///   { "addresses": ["0xAbc...", "0xDef...", ...] }
///
/// 用法:
///   cd contract
///
///   FORGEPOOL=0x... AMOUNT_ETHER=100 LOCK_DAYS=180 ADDRESSES_JSON=./addresses.json \
///   forge script script/BatchDeposit.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract BatchDeposit is Script {
    function run() external {
        ForgePool pool = ForgePool(vm.envAddress("FORGEPOOL"));
        uint256 amount = vm.envUint("AMOUNT_ETHER") * 1 ether;
        uint256 lockTime = vm.envUint("LOCK_DAYS") * 1 days;

        string memory json = vm.readFile(vm.envString("ADDRESSES_JSON"));
        address[] memory addresses = vm.parseJsonAddressArray(json, ".addresses");
        require(addresses.length > 0, "addresses array is empty");

        address token = pool.lockedToken();
        uint256 totalAmount = amount * addresses.length;

        console.log("=========================================");
        console.log("  ForgePool BatchDeposit");
        console.log("=========================================");
        console.log("ForgePool:", address(pool));
        console.log("Token:    ", token);
        console.log("Count:    ", addresses.length);
        console.log("Total:    ", totalAmount / 1 ether, "ether");

        require(pool.isMinter(msg.sender), "sender is not in minter whitelist");
        require(IERC20(token).balanceOf(msg.sender) >= totalAmount, "insufficient token balance");

        vm.startBroadcast();

        if (IERC20(token).allowance(msg.sender, address(pool)) < totalAmount) {
            console.log(">>> Approving...");
            IERC20(token).approve(address(pool), totalAmount);
        }

        pool.batchDeposit(addresses, amount, lockTime);
        vm.stopBroadcast();
    }
}
