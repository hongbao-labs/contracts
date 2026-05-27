// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HongBaoTokenFactory} from "../src/HongBao/token/HongBaoTokenFactory.sol";
import {HongBaoTokenPool} from "../src/HongBao/token/HongBaoTokenPool.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @title TaskCardE2E — end-to-end integration test for the task-card flow
///
/// @notice Exercises the three core task-card features against a live (or
///         forked) deployment:
///           1. create a pool from the factory
///           2. lock funds + commit tasks (`depositWithTasks`)
///           3. claim: bind a recipient via a device signature (`withdraw`),
///              then redeem every task (`claimTask`)
///
///         The "hardware card" is simulated entirely off-chain: the script
///         derives a throwaway secp256k1 keypair plus random task preimages
///         from on-chain entropy, signs the EIP-712 withdraw digest with
///         `vm.sign`, and submits it. No real device is needed.
///
/// @notice Run modes:
///           * Simulation (recommended first) — no `--broadcast`. Forks the
///             target chain, runs the whole flow in-memory, and asserts every
///             invariant. Zero gas, no real transactions:
///               FACTORY=0x.. TOKEN=0x.. forge script script/TaskCardE2E.s.sol \
///                 --rpc-url $RPC_URL --sender <yourAddr>
///           * Broadcast — append `--private-key $PK --broadcast --slow`
///             (`--slow` avoids the in-flight-tx limit, since this sends
///             several sequential transactions).
///           * Local smoke test — omit FACTORY/TOKEN entirely; the script
///             deploys a fresh factory + MockERC20 and runs end-to-end:
///               forge script script/TaskCardE2E.s.sol
///
/// @notice Environment variables (all optional):
///           FACTORY   — existing HongBaoTokenFactory (default: deploy fresh)
///           TOKEN     — existing MockERC20 (default: deploy fresh)
///           RECIPIENT — where claimed funds land (default: a fresh derived address)
///           SALT      — bump to force a unique simulated card across re-runs
contract TaskCardE2E is Script {
    uint256 internal constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant LOCK_TIME = 30 days;

    function run() external {
        address initiator = msg.sender;

        // ---- simulate a card keypair + task preimages from entropy ----
        uint256 seed =
            uint256(keccak256(abi.encode(block.timestamp, block.prevrandao, initiator, vm.envOr("SALT", uint256(0)))));
        uint256 cardPk = _toPrivateKey(uint256(keccak256(abi.encode(seed, "card"))));
        address cardAddr = vm.addr(cardPk);
        address recipient =
            vm.envOr("RECIPIENT", vm.addr(_toPrivateKey(uint256(keccak256(abi.encode(seed, "recipient"))))));

        bytes[] memory preimages = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            preimages[i] = abi.encode(keccak256(abi.encode(seed, "preimage", i)));
        }

        address factoryAddr = vm.envOr("FACTORY", address(0));
        address tokenAddr = vm.envOr("TOKEN", address(0));

        vm.startBroadcast();

        HongBaoTokenFactory factory =
            factoryAddr == address(0) ? new HongBaoTokenFactory() : HongBaoTokenFactory(factoryAddr);
        MockERC20 token = tokenAddr == address(0) ? new MockERC20("Test USDC", "USDC", 6) : MockERC20(tokenAddr);

        uint256 scale = 10 ** uint256(token.decimals());
        uint256 basicAmount = 10 * scale;
        uint256[] memory taskAmounts = new uint256[](3);
        taskAmounts[0] = 20 * scale;
        taskAmounts[1] = 30 * scale;
        taskAmounts[2] = 40 * scale;
        uint256 total = basicAmount + taskAmounts[0] + taskAmounts[1] + taskAmounts[2];

        // ---- (1) create pool from factory ----
        address predicted = factory.computePoolAddress(address(token), initiator);
        address poolAddr = factory.pools(address(token), initiator);
        if (poolAddr == address(0)) {
            poolAddr = factory.createPool(address(token), initiator);
            require(poolAddr == predicted, "createPool address != computePoolAddress");
            console.log("[1] createPool ->", poolAddr);
        } else {
            console.log("[1] pool already exists, reusing ->", poolAddr);
        }
        HongBaoTokenPool pool = HongBaoTokenPool(poolAddr);

        // Task hashes are bound to (chainid, pool, card, idx) — must match the
        // contract's `computeTaskHash`. The pool address is deterministic, so
        // we can build these the moment the pool address is known.
        bytes32[] memory taskHashes = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            taskHashes[i] = keccak256(abi.encode(block.chainid, poolAddr, cardAddr, uint8(i), preimages[i]));
        }

        // ---- (2) lock + set tasks ----
        if (token.balanceOf(initiator) < total) {
            token.mint(initiator, total - token.balanceOf(initiator)); // MockERC20: permissionless mint
        }
        if (token.allowance(initiator, poolAddr) < total) {
            token.approve(poolAddr, type(uint256).max);
        }
        pool.depositWithTasks(cardAddr, basicAmount, taskHashes, taskAmounts, LOCK_TIME);
        console.log("[2] depositWithTasks done. card:", cardAddr);
        console.log("    total locked:", total);

        // ---- (3) claim: bind recipient via card signature, then each task ----
        bytes32 digest = pool.getWithdrawDigest(cardAddr, recipient);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cardPk, digest); // vm.sign is canonical low-S
        pool.withdraw(cardAddr, recipient, v, r, s);
        console.log("[3a] withdraw bound recipient:", recipient);

        for (uint256 i = 0; i < 3; i++) {
            pool.claimTask(cardAddr, uint8(i), preimages[i]);
            console.log("[3b] claimTask idx claimed:", i);
        }

        vm.stopBroadcast();

        // ---- assertions (validated in simulation before any broadcast) ----
        require(pool.cardTaskCount(cardAddr) == 3, "taskCount != 3");
        require(pool.cardBoundTo(cardAddr) == recipient, "boundTo mismatch");
        require(pool.cardUnlockedAt(cardAddr) != 0, "card not unlocked");
        require(pool.cardTotal(cardAddr) == 0, "cardTotal not fully drained");
        require(token.balanceOf(recipient) == total, "recipient balance != total locked");
        for (uint256 i = 0; i < 3; i++) {
            (,, uint256 claimedAt) = pool.task(cardAddr, uint8(i));
            require(claimedAt != 0, "a task slot was not claimed");
        }

        console.log("=========================================");
        console.log("  ALL CHECKS PASSED");
        console.log("=========================================");
        console.log("Factory:          ", address(factory));
        console.log("Token:            ", address(token));
        console.log("Pool:             ", poolAddr);
        console.log("Card (simulated): ", cardAddr);
        console.log("Recipient:        ", recipient);
        console.log("Recipient balance:", token.balanceOf(recipient));
    }

    /// @dev Map arbitrary 256-bit entropy into the valid secp256k1 key range [1, n-1].
    function _toPrivateKey(uint256 x) internal pure returns (uint256) {
        return (x % (SECP256K1_N - 1)) + 1;
    }
}
