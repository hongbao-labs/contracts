// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HongBaoTokenPool} from "../src/HongBao/token/HongBaoTokenPool.sol";
import {IHongBaoTokenPool} from "../src/HongBao/token/interfaces/IHongBaoTokenPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

// ================================================================
//          BATCH WITHDRAW / BATCH CLAIM TASK — RELAYER PATH
//   Both are silently skip-on-failure so one bad request cannot
//   poison a relayer's batch submission.
// ================================================================

contract HongBaoTokenPoolBatchTest is Test {
    HongBaoTokenPool public pool;
    MockERC20 public token;

    address initiator = address(0xA);
    address relayer = address(0xBEAD);
    uint256 constant MIN_LOCK = 30 days;

    uint256 card1Pk = 0xBEEF;
    uint256 card2Pk = 0xC0FFEE;
    uint256 card3Pk = 0xFEED;
    address card1;
    address card2;
    address card3;

    address to1 = address(0xCAFE);
    address to2 = address(0xC0DE);
    address to3 = address(0xFACE);

    bytes preimage = "task-preimage";

    function setUp() public {
        token = new MockERC20("TestToken", "TT", 18);
        pool = new HongBaoTokenPool(address(token), initiator);
        card1 = vm.addr(card1Pk);
        card2 = vm.addr(card2Pk);
        card3 = vm.addr(card3Pk);

        token.mint(initiator, 1_000_000 ether);
        vm.prank(initiator);
        token.approve(address(pool), type(uint256).max);
    }

    // ---- helpers ----

    function _hashTask(address unlockAddress, uint8 idx, bytes memory n) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(pool), unlockAddress, idx, n));
    }

    function _sign(uint256 pk, address unlockAddress, address to) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = pool.getWithdrawDigest(unlockAddress, to);
        (v, r, s) = vm.sign(pk, digest);
    }

    function _plainDeposit(address unlockAddress, uint256 amount) internal {
        vm.prank(initiator);
        pool.deposit(unlockAddress, amount, MIN_LOCK);
    }

    function _taskDeposit(address unlockAddress, uint256 basic, uint256[] memory amts, bytes[] memory ps) internal {
        require(amts.length == ps.length, "test helper: array length mismatch");
        bytes32[] memory hashes = new bytes32[](amts.length);
        for (uint8 i = 0; i < amts.length; i++) {
            hashes[i] = _hashTask(unlockAddress, i, ps[i]);
        }
        vm.prank(initiator);
        pool.depositWithTasks(unlockAddress, basic, hashes, amts, MIN_LOCK);
    }

    // ============ batchWithdraw: happy path ============

    function test_batchWithdraw_two_plain_cards_one_call() public {
        _plainDeposit(card1, 30 ether);
        _plainDeposit(card2, 50 ether);

        (uint8 v1, bytes32 r1, bytes32 s1) = _sign(card1Pk, card1, to1);
        (uint8 v2, bytes32 r2, bytes32 s2) = _sign(card2Pk, card2, to2);

        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card2;
        address[] memory tos = new address[](2);
        tos[0] = to1;
        tos[1] = to2;
        uint8[] memory vs = new uint8[](2);
        vs[0] = v1;
        vs[1] = v2;
        bytes32[] memory rs = new bytes32[](2);
        rs[0] = r1;
        rs[1] = r2;
        bytes32[] memory ss = new bytes32[](2);
        ss[0] = s1;
        ss[1] = s2;

        vm.prank(relayer);
        pool.batchWithdraw(addrs, tos, vs, rs, ss);

        assertEq(token.balanceOf(to1), 30 ether);
        assertEq(token.balanceOf(to2), 50 ether);
        assertEq(pool.cardUnlockedAt(card1), block.timestamp);
        assertEq(pool.cardUnlockedAt(card2), block.timestamp);
    }

    function test_batchWithdraw_mix_plain_and_task_cards() public {
        // card1: plain
        _plainDeposit(card1, 30 ether);
        // card2: task card, basic=5, single task=10
        uint256[] memory amts = new uint256[](1);
        amts[0] = 10 ether;
        bytes[] memory ps = new bytes[](1);
        ps[0] = preimage;
        _taskDeposit(card2, 5 ether, amts, ps);

        (uint8 v1, bytes32 r1, bytes32 s1) = _sign(card1Pk, card1, to1);
        (uint8 v2, bytes32 r2, bytes32 s2) = _sign(card2Pk, card2, to2);

        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card2;
        address[] memory tos = new address[](2);
        tos[0] = to1;
        tos[1] = to2;
        uint8[] memory vs = new uint8[](2);
        vs[0] = v1;
        vs[1] = v2;
        bytes32[] memory rs = new bytes32[](2);
        rs[0] = r1;
        rs[1] = r2;
        bytes32[] memory ss = new bytes32[](2);
        ss[0] = s1;
        ss[1] = s2;

        vm.prank(relayer);
        pool.batchWithdraw(addrs, tos, vs, rs, ss);

        // plain: full 30 to to1; task: basic 5 to to2, boundTo=to2, 10 still locked
        assertEq(token.balanceOf(to1), 30 ether);
        assertEq(token.balanceOf(to2), 5 ether);
        assertEq(pool.cardBoundTo(card2), to2);
        assertEq(pool.cardTotal(card2), 10 ether);
    }

    // ============ batchWithdraw: skip-silently semantics ============

    function test_batchWithdraw_skips_bad_signature() public {
        _plainDeposit(card1, 30 ether);
        _plainDeposit(card2, 50 ether);

        (uint8 v1, bytes32 r1, bytes32 s1) = _sign(card1Pk, card1, to1);
        // For card2 we deliberately sign with the WRONG private key.
        (uint8 v2bad, bytes32 r2bad, bytes32 s2bad) = _sign(card1Pk, card2, to2);

        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card2;
        address[] memory tos = new address[](2);
        tos[0] = to1;
        tos[1] = to2;
        uint8[] memory vs = new uint8[](2);
        vs[0] = v1;
        vs[1] = v2bad;
        bytes32[] memory rs = new bytes32[](2);
        rs[0] = r1;
        rs[1] = r2bad;
        bytes32[] memory ss = new bytes32[](2);
        ss[0] = s1;
        ss[1] = s2bad;

        vm.prank(relayer);
        pool.batchWithdraw(addrs, tos, vs, rs, ss);

        // card1 redeemed, card2 silently skipped
        assertEq(token.balanceOf(to1), 30 ether);
        assertEq(token.balanceOf(to2), 0);
        assertEq(pool.cardUnlockedAt(card1), block.timestamp);
        assertEq(pool.cardUnlockedAt(card2), 0);
    }

    function test_batchWithdraw_skips_already_redeemed() public {
        _plainDeposit(card1, 30 ether);
        _plainDeposit(card2, 50 ether);
        // card1 redeemed individually beforehand
        (uint8 v1, bytes32 r1, bytes32 s1) = _sign(card1Pk, card1, to1);
        pool.withdraw(card1, to1, v1, r1, s1);

        // batch including the now-stale card1 signature
        (uint8 v2, bytes32 r2, bytes32 s2) = _sign(card2Pk, card2, to2);

        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card2;
        address[] memory tos = new address[](2);
        tos[0] = to1;
        tos[1] = to2;
        uint8[] memory vs = new uint8[](2);
        vs[0] = v1;
        vs[1] = v2;
        bytes32[] memory rs = new bytes32[](2);
        rs[0] = r1;
        rs[1] = r2;
        bytes32[] memory ss = new bytes32[](2);
        ss[0] = s1;
        ss[1] = s2;

        vm.prank(relayer);
        pool.batchWithdraw(addrs, tos, vs, rs, ss); // must not revert

        assertEq(token.balanceOf(to2), 50 ether);
    }

    function test_batchWithdraw_skips_zero_to() public {
        _plainDeposit(card1, 30 ether);
        // Sign for the zero address. The signature itself is valid but `to == 0` is rejected.
        (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, address(0));

        address[] memory addrs = new address[](1);
        addrs[0] = card1;
        address[] memory tos = new address[](1);
        tos[0] = address(0);
        uint8[] memory vs = new uint8[](1);
        vs[0] = v;
        bytes32[] memory rs = new bytes32[](1);
        rs[0] = r;
        bytes32[] memory ss = new bytes32[](1);
        ss[0] = s;

        vm.prank(relayer);
        pool.batchWithdraw(addrs, tos, vs, rs, ss); // no revert, just skip

        assertEq(pool.cardUnlockedAt(card1), 0);
    }

    function test_batchWithdraw_revert_empty() public {
        address[] memory addrs = new address[](0);
        address[] memory tos = new address[](0);
        uint8[] memory vs = new uint8[](0);
        bytes32[] memory rs = new bytes32[](0);
        bytes32[] memory ss = new bytes32[](0);
        vm.expectRevert(IHongBaoTokenPool.EmptyArray.selector);
        pool.batchWithdraw(addrs, tos, vs, rs, ss);
    }

    function test_batchWithdraw_revert_length_mismatch() public {
        address[] memory addrs = new address[](2);
        address[] memory tos = new address[](1); // mismatch
        uint8[] memory vs = new uint8[](2);
        bytes32[] memory rs = new bytes32[](2);
        bytes32[] memory ss = new bytes32[](2);
        vm.expectRevert(IHongBaoTokenPool.ArrayLengthMismatch.selector);
        pool.batchWithdraw(addrs, tos, vs, rs, ss);
    }

    // ============ batchClaimTask: happy path ============

    function test_batchClaimTask_one_card_multiple_tasks() public {
        // card1 with 3 tasks
        uint256[] memory amts = new uint256[](3);
        amts[0] = 10 ether;
        amts[1] = 20 ether;
        amts[2] = 30 ether;
        bytes[] memory ps = new bytes[](3);
        ps[0] = "p0";
        ps[1] = "p1";
        ps[2] = "p2";
        _taskDeposit(card1, 5 ether, amts, ps);

        // Bind to1
        (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, to1);
        pool.withdraw(card1, to1, v, r, s);
        assertEq(token.balanceOf(to1), 5 ether); // basic only

        // Batch-claim tasks 0 and 2 (skip 1)
        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card1;
        uint8[] memory idxs = new uint8[](2);
        idxs[0] = 0;
        idxs[1] = 2;
        bytes[] memory preimages = new bytes[](2);
        preimages[0] = ps[0];
        preimages[1] = ps[2];

        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages);

        assertEq(token.balanceOf(to1), 5 ether + 10 ether + 30 ether);
        assertEq(pool.cardTotal(card1), 20 ether); // task 1 still locked
    }

    function test_batchClaimTask_across_cards() public {
        // two task cards, each with one task, both bound
        uint256[] memory amts1 = new uint256[](1);
        amts1[0] = 10 ether;
        bytes[] memory ps1 = new bytes[](1);
        ps1[0] = "p-card1";
        _taskDeposit(card1, 1 ether, amts1, ps1);

        uint256[] memory amts2 = new uint256[](1);
        amts2[0] = 20 ether;
        bytes[] memory ps2 = new bytes[](1);
        ps2[0] = "p-card2";
        _taskDeposit(card2, 2 ether, amts2, ps2);

        // bind each card to a different `to`
        {
            (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, to1);
            pool.withdraw(card1, to1, v, r, s);
        }
        {
            (uint8 v, bytes32 r, bytes32 s) = _sign(card2Pk, card2, to2);
            pool.withdraw(card2, to2, v, r, s);
        }

        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card2;
        uint8[] memory idxs = new uint8[](2);
        idxs[0] = 0;
        idxs[1] = 0;
        bytes[] memory preimages = new bytes[](2);
        preimages[0] = ps1[0];
        preimages[1] = ps2[0];

        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages);

        assertEq(token.balanceOf(to1), 1 ether + 10 ether);
        assertEq(token.balanceOf(to2), 2 ether + 20 ether);
    }

    // ============ batchClaimTask: skip-silently semantics ============

    function test_batchClaimTask_skips_wrong_preimage() public {
        uint256[] memory amts = new uint256[](2);
        amts[0] = 10 ether;
        amts[1] = 20 ether;
        bytes[] memory ps = new bytes[](2);
        ps[0] = "p0";
        ps[1] = "p1";
        _taskDeposit(card1, 1 ether, amts, ps);

        (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, to1);
        pool.withdraw(card1, to1, v, r, s);

        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card1;
        uint8[] memory idxs = new uint8[](2);
        idxs[0] = 0;
        idxs[1] = 1;
        bytes[] memory preimages = new bytes[](2);
        preimages[0] = ps[0];        // valid
        preimages[1] = "wrong";     // invalid

        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages);

        // task 0 claimed, task 1 skipped
        assertEq(token.balanceOf(to1), 1 ether + 10 ether);
        (,, uint256 claimed0) = pool.task(card1, 0);
        (,, uint256 claimed1) = pool.task(card1, 1);
        assertGt(claimed0, 0);
        assertEq(claimed1, 0);
    }

    function test_batchClaimTask_skips_basic_not_completed() public {
        uint256[] memory amts = new uint256[](1);
        amts[0] = 10 ether;
        bytes[] memory ps = new bytes[](1);
        ps[0] = "p0";
        _taskDeposit(card1, 1 ether, amts, ps);
        // basic NOT done

        address[] memory addrs = new address[](1);
        addrs[0] = card1;
        uint8[] memory idxs = new uint8[](1);
        idxs[0] = 0;
        bytes[] memory preimages = new bytes[](1);
        preimages[0] = ps[0];

        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages); // skipped, no revert

        (,, uint256 claimedAt) = pool.task(card1, 0);
        assertEq(claimedAt, 0);
    }

    function test_batchClaimTask_skips_already_claimed_slot() public {
        uint256[] memory amts = new uint256[](1);
        amts[0] = 10 ether;
        bytes[] memory ps = new bytes[](1);
        ps[0] = "p0";
        _taskDeposit(card1, 1 ether, amts, ps);

        (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, to1);
        pool.withdraw(card1, to1, v, r, s);

        // first claim succeeds individually
        pool.claimTask(card1, 0, ps[0]);
        uint256 balAfterFirst = token.balanceOf(to1);

        // batch repeats same claim → second attempt skipped
        address[] memory addrs = new address[](1);
        addrs[0] = card1;
        uint8[] memory idxs = new uint8[](1);
        idxs[0] = 0;
        bytes[] memory preimages = new bytes[](1);
        preimages[0] = ps[0];
        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages);

        assertEq(token.balanceOf(to1), balAfterFirst); // unchanged
    }

    function test_batchClaimTask_skips_plain_card() public {
        _plainDeposit(card1, 30 ether);
        // (no withdraw — but card is plain so taskCount == 0 → skip)

        address[] memory addrs = new address[](1);
        addrs[0] = card1;
        uint8[] memory idxs = new uint8[](1);
        idxs[0] = 0;
        bytes[] memory preimages = new bytes[](1);
        preimages[0] = "anything";

        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages); // skip, no revert
        assertEq(pool.cardTotal(card1), 30 ether);
    }

    function test_batchClaimTask_skips_closed_card() public {
        uint256[] memory amts = new uint256[](1);
        amts[0] = 10 ether;
        bytes[] memory ps = new bytes[](1);
        ps[0] = "p0";
        _taskDeposit(card1, 1 ether, amts, ps);
        // bind, then initiator closes via withdrawExpired
        (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, to1);
        pool.withdraw(card1, to1, v, r, s);
        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.prank(initiator);
        pool.withdrawExpired(card1);
        assertTrue(pool.cardClosed(card1));

        address[] memory addrs = new address[](1);
        addrs[0] = card1;
        uint8[] memory idxs = new uint8[](1);
        idxs[0] = 0;
        bytes[] memory preimages = new bytes[](1);
        preimages[0] = ps[0];

        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages); // skip, no revert
    }

    function test_batchClaimTask_skips_out_of_range_idx() public {
        uint256[] memory amts = new uint256[](1);
        amts[0] = 10 ether;
        bytes[] memory ps = new bytes[](1);
        ps[0] = "p0";
        _taskDeposit(card1, 1 ether, amts, ps);
        (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, to1);
        pool.withdraw(card1, to1, v, r, s);

        address[] memory addrs = new address[](1);
        addrs[0] = card1;
        uint8[] memory idxs = new uint8[](1);
        idxs[0] = 5; // out of range (taskCount == 1)
        bytes[] memory preimages = new bytes[](1);
        preimages[0] = ps[0];

        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages); // skip, no revert
        (,, uint256 claimedAt) = pool.task(card1, 0);
        assertEq(claimedAt, 0);
    }

    function test_batchClaimTask_revert_empty() public {
        address[] memory addrs = new address[](0);
        uint8[] memory idxs = new uint8[](0);
        bytes[] memory preimages = new bytes[](0);
        vm.expectRevert(IHongBaoTokenPool.EmptyArray.selector);
        pool.batchClaimTask(addrs, idxs, preimages);
    }

    function test_batchClaimTask_revert_length_mismatch() public {
        address[] memory addrs = new address[](2);
        uint8[] memory idxs = new uint8[](1); // mismatch
        bytes[] memory preimages = new bytes[](2);
        vm.expectRevert(IHongBaoTokenPool.ArrayLengthMismatch.selector);
        pool.batchClaimTask(addrs, idxs, preimages);
    }
}
