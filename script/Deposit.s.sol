// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoTokenPool} from "../src/HongBao/token/HongBaoTokenPool.sol";
import {IERC20} from "../src/HongBao/shared/interfaces/IERC20.sol";

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

/// @title Deposit — Single-deposit script
/// @notice Deposits ERC20 into a HongBaoTokenPool, locked to a given unlockAddress (the card's public-key address)
///
/// @notice Environment variables:
///           POOL            — HongBaoTokenPool contract address
///           UNLOCK_ADDRESS  — The card's public-key address (lock target)
///           AMOUNT          — Lock amount (whole tokens, scaled by token.decimals())
///           LOCK_DAYS       — Lock duration in days (the first deposit must be >= 30)
///
/// @notice Usage:
///   POOL=0x... UNLOCK_ADDRESS=0x... AMOUNT=100 LOCK_DAYS=30 \
///   forge script script/Deposit.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract Deposit is Script {
    function run() external {
        HongBaoTokenPool pool = HongBaoTokenPool(vm.envAddress("POOL"));
        address unlockAddress = vm.envAddress("UNLOCK_ADDRESS");
        uint256 amountWhole = vm.envUint("AMOUNT");
        uint256 lockTime = vm.envUint("LOCK_DAYS") * 1 days;

        address token = pool.lockedToken();
        address poolInitiator = pool.initiator();
        uint8 decimals = IERC20Metadata(token).decimals();
        uint256 amount = amountWhole * (10 ** decimals);

        console.log("=========================================");
        console.log("  HongBaoTokenPool.deposit");
        console.log("=========================================");
        console.log("Pool:          ", address(pool));
        console.log("Token:         ", token);
        console.log("Decimals:      ", decimals);
        console.log("Initiator:     ", poolInitiator);
        console.log("UnlockAddress: ", unlockAddress);
        console.log("Amount:        ", amountWhole, "(tokens)");
        console.log("LockDays:      ", lockTime / 1 days, "days");

        vm.startBroadcast();

        if (IERC20(token).allowance(msg.sender, address(pool)) < amount) {
            console.log(">>> Approving...");
            IERC20(token).approve(address(pool), amount);
        }

        pool.deposit(unlockAddress, amount, lockTime);
        vm.stopBroadcast();

        console.log(">>> Done.");
    }
}
