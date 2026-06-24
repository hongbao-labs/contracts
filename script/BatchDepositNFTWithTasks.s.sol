// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoNFTPool} from "../src/HongBao/nft/HongBaoNFTPool.sol";
import {IERC721} from "../src/HongBao/shared/interfaces/IERC721.sol";

/// @title BatchDepositNFTWithTasks — project-side script to mint a batch of NFT task cards
///
/// @notice Each card may carry an optional basic NFT (`hasBasic`) plus an
///         immutable list of bonus tasks (hash + tokenId). Generate the
///         preimages off-chain, compute hashes as
///           `keccak256(abi.encode(block.chainid, pool, unlockAddress,
///                                  taskIdx, preimage))`,
///         then call this script with the resulting JSON. Hashes are
///         chain-specific — re-generate per target chain.
///
/// @notice Environment variables:
///           POOL          — HongBaoNFTPool address
///           LOCK_DAYS     — lock duration in days (must be >= 30)
///           CARDS_JSON    — path to JSON file
///
/// @notice JSON format:
///           {
///             "cards": [
///               {
///                 "unlockAddress": "0xCard1...",
///                 "hasBasic": true,
///                 "basicTokenId": "1",
///                 "taskHashes":  ["0xabc...", "0xdef..."],
///                 "taskTokenIds": ["10", "11"]
///               },
///               {
///                 "unlockAddress": "0xCard2...",
///                 "hasBasic": false,
///                 "basicTokenId": "0",
///                 "taskHashes":  ["0x123..."],
///                 "taskTokenIds": ["20"]
///               },
///               ...
///             ]
///           }
///         When `hasBasic` is `false`, `basicTokenId` is ignored on-chain;
///         supply `"0"` (any value works, but `"0"` is least confusing).
///         `taskHashes` and `taskTokenIds` must be parallel arrays of equal
///         length per card; empty `taskHashes` is rejected by the contract.
///         tokenIds are parsed as string-encoded uint256 to support values
///         that exceed JSON's safe integer range.
///
/// @notice Usage:
///   POOL=0x... LOCK_DAYS=30 CARDS_JSON=./nft-task-cards.json \
///   forge script script/BatchDepositNFTWithTasks.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract BatchDepositNFTWithTasks is Script {
    // Buffers held in storage to keep the local stack shallow when calling
    // the pool with nested calldata arrays (see BatchDepositWithTasks.s.sol
    // for the analogous Token-side pattern).
    address[] internal _addrs;
    bool[] internal _hasBasics;
    uint256[] internal _basicTokenIds;
    bytes32[][] internal _hashes;
    uint256[][] internal _taskTokenIds;

    function run() external {
        HongBaoNFTPool pool = HongBaoNFTPool(vm.envAddress("POOL"));
        uint256 lockTime = vm.envUint("LOCK_DAYS") * 1 days;

        _loadJson(vm.readFile(vm.envString("CARDS_JSON")));

        address collection = pool.lockedCollection();
        address poolInitiator = pool.initiator();
        require(poolInitiator == msg.sender, "sender does not match pool initiator");

        console.log("=========================================");
        console.log("  HongBaoNFTPool.batchDepositWithTasks");
        console.log("=========================================");
        console.log("Pool:        ", address(pool));
        console.log("Collection:  ", collection);
        console.log("Initiator:   ", poolInitiator);
        console.log("Cards:       ", _addrs.length);
        console.log("Lock days:   ", lockTime / 1 days);

        _preflightOwnership(collection);

        vm.startBroadcast();

        if (!IERC721(collection).isApprovedForAll(msg.sender, address(pool))) {
            console.log(">>> Setting approval for all...");
            IERC721(collection).setApprovalForAll(address(pool), true);
        }

        pool.batchDepositWithTasks(_addrs, _hasBasics, _basicTokenIds, _hashes, _taskTokenIds, lockTime);

        vm.stopBroadcast();

        console.log(">>> Done.");
    }

    function _loadJson(string memory json) internal {
        address[] memory addrs = vm.parseJsonAddressArray(json, ".cards[*].unlockAddress");
        bool[] memory hasBasics = vm.parseJsonBoolArray(json, ".cards[*].hasBasic");
        string[] memory basicTokenIdStrs = vm.parseJsonStringArray(json, ".cards[*].basicTokenId");
        uint256 n = addrs.length;
        require(n > 0, "cards array is empty");
        require(hasBasics.length == n, "hasBasic/unlockAddress length mismatch");
        require(basicTokenIdStrs.length == n, "basicTokenId/unlockAddress length mismatch");

        for (uint256 i = 0; i < n; i++) {
            _addrs.push(addrs[i]);
            _hasBasics.push(hasBasics[i]);
            _basicTokenIds.push(vm.parseUint(basicTokenIdStrs[i]));
            _loadOneCard(json, i);
        }
    }

    function _loadOneCard(string memory json, uint256 i) internal {
        string memory base = string.concat(".cards[", vm.toString(i), "]");
        bytes32[] memory h = vm.parseJsonBytes32Array(json, string.concat(base, ".taskHashes"));
        string[] memory tidStrs = vm.parseJsonStringArray(json, string.concat(base, ".taskTokenIds"));
        require(h.length == tidStrs.length, "taskHashes/taskTokenIds length mismatch");

        uint256[] memory tids = new uint256[](tidStrs.length);
        for (uint256 j = 0; j < tidStrs.length; j++) {
            tids[j] = vm.parseUint(tidStrs[j]);
        }

        _hashes.push(h);
        _taskTokenIds.push(tids);
    }

    /// @dev Verifies that msg.sender owns every NFT that the pool will pull
    ///      (basic if `hasBasic` + every task tokenId), so the broadcast can't
    ///      revert mid-batch with `ERC721InvalidSender`. Also catches the
    ///      common typo of two cards listing the same tokenId — checked via a
    ///      flat dup-pass after ownership is confirmed.
    function _preflightOwnership(address collection) internal view {
        // Count total NFTs and ownership-check each one.
        uint256 total;
        for (uint256 i = 0; i < _addrs.length; i++) {
            if (_hasBasics[i]) {
                require(
                    IERC721(collection).ownerOf(_basicTokenIds[i]) == msg.sender,
                    "sender does not own a listed basicTokenId"
                );
                total++;
            }
            uint256[] storage tids = _taskTokenIds[i];
            for (uint256 j = 0; j < tids.length; j++) {
                require(
                    IERC721(collection).ownerOf(tids[j]) == msg.sender, "sender does not own a listed taskTokenId"
                );
                total++;
            }
        }
        require(total > 0, "no NFTs to deposit (every card hasBasic=false with empty tasks?)");

        // Dup-pass: flatten then O(n^2) check (n is small — typical batch <100 NFTs).
        uint256[] memory flat = new uint256[](total);
        uint256 k;
        for (uint256 i = 0; i < _addrs.length; i++) {
            if (_hasBasics[i]) {
                flat[k++] = _basicTokenIds[i];
            }
            uint256[] storage tids = _taskTokenIds[i];
            for (uint256 j = 0; j < tids.length; j++) {
                flat[k++] = tids[j];
            }
        }
        for (uint256 i = 0; i < total; i++) {
            for (uint256 j = i + 1; j < total; j++) {
                require(flat[i] != flat[j], "duplicate tokenId across cards/slots");
            }
        }
    }
}
