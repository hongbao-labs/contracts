// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HongBaoNFTPool} from "../src/HongBao/nft/HongBaoNFTPool.sol";
import {IHongBaoNFTPool} from "../src/HongBao/nft/interfaces/IHongBaoNFTPool.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockNonReceiver} from "./mocks/MockNonReceiver.sol";

// ================================================================
//      NFT BATCH WITHDRAW / BATCH CLAIM TASK — RELAYER PATH
//   Both are skip-on-failure (pre-check skips silently; per-entry
//   safeTransferFrom failures emit BatchTransferFailed and leave
//   card / slot state intact for retry).
// ================================================================

contract HongBaoNFTPoolBatchTest is Test {
    HongBaoNFTPool public pool;
    MockERC721 public nft;

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

    function setUp() public {
        nft = new MockERC721("NFT", "N");
        pool = new HongBaoNFTPool(address(nft), initiator);
        card1 = vm.addr(card1Pk);
        card2 = vm.addr(card2Pk);
        card3 = vm.addr(card3Pk);

        for (uint256 i = 100; i < 200; i++) {
            nft.mint(initiator, i);
        }
        vm.prank(initiator);
        nft.setApprovalForAll(address(pool), true);
    }

    // ---- helpers ----

    function _hash(address unlock, uint8 idx, bytes memory n) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(pool), unlock, idx, n));
    }

    function _sign(uint256 pk, address unlock, address to) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = pool.getWithdrawDigest(unlock, to);
        (v, r, s) = vm.sign(pk, digest);
    }

    function _plainDeposit(address unlock, uint256 tokenId) internal {
        vm.prank(initiator);
        pool.deposit(unlock, tokenId, MIN_LOCK);
    }

    function _taskDeposit(address unlock, bool hasBasic, uint256 basicTokenId, uint256[] memory taskTokenIds)
        internal
    {
        bytes32[] memory hashes = new bytes32[](taskTokenIds.length);
        for (uint8 i = 0; i < taskTokenIds.length; i++) {
            hashes[i] = _hash(unlock, i, abi.encodePacked("p", i));
        }
        vm.prank(initiator);
        pool.depositWithTasks(unlock, hasBasic, basicTokenId, hashes, taskTokenIds, MIN_LOCK);
    }

    // ============ batchWithdraw: happy path ============

    function test_batchWithdraw_two_plain_cards_one_call() public {
        _plainDeposit(card1, 100);
        _plainDeposit(card2, 101);

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

        assertEq(nft.ownerOf(100), to1);
        assertEq(nft.ownerOf(101), to2);
    }

    function test_batchWithdraw_mix_plain_and_task_cards() public {
        // plain
        _plainDeposit(card1, 100);
        // task with basic
        uint256[] memory tids = new uint256[](1);
        tids[0] = 110;
        _taskDeposit(card2, true, 101, tids);

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

        // plain: full NFT to to1
        assertEq(nft.ownerOf(100), to1);
        // task: basic to to2, boundTo set, task NFT still in pool
        assertEq(nft.ownerOf(101), to2);
        assertEq(nft.ownerOf(110), address(pool));
        assertEq(pool.cardBoundTo(card2), to2);
    }

    function test_batchWithdraw_pure_binding_no_transfer() public {
        // task card with no basic — binding doesn't need a transfer at all
        uint256[] memory tids = new uint256[](2);
        tids[0] = 110;
        tids[1] = 111;
        _taskDeposit(card1, false, 0, tids);

        (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, to1);

        address[] memory addrs = new address[](1);
        addrs[0] = card1;
        address[] memory tos = new address[](1);
        tos[0] = to1;
        uint8[] memory vs = new uint8[](1);
        vs[0] = v;
        bytes32[] memory rs = new bytes32[](1);
        rs[0] = r;
        bytes32[] memory ss = new bytes32[](1);
        ss[0] = s;

        vm.prank(relayer);
        pool.batchWithdraw(addrs, tos, vs, rs, ss);

        assertEq(pool.cardBoundTo(card1), to1);
        assertEq(pool.cardUnlockedAt(card1), block.timestamp);
        // task NFTs still in pool
        assertEq(nft.ownerOf(110), address(pool));
        assertEq(nft.ownerOf(111), address(pool));
    }

    // ============ batchWithdraw: skip-silently semantics ============

    function test_batchWithdraw_skips_bad_signature() public {
        _plainDeposit(card1, 100);
        _plainDeposit(card2, 101);

        (uint8 v1, bytes32 r1, bytes32 s1) = _sign(card1Pk, card1, to1);
        // card2 deliberately signed with WRONG key
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

        // card1 redeemed; card2 silently skipped (NFT stays in pool)
        assertEq(nft.ownerOf(100), to1);
        assertEq(nft.ownerOf(101), address(pool));
        assertEq(pool.cardUnlockedAt(card2), 0);
    }

    function test_batchWithdraw_skips_already_redeemed() public {
        _plainDeposit(card1, 100);
        _plainDeposit(card2, 101);

        // card1 redeemed individually first
        (uint8 v1, bytes32 r1, bytes32 s1) = _sign(card1Pk, card1, to1);
        pool.withdraw(card1, to1, v1, r1, s1);

        // batch includes the now-stale card1 sig
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

        assertEq(nft.ownerOf(101), to2);
    }

    function test_batchWithdraw_skip_basic_transfer_to_non_receiver() public {
        // task card with basic, plus an OK plain card
        uint256[] memory tids = new uint256[](1);
        tids[0] = 110;
        _taskDeposit(card1, true, 100, tids);
        _plainDeposit(card2, 101);

        address bad = address(new MockNonReceiver());

        (uint8 v1, bytes32 r1, bytes32 s1) = _sign(card1Pk, card1, bad);
        (uint8 v2, bytes32 r2, bytes32 s2) = _sign(card2Pk, card2, to2);

        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card2;
        address[] memory tos = new address[](2);
        tos[0] = bad;
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
        pool.batchWithdraw(addrs, tos, vs, rs, ss); // does NOT revert

        // card1 binding to non-receiver: try/catch caught -> emit failure,
        // card1 state stays untouched (basic still in pool, not bound, not unlocked)
        assertEq(nft.ownerOf(100), address(pool));
        assertEq(pool.cardBoundTo(card1), address(0));
        assertEq(pool.cardUnlockedAt(card1), 0);
        assertTrue(pool.cardHasBasic(card1));

        // card2 succeeded
        assertEq(nft.ownerOf(101), to2);
    }

    function test_batchWithdraw_skips_zero_to() public {
        _plainDeposit(card1, 100);
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
        pool.batchWithdraw(addrs, tos, vs, rs, ss);

        assertEq(pool.cardUnlockedAt(card1), 0);
    }

    function test_batchWithdraw_revert_empty() public {
        address[] memory addrs = new address[](0);
        address[] memory tos = new address[](0);
        uint8[] memory vs = new uint8[](0);
        bytes32[] memory rs = new bytes32[](0);
        bytes32[] memory ss = new bytes32[](0);
        vm.expectRevert(IHongBaoNFTPool.EmptyArray.selector);
        pool.batchWithdraw(addrs, tos, vs, rs, ss);
    }

    function test_batchWithdraw_revert_length_mismatch() public {
        address[] memory addrs = new address[](2);
        address[] memory tos = new address[](1);
        uint8[] memory vs = new uint8[](2);
        bytes32[] memory rs = new bytes32[](2);
        bytes32[] memory ss = new bytes32[](2);
        vm.expectRevert(IHongBaoNFTPool.ArrayLengthMismatch.selector);
        pool.batchWithdraw(addrs, tos, vs, rs, ss);
    }

    // ============ batchClaimTask: happy + skip ============

    function test_batchClaimTask_one_card_multiple_tasks() public {
        uint256[] memory tids = new uint256[](3);
        tids[0] = 110;
        tids[1] = 111;
        tids[2] = 112;
        _taskDeposit(card1, true, 100, tids);

        // bind to to1
        (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, to1);
        pool.withdraw(card1, to1, v, r, s);

        // claim tasks 0 and 2 (skip 1)
        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card1;
        uint8[] memory idxs = new uint8[](2);
        idxs[0] = 0;
        idxs[1] = 2;
        bytes[] memory preimages = new bytes[](2);
        preimages[0] = abi.encodePacked("p", uint8(0));
        preimages[1] = abi.encodePacked("p", uint8(2));

        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages);

        assertEq(nft.ownerOf(110), to1);
        assertEq(nft.ownerOf(112), to1);
        // task 1 still in pool
        assertEq(nft.ownerOf(111), address(pool));
    }

    function test_batchClaimTask_across_cards() public {
        uint256[] memory tids1 = new uint256[](1);
        tids1[0] = 110;
        _taskDeposit(card1, false, 0, tids1);
        uint256[] memory tids2 = new uint256[](1);
        tids2[0] = 120;
        _taskDeposit(card2, false, 0, tids2);

        // bind each card to a different to
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
        preimages[0] = abi.encodePacked("p", uint8(0));
        preimages[1] = abi.encodePacked("p", uint8(0));

        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages);

        assertEq(nft.ownerOf(110), to1);
        assertEq(nft.ownerOf(120), to2);
    }

    function test_batchClaimTask_skips_wrong_preimage_and_already_claimed() public {
        uint256[] memory tids = new uint256[](2);
        tids[0] = 110;
        tids[1] = 111;
        _taskDeposit(card1, false, 0, tids);
        (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, to1);
        pool.withdraw(card1, to1, v, r, s);

        // claim task 0 first (so it shows up as already-claimed in the batch)
        pool.claimTask(card1, 0, abi.encodePacked("p", uint8(0)));

        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card1;
        uint8[] memory idxs = new uint8[](2);
        idxs[0] = 0; // already claimed
        idxs[1] = 1; // wrong preimage
        bytes[] memory preimages = new bytes[](2);
        preimages[0] = abi.encodePacked("p", uint8(0));
        preimages[1] = "wrong";

        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages); // no revert; both skipped

        // task 1 still in pool (was skipped, not claimed)
        assertEq(nft.ownerOf(111), address(pool));
    }

    function test_batchClaimTask_skip_transfer_to_non_receiver_emits_failure() public {
        uint256[] memory tids = new uint256[](1);
        tids[0] = 110;
        _taskDeposit(card1, false, 0, tids);

        address bad = address(new MockNonReceiver());
        (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, bad);
        pool.withdraw(card1, bad, v, r, s);

        address[] memory addrs = new address[](1);
        addrs[0] = card1;
        uint8[] memory idxs = new uint8[](1);
        idxs[0] = 0;
        bytes[] memory preimages = new bytes[](1);
        preimages[0] = abi.encodePacked("p", uint8(0));

        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages); // no revert

        // slot not claimed; NFT stays in pool for retry
        (,, uint256 claimedAt) = pool.task(card1, 0);
        assertEq(claimedAt, 0);
        assertEq(nft.ownerOf(110), address(pool));
    }

    function test_batchClaimTask_skips_basic_not_completed_and_plain_card_and_oor() public {
        // task card, not bound yet
        uint256[] memory tids = new uint256[](1);
        tids[0] = 110;
        _taskDeposit(card1, false, 0, tids);
        // plain card
        _plainDeposit(card2, 100);
        // bound task card with valid claim possible
        uint256[] memory tids3 = new uint256[](1);
        tids3[0] = 120;
        _taskDeposit(card3, false, 0, tids3);
        (uint8 v, bytes32 r, bytes32 s) = _sign(card3Pk, card3, to1);
        pool.withdraw(card3, to1, v, r, s);

        address[] memory addrs = new address[](4);
        addrs[0] = card1; // BasicNotCompleted skip
        addrs[1] = card2; // NotTaskCard skip
        addrs[2] = card3; // out-of-range idx skip
        addrs[3] = card3; // valid claim
        uint8[] memory idxs = new uint8[](4);
        idxs[0] = 0;
        idxs[1] = 0;
        idxs[2] = 5;
        idxs[3] = 0;
        bytes[] memory preimages = new bytes[](4);
        preimages[0] = abi.encodePacked("p", uint8(0));
        preimages[1] = "x";
        preimages[2] = "x";
        preimages[3] = abi.encodePacked("p", uint8(0));

        vm.prank(relayer);
        pool.batchClaimTask(addrs, idxs, preimages);

        // Only the card3 valid one went through
        assertEq(nft.ownerOf(110), address(pool));
        assertEq(nft.ownerOf(100), address(pool)); // plain card untouched
        assertEq(nft.ownerOf(120), to1);
    }

    function test_batchClaimTask_revert_empty() public {
        address[] memory addrs = new address[](0);
        uint8[] memory idxs = new uint8[](0);
        bytes[] memory preimages = new bytes[](0);
        vm.expectRevert(IHongBaoNFTPool.EmptyArray.selector);
        pool.batchClaimTask(addrs, idxs, preimages);
    }

    function test_batchClaimTask_revert_length_mismatch() public {
        address[] memory addrs = new address[](2);
        uint8[] memory idxs = new uint8[](1);
        bytes[] memory preimages = new bytes[](2);
        vm.expectRevert(IHongBaoNFTPool.ArrayLengthMismatch.selector);
        pool.batchClaimTask(addrs, idxs, preimages);
    }

    // ============ batchWithdrawExpired: task card partial failure ============

    function test_batchWithdrawExpired_task_partial_failure_leaves_open_for_retry() public {
        // task card bound to a non-receiver — when we batch-reclaim, the task
        // transfer to initiator should succeed (initiator is a normal EOA-ish
        // address). To engineer a partial failure, we instead curse one of
        // the task tokenIds via MockERC721.curse, which makes any transfer
        // of that tokenId revert.
        uint256[] memory tids = new uint256[](2);
        tids[0] = 110;
        tids[1] = 111;
        _taskDeposit(card1, true, 100, tids);

        // Curse tokenId 111 so its transfer reverts.
        nft.curse(111);

        vm.warp(block.timestamp + MIN_LOCK + 1);

        address[] memory cards = new address[](1);
        cards[0] = card1;
        vm.prank(initiator);
        pool.batchWithdrawExpired(cards); // no revert

        // basic + task 0 reclaimed; cursed task 1 stays in pool; card NOT closed
        assertEq(nft.ownerOf(100), initiator);
        assertEq(nft.ownerOf(110), initiator);
        assertEq(nft.ownerOf(111), address(pool));
        assertFalse(pool.cardClosed(card1));

        // Operator un-curses + retries (simulated by directly clearing the curse storage)
        // For this test, just verify retry behavior: a fresh batch call should now succeed.
        // We can't un-curse via the mock without an extra helper; the operator action
        // (unpause / fix collection) is out of scope. Asserting state preservation is enough.
        (,, uint256 claimedAt0) = pool.task(card1, 0);
        (,, uint256 claimedAt1) = pool.task(card1, 1);
        assertGt(claimedAt0, 0, "task 0 marked claimed (reclaimed)");
        assertEq(claimedAt1, 0, "task 1 still open for retry");
    }
}
