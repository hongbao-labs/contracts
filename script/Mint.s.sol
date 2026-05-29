// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @title Mint — mint MockERC20 test tokens to an address
///
/// @notice `MockERC20.mint` is permissionless, so anyone can call this on a
///         test deployment. Mints to the broadcaster by default.
///
/// @notice Environment variables:
///           TOKEN  — MockERC20 address (required)
///           AMOUNT — amount in WHOLE tokens (required); scaled by the token's
///                    decimals automatically (e.g. AMOUNT=1000 on an 18-dec
///                    token mints 1000e18)
///           TO     — recipient (optional, defaults to the broadcaster)
///
/// @notice Usage:
///   TOKEN=0x... AMOUNT=1000 \
///   forge script script/Mint.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract Mint is Script {
    function run() external {
        MockERC20 token = MockERC20(vm.envAddress("TOKEN"));
        uint256 whole = vm.envUint("AMOUNT");
        address to = vm.envOr("TO", msg.sender);

        uint256 amount = whole * (10 ** uint256(token.decimals()));

        vm.startBroadcast();
        token.mint(to, amount);
        vm.stopBroadcast();

        console.log("=========================================");
        console.log("  Mint");
        console.log("=========================================");
        console.log("Token:          ", address(token));
        console.log("To:             ", to);
        console.log("Amount (whole): ", whole);
        console.log("Amount (base):  ", amount);
        console.log("New balance:    ", token.balanceOf(to));
    }
}
