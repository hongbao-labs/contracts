// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoTokenPool} from "../src/HongBao/token/HongBaoTokenPool.sol";
import {IERC20} from "../src/HongBao/shared/interfaces/IERC20.sol";

/// @title BatchDepositWithTasks — project-side script to mint a batch of task cards
///
/// @notice Each card carries an immutable list of bonus tasks (hash + amount)
///         plus a top-uppable `basicAmount`. Generate the preimages off-chain,
///         compute hashes as
///           `keccak256(abi.encode(block.chainid, pool, unlockAddress,
///                                  taskIdx, preimage))`,
///         then call this script with the resulting JSON. Hashes are
///         chain-specific — re-generate per target chain.
///
/// @notice Environment variables:
///           POOL          — HongBaoTokenPool address (restricted-mode)
///           LOCK_DAYS     — lock duration in days (>= 30)
///           CARDS_JSON    — path to JSON file
///
/// @notice JSON format:
///           {
///             "cards": [
///               {
///                 "unlockAddress": "0xCard1...",
///                 "basicAmount": 10000000000000000000,
///                 "taskHashes":  ["0xabc...", "0xdef..."],
///                 "taskAmounts": [20000000000000000000, 30000000000000000000]
///               },
///               ...
///             ]
///           }
///         Amounts are raw token base-units (e.g. 1e18 for one whole 18-decimal
///         token). `taskHashes` and `taskAmounts` must be parallel arrays of
///         equal length per card. Empty `taskHashes` is rejected by the
///         contract.
///
/// @notice Usage:
///   POOL=0x... LOCK_DAYS=30 CARDS_JSON=./task-cards.json \
///   forge script script/BatchDepositWithTasks.s.sol \
///     --rpc-url $RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast
contract BatchDepositWithTasks is Script {
    // Buffers held in storage to keep the local stack shallow when calling
    // the pool with nested calldata arrays (see commit history for the
    // various failed memory-only attempts).
    address[] internal _addrs;
    uint256[] internal _basics;
    bytes32[][] internal _hashes;
    uint256[][] internal _amounts;
    uint256 internal _grandTotal;

    function run() external {
        HongBaoTokenPool pool = HongBaoTokenPool(vm.envAddress("POOL"));
        uint256 lockTime = vm.envUint("LOCK_DAYS") * 1 days;

        _loadJson(vm.readFile(vm.envString("CARDS_JSON")));

        address token = pool.lockedToken();
        address poolInitiator = pool.initiator();
        require(poolInitiator != address(0), "pool is open-mode; task cards require restricted-mode");
        require(poolInitiator == msg.sender, "sender does not match pool initiator");

        console.log("=========================================");
        console.log("  HongBaoTokenPool.batchDepositWithTasks");
        console.log("=========================================");
        console.log("Pool:        ", address(pool));
        console.log("Token:       ", token);
        console.log("Initiator:   ", poolInitiator);
        console.log("Cards:       ", _addrs.length);
        console.log("Lock days:   ", lockTime / 1 days);
        console.log("Total amount:", _grandTotal);

        require(IERC20(token).balanceOf(msg.sender) >= _grandTotal, "insufficient token balance");

        vm.startBroadcast();

        if (IERC20(token).allowance(msg.sender, address(pool)) < _grandTotal) {
            console.log(">>> Approving...");
            IERC20(token).approve(address(pool), _grandTotal);
        }

        pool.batchDepositWithTasks(_addrs, _basics, _hashes, _amounts, lockTime);

        vm.stopBroadcast();

        console.log(">>> Done.");
    }

    function _loadJson(string memory json) internal {
        address[] memory addrs = vm.parseJsonAddressArray(json, ".cards[*].unlockAddress");
        uint256[] memory basics = vm.parseJsonUintArray(json, ".cards[*].basicAmount");
        uint256 n = addrs.length;
        require(n > 0, "cards array is empty");
        require(basics.length == n, "basicAmount/unlockAddress length mismatch");

        for (uint256 i = 0; i < n; i++) {
            _addrs.push(addrs[i]);
            _basics.push(basics[i]);
            _loadOneCard(json, i, basics[i]);
        }
    }

    function _loadOneCard(string memory json, uint256 i, uint256 basicAmount) internal {
        string memory base = string.concat(".cards[", vm.toString(i), "]");
        bytes32[] memory h = vm.parseJsonBytes32Array(json, string.concat(base, ".taskHashes"));
        uint256[] memory a = vm.parseJsonUintArray(json, string.concat(base, ".taskAmounts"));
        require(h.length == a.length, "taskHashes/taskAmounts length mismatch");

        _hashes.push(h);
        _amounts.push(a);

        uint256 sub = basicAmount;
        for (uint256 j = 0; j < a.length; j++) {
            sub += a[j];
        }
        _grandTotal += sub;
    }
}
