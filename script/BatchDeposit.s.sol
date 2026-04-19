// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoTokenPool} from "../src/HongBao/token/HongBaoTokenPool.sol";
import {IERC20} from "../src/HongBao/shared/interfaces/IERC20.sol";

/// @title BatchDeposit — project-side script to mint a batch of locked cards
///
/// @notice Reads a JSON list of card addresses and calls
///         `HongBaoTokenPool.batchDeposit`.
///
/// @notice Environment variables:
///           POOL            — HongBaoTokenPool address
///           AMOUNT_ETHER    — per-card amount in whole tokens (e.g. "100")
///           LOCK_DAYS       — lock duration in days (must be >= 30)
///           ADDRESSES_JSON  — path to JSON file of card addresses
///
/// @notice JSON format:
///           { "addresses": ["0xAbc...", "0xDef...", ...] }
///
/// @notice Usage:
///   POOL=0x... AMOUNT_ETHER=100 LOCK_DAYS=30 ADDRESSES_JSON=./addresses.json \
///   forge script script/BatchDeposit.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract BatchDeposit is Script {
    function run() external {
        HongBaoTokenPool pool = HongBaoTokenPool(vm.envAddress("POOL"));
        uint256 amount = vm.envUint("AMOUNT_ETHER") * 1 ether;
        uint256 lockTime = vm.envUint("LOCK_DAYS") * 1 days;

        string memory json = vm.readFile(vm.envString("ADDRESSES_JSON"));
        address[] memory addresses = vm.parseJsonAddressArray(json, ".addresses");
        require(addresses.length > 0, "addresses array is empty");

        address token = pool.lockedToken();
        address poolInitiator = pool.initiator();
        uint256 totalAmount = amount * addresses.length;

        console.log("=========================================");
        console.log("  HongBaoTokenPool.batchDeposit");
        console.log("=========================================");
        console.log("Pool:      ", address(pool));
        console.log("Token:     ", token);
        console.log("Initiator: ", poolInitiator);
        console.log("Count:     ", addresses.length);
        console.log("Per card:  ", amount / 1 ether, "(tokens)");
        console.log("Total:     ", totalAmount / 1 ether, "(tokens)");

        require(
            poolInitiator == address(0) || poolInitiator == msg.sender,
            "sender does not match pool initiator"
        );
        require(IERC20(token).balanceOf(msg.sender) >= totalAmount, "insufficient token balance");

        vm.startBroadcast();

        if (IERC20(token).allowance(msg.sender, address(pool)) < totalAmount) {
            console.log(">>> Approving...");
            IERC20(token).approve(address(pool), totalAmount);
        }

        pool.batchDeposit(addresses, amount, lockTime);
        vm.stopBroadcast();

        console.log(">>> Done.");
    }
}
