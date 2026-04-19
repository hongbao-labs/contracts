// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoNFTPool} from "../src/HongBao/nft/HongBaoNFTPool.sol";
import {IERC721} from "../src/HongBao/shared/interfaces/IERC721.sol";

/// @title BatchDepositNFT — project-side script to mint a batch of NFT cards
///
/// @notice The NFT pool has no on-chain `batchDeposit` (each card binds one
///         tokenId), so this script loops `deposit(...)` per entry inside a
///         single broadcast. The whole batch reverts if any single deposit
///         fails — the script exists to amortize gas overhead and ergonomics,
///         not to provide partial-failure semantics.
///
/// @notice Environment variables:
///           POOL          — HongBaoNFTPool address
///           LOCK_DAYS     — lock duration in days (must be >= 30)
///           ENTRIES_JSON  — path to JSON file of (unlockAddress, tokenId) pairs
///
/// @notice JSON format:
///           {
///             "entries": [
///               { "unlockAddress": "0xAbc...", "tokenId": "1" },
///               { "unlockAddress": "0xDef...", "tokenId": "2" }
///             ]
///           }
///         (tokenId is parsed as a string-encoded uint256 to support values
///         that exceed JSON's safe integer range.)
///
/// @notice Usage:
///   POOL=0x... LOCK_DAYS=30 ENTRIES_JSON=./entries.json \
///   forge script script/BatchDepositNFT.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract BatchDepositNFT is Script {
    function run() external {
        HongBaoNFTPool pool = HongBaoNFTPool(vm.envAddress("POOL"));
        uint256 lockTime = vm.envUint("LOCK_DAYS") * 1 days;

        string memory json = vm.readFile(vm.envString("ENTRIES_JSON"));
        address[] memory unlockAddresses = vm.parseJsonAddressArray(json, ".entries[*].unlockAddress");
        string[] memory tokenIdStrs = vm.parseJsonStringArray(json, ".entries[*].tokenId");

        require(unlockAddresses.length > 0, "entries array is empty");
        require(unlockAddresses.length == tokenIdStrs.length, "entries malformed");

        address collection = pool.lockedCollection();
        address poolInitiator = pool.initiator();

        console.log("=========================================");
        console.log("  HongBaoNFTPool.deposit (batch)");
        console.log("=========================================");
        console.log("Pool:       ", address(pool));
        console.log("Collection: ", collection);
        console.log("Initiator:  ", poolInitiator);
        console.log("Count:      ", unlockAddresses.length);
        console.log("Lock days:  ", lockTime / 1 days);

        require(poolInitiator == msg.sender, "sender does not match pool initiator");

        // Pre-flight: verify ownership and parse tokenIds.
        uint256[] memory tokenIds = new uint256[](unlockAddresses.length);
        for (uint256 i = 0; i < unlockAddresses.length; i++) {
            tokenIds[i] = vm.parseUint(tokenIdStrs[i]);
            require(
                IERC721(collection).ownerOf(tokenIds[i]) == msg.sender,
                "sender does not own one of the listed tokenIds"
            );
        }

        vm.startBroadcast();

        if (!IERC721(collection).isApprovedForAll(msg.sender, address(pool))) {
            console.log(">>> Setting approval for all...");
            IERC721(collection).setApprovalForAll(address(pool), true);
        }

        for (uint256 i = 0; i < unlockAddresses.length; i++) {
            pool.deposit(unlockAddresses[i], tokenIds[i], lockTime);
        }

        vm.stopBroadcast();

        console.log(">>> Done.");
    }
}
