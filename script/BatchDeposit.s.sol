// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoPool} from "../src/HongBao/HongBaoPool.sol";
import {IERC20} from "../src/HongBao/interfaces/IERC20.sol";

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

/// @title BatchDeposit — project-side script to mint a batch of locked cards
///
/// @notice Reads a JSON list of card addresses and calls
///         `HongBaoPool.batchDeposit`.
///
/// @notice Environment variables:
///           POOL            — HongBaoPool address
///           AMOUNT          — per-card amount in whole tokens (scaled by token.decimals())
///           LOCK_DAYS       — lock duration in days (must be >= 30)
///           ADDRESSES_JSON  — path to JSON file of card addresses
///
/// @notice JSON format:
///           { "addresses": ["0xAbc...", "0xDef...", ...] }
///
/// @notice Usage:
///   POOL=0x... AMOUNT=100 LOCK_DAYS=30 ADDRESSES_JSON=./addresses.json \
///   forge script script/BatchDeposit.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract BatchDeposit is Script {
    function run() external {
        HongBaoPool pool = HongBaoPool(vm.envAddress("POOL"));
        uint256 amountWhole = vm.envUint("AMOUNT");
        uint256 lockTime = vm.envUint("LOCK_DAYS") * 1 days;

        string memory json = vm.readFile(vm.envString("ADDRESSES_JSON"));
        address[] memory addresses = vm.parseJsonAddressArray(json, ".addresses");
        require(addresses.length > 0, "addresses array is empty");

        address token = pool.lockedToken();
        address poolInitiator = pool.initiator();
        uint8 decimals = IERC20Metadata(token).decimals();
        uint256 amount = amountWhole * (10 ** decimals);
        uint256 totalAmount = amount * addresses.length;

        console.log("=========================================");
        console.log("  HongBaoPool.batchDeposit");
        console.log("=========================================");
        console.log("Pool:      ", address(pool));
        console.log("Token:     ", token);
        console.log("Decimals:  ", decimals);
        console.log("Initiator: ", poolInitiator);
        console.log("Count:     ", addresses.length);
        console.log("Per card:  ", amountWhole, "(tokens)");
        console.log("Total:     ", amountWhole * addresses.length, "(tokens)");

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
