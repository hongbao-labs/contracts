// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HongBaoNFTPool} from "../src/HongBao/nft/HongBaoNFTPool.sol";
import {IHongBaoNFTPool} from "../src/HongBao/nft/interfaces/IHongBaoNFTPool.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockNonReceiver} from "./mocks/MockNonReceiver.sol";

// ================================================================
//                     NFT TASK CARD TESTS
//  (depositWithTasks / claimTask / batchDepositWithTasks /
//   withdrawExpired on task cards / batchWithdrawExpired mix)
// ================================================================

contract HongBaoNFTPoolTaskTest is Test {
    HongBaoNFTPool public pool;
    MockERC721 public nft;

    address initiator = address(0xA);
    address recipient = address(0xCAFE);
    uint256 constant MIN_LOCK = 30 days;

    uint256 cardPk = 0xBEEF;
    address card;

    uint256 card2Pk = 0xC0FFEE;
    address card2;

    bytes preimage0 = "task-0";
    bytes preimage1 = "task-1";
    bytes preimage2 = "task-2";

    // Basic NFT for card = 100. Task NFTs = 101, 102, 103.
    uint256 constant BASIC = 100;
    uint256 constant TASK0 = 101;
    uint256 constant TASK1 = 102;
    uint256 constant TASK2 = 103;

    function setUp() public {
        nft = new MockERC721("NFT", "N");
        pool = new HongBaoNFTPool(address(nft), initiator);
        card = vm.addr(cardPk);
        card2 = vm.addr(card2Pk);

        // Pre-mint NFTs 100..199 to initiator for use across tests.
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

    function _depositCardWith3Tasks(bool hasBasic) internal {
        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = _hash(card, 0, preimage0);
        hashes[1] = _hash(card, 1, preimage1);
        hashes[2] = _hash(card, 2, preimage2);
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = TASK0;
        tokenIds[1] = TASK1;
        tokenIds[2] = TASK2;
        vm.prank(initiator);
        pool.depositWithTasks(card, hasBasic, BASIC, hashes, tokenIds, MIN_LOCK);
    }

    function _withdrawBasic(uint256 pk, address unlock, address to) internal {
        (uint8 v, bytes32 r, bytes32 s) = _sign(pk, unlock, to);
        pool.withdraw(unlock, to, v, r, s);
    }

    // ============================================================
    //                  depositWithTasks: happy
    // ============================================================

    function test_depositWithTasks_with_basic_ok() public {
        _depositCardWith3Tasks(true);

        assertEq(pool.cardTokenId(card), BASIC);
        assertEq(pool.cardTaskCount(card), 3);
        assertTrue(pool.cardHasBasic(card));
        assertEq(pool.cardBoundTo(card), address(0));
        assertFalse(pool.cardClosed(card));
        assertEq(pool.cardExpire(card), block.timestamp + MIN_LOCK);

        // NFTs in pool custody
        assertEq(nft.ownerOf(BASIC), address(pool));
        assertEq(nft.ownerOf(TASK0), address(pool));
        assertEq(nft.ownerOf(TASK1), address(pool));
        assertEq(nft.ownerOf(TASK2), address(pool));

        (bytes32 h0, uint256 tid0, uint256 c0) = pool.task(card, 0);
        assertEq(h0, _hash(card, 0, preimage0));
        assertEq(tid0, TASK0);
        assertEq(c0, 0);

        assertTrue(pool.isLocked(card));
    }

    function test_depositWithTasks_no_basic_ok() public {
        _depositCardWith3Tasks(false);

        assertFalse(pool.cardHasBasic(card));
        assertEq(pool.cardTokenId(card), 0); // basic slot unused
        assertEq(pool.cardTaskCount(card), 3);

        // Only the 3 task NFTs in pool; basic was not pulled
        assertEq(nft.ownerOf(BASIC), initiator);
        assertEq(nft.ownerOf(TASK0), address(pool));
        assertEq(nft.ownerOf(TASK1), address(pool));
        assertEq(nft.ownerOf(TASK2), address(pool));
    }

    // ============================================================
    //                  depositWithTasks: rejections
    // ============================================================

    function test_depositWithTasks_revert_not_initiator() public {
        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(uint256(1));
        uint256[] memory tids = new uint256[](1);
        tids[0] = TASK0;
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.NotInitiator.selector, address(this)));
        pool.depositWithTasks(card, false, 0, h, tids, MIN_LOCK);
    }

    function test_depositWithTasks_revert_zero_unlock() public {
        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(uint256(1));
        uint256[] memory tids = new uint256[](1);
        tids[0] = TASK0;
        vm.prank(initiator);
        vm.expectRevert(IHongBaoNFTPool.ZeroAddress.selector);
        pool.depositWithTasks(address(0), false, 0, h, tids, MIN_LOCK);
    }

    function test_depositWithTasks_revert_lock_time_too_short() public {
        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(uint256(1));
        uint256[] memory tids = new uint256[](1);
        tids[0] = TASK0;
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.LockTimeTooShort.selector, MIN_LOCK - 1, MIN_LOCK));
        pool.depositWithTasks(card, false, 0, h, tids, MIN_LOCK - 1);
    }

    function test_depositWithTasks_revert_array_mismatch() public {
        bytes32[] memory h = new bytes32[](2);
        uint256[] memory tids = new uint256[](3);
        vm.prank(initiator);
        vm.expectRevert(IHongBaoNFTPool.TaskArrayMismatch.selector);
        pool.depositWithTasks(card, false, 0, h, tids, MIN_LOCK);
    }

    function test_depositWithTasks_revert_empty_task_array() public {
        bytes32[] memory h = new bytes32[](0);
        uint256[] memory tids = new uint256[](0);
        vm.prank(initiator);
        vm.expectRevert(IHongBaoNFTPool.EmptyTaskArray.selector);
        pool.depositWithTasks(card, true, BASIC, h, tids, MIN_LOCK);
    }

    function test_depositWithTasks_revert_too_many_tasks() public {
        bytes32[] memory h = new bytes32[](256);
        uint256[] memory tids = new uint256[](256);
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.TooManyTasks.selector, 256));
        pool.depositWithTasks(card, false, 0, h, tids, MIN_LOCK);
    }

    function test_depositWithTasks_revert_card_exists_plain() public {
        vm.prank(initiator);
        pool.deposit(card, BASIC, MIN_LOCK);

        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(uint256(1));
        uint256[] memory tids = new uint256[](1);
        tids[0] = TASK0;
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.CardExists.selector, card));
        pool.depositWithTasks(card, false, 0, h, tids, MIN_LOCK);
    }

    function test_depositWithTasks_revert_card_exists_task() public {
        _depositCardWith3Tasks(true);

        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(uint256(1));
        uint256[] memory tids = new uint256[](1);
        tids[0] = 200; // not owned, but reverts CardExists first
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.CardExists.selector, card));
        pool.depositWithTasks(card, false, 0, h, tids, MIN_LOCK);
    }

    function test_depositWithTasks_atomic_revert_on_missing_approval() public {
        // Initiator owns these NFTs, but revokes approval before depositing.
        vm.prank(initiator);
        nft.setApprovalForAll(address(pool), false);

        bytes32[] memory h = new bytes32[](2);
        h[0] = _hash(card, 0, preimage0);
        h[1] = _hash(card, 1, preimage1);
        uint256[] memory tids = new uint256[](2);
        tids[0] = TASK0;
        tids[1] = TASK1;

        vm.prank(initiator);
        vm.expectRevert(MockERC721.NotAuthorized.selector);
        pool.depositWithTasks(card, true, BASIC, h, tids, MIN_LOCK);

        // No state set despite partial transfers being attempted by the loop.
        assertEq(pool.cardExpire(card), 0);
        assertEq(nft.ownerOf(BASIC), initiator);
        assertEq(nft.ownerOf(TASK0), initiator);
        assertEq(nft.ownerOf(TASK1), initiator);
    }

    // ============================================================
    //              plain `deposit` does NOT mutate task cards
    // ============================================================

    function test_topup_via_plain_deposit_blocked_on_task_card() public {
        _depositCardWith3Tasks(true);
        // even initiator can't `deposit` a new NFT to the same unlockAddress
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.CardExists.selector, card));
        pool.deposit(card, 110, MIN_LOCK);
    }

    // ============================================================
    //                   withdraw on task cards
    // ============================================================

    function test_withdraw_task_card_with_basic_releases_basic_and_binds() public {
        _depositCardWith3Tasks(true);

        _withdrawBasic(cardPk, card, recipient);

        // Basic NFT to recipient
        assertEq(nft.ownerOf(BASIC), recipient);
        // Card still active, bound, basic-slot cleared
        assertEq(pool.cardBoundTo(card), recipient);
        assertFalse(pool.cardHasBasic(card));
        assertEq(pool.cardTokenId(card), 0);
        assertEq(pool.cardUnlockedAt(card), block.timestamp);
        assertFalse(pool.cardClosed(card));
        assertTrue(pool.isLocked(card)); // tasks still in pool
    }

    function test_withdraw_task_card_no_basic_pure_binding() public {
        _depositCardWith3Tasks(false);

        _withdrawBasic(cardPk, card, recipient);

        // No NFT transferred on bind: task NFTs stay in pool, basic stays with initiator
        assertEq(nft.ownerOf(BASIC), initiator);
        assertEq(nft.ownerOf(TASK0), address(pool));
        assertEq(nft.ownerOf(TASK1), address(pool));
        assertEq(nft.ownerOf(TASK2), address(pool));
        assertEq(pool.cardBoundTo(card), recipient);
        assertEq(pool.cardUnlockedAt(card), block.timestamp);
        assertTrue(pool.isLocked(card));
    }

    function test_withdraw_task_card_twice_reverts() public {
        _depositCardWith3Tasks(true);
        _withdrawBasic(cardPk, card, recipient);

        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, card, recipient);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.AlreadyUnlocked.selector, card));
        pool.withdraw(card, recipient, v, r, s);
    }

    function test_withdraw_task_card_after_close_reverts() public {
        _depositCardWith3Tasks(true);
        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.prank(initiator);
        pool.withdrawExpired(card);

        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, card, recipient);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.CardClosed.selector, card));
        pool.withdraw(card, recipient, v, r, s);
    }

    function test_withdraw_task_card_basic_transfer_to_non_receiver_reverts() public {
        _depositCardWith3Tasks(true);
        address bad = address(new MockNonReceiver());
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, card, bad);
        vm.expectRevert(); // safeTransferFrom -> onERC721Received check fails
        pool.withdraw(card, bad, v, r, s);

        // State rolled back: no binding, basic still in pool
        assertEq(pool.cardBoundTo(card), address(0));
        assertTrue(pool.cardHasBasic(card));
        assertEq(nft.ownerOf(BASIC), address(pool));
        assertEq(pool.cardUnlockedAt(card), 0);

        // User can retry to a valid `to`
        _withdrawBasic(cardPk, card, recipient);
        assertEq(nft.ownerOf(BASIC), recipient);
        assertEq(pool.cardBoundTo(card), recipient);
    }

    // ============================================================
    //                          claimTask
    // ============================================================

    function test_claimTask_happy() public {
        _depositCardWith3Tasks(true);
        _withdrawBasic(cardPk, card, recipient);

        pool.claimTask(card, 1, preimage1);

        assertEq(nft.ownerOf(TASK1), recipient);
        (,, uint256 claimedAt) = pool.task(card, 1);
        assertEq(claimedAt, block.timestamp);
    }

    function test_claimTask_callable_by_anyone_funds_go_to_boundTo() public {
        _depositCardWith3Tasks(true);
        _withdrawBasic(cardPk, card, recipient);

        address random = address(0xDEAD);
        vm.prank(random);
        pool.claimTask(card, 0, preimage0);

        // NFT to boundTo (= recipient), not the caller
        assertEq(nft.ownerOf(TASK0), recipient);
        // sanity: random never received the NFT (still owns nothing in this collection)
        assertTrue(nft.ownerOf(TASK0) != random);
    }

    function test_claimTask_revert_before_basic() public {
        _depositCardWith3Tasks(true);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.BasicNotCompleted.selector, card));
        pool.claimTask(card, 0, preimage0);
    }

    function test_claimTask_revert_wrong_preimage() public {
        _depositCardWith3Tasks(true);
        _withdrawBasic(cardPk, card, recipient);
        vm.expectRevert(IHongBaoNFTPool.InvalidPreimage.selector);
        pool.claimTask(card, 0, "wrong");
    }

    function test_claimTask_revert_index_out_of_range() public {
        _depositCardWith3Tasks(true);
        _withdrawBasic(cardPk, card, recipient);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.InvalidTaskIndex.selector, uint8(3), uint8(3)));
        pool.claimTask(card, 3, preimage0);
    }

    function test_claimTask_revert_already_claimed() public {
        _depositCardWith3Tasks(true);
        _withdrawBasic(cardPk, card, recipient);
        pool.claimTask(card, 0, preimage0);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.TaskAlreadyClaimed.selector, card, uint8(0)));
        pool.claimTask(card, 0, preimage0);
    }

    function test_claimTask_revert_plain_card() public {
        vm.prank(initiator);
        pool.deposit(card, BASIC, MIN_LOCK);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.NotTaskCard.selector, card));
        pool.claimTask(card, 0, preimage0);
    }

    function test_claimTask_revert_after_close() public {
        _depositCardWith3Tasks(true);
        _withdrawBasic(cardPk, card, recipient);
        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.prank(initiator);
        pool.withdrawExpired(card);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.CardClosed.selector, card));
        pool.claimTask(card, 0, preimage0);
    }

    function test_claimTask_works_past_expire_before_close() public {
        _depositCardWith3Tasks(true);
        _withdrawBasic(cardPk, card, recipient);
        vm.warp(block.timestamp + MIN_LOCK + 100);
        pool.claimTask(card, 0, preimage0);
        assertEq(nft.ownerOf(TASK0), recipient);
    }

    function test_claimTask_to_bound_non_receiver_reverts_initiator_can_still_reclaim_via_expire() public {
        // bind to a non-receiver contract via the pure-binding path
        _depositCardWith3Tasks(false);
        address bad = address(new MockNonReceiver());
        _withdrawBasic(cardPk, card, bad);
        assertEq(pool.cardBoundTo(card), bad);

        // claim attempt reverts; NFT stays in pool
        vm.expectRevert();
        pool.claimTask(card, 0, preimage0);
        assertEq(nft.ownerOf(TASK0), address(pool));

        // initiator still recovers via withdrawExpired
        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.prank(initiator);
        pool.withdrawExpired(card);
        assertEq(nft.ownerOf(TASK0), initiator);
        assertEq(nft.ownerOf(TASK1), initiator);
        assertEq(nft.ownerOf(TASK2), initiator);
        assertTrue(pool.cardClosed(card));
    }

    // ============================================================
    //                   hash binding: cross-card / cross-chain
    // ============================================================

    function test_preimage_reuse_across_cards_fails() public {
        // card1 task 0 uses preimage "shared", committed against card1 slot 0.
        bytes memory shared = "shared";
        bytes32[] memory h1 = new bytes32[](1);
        h1[0] = _hash(card, 0, shared);
        uint256[] memory t1 = new uint256[](1);
        t1[0] = TASK0;
        vm.prank(initiator);
        pool.depositWithTasks(card, false, 0, h1, t1, MIN_LOCK);

        // card2 commits using card1's hash bytes (deliberately wrong).
        bytes32[] memory h2 = new bytes32[](1);
        h2[0] = _hash(card, 0, shared);
        uint256[] memory t2 = new uint256[](1);
        t2[0] = TASK1;
        vm.prank(initiator);
        pool.depositWithTasks(card2, false, 0, h2, t2, MIN_LOCK);

        _withdrawBasic(cardPk, card, recipient);
        _withdrawBasic(card2Pk, card2, address(0xBEAD));

        // Card2 + shared preimage: hash is computed against (card2, 0, shared),
        // which differs from the committed (card, 0, shared) hash bytes.
        vm.expectRevert(IHongBaoNFTPool.InvalidPreimage.selector);
        pool.claimTask(card2, 0, shared);

        // Card1 accepts it.
        pool.claimTask(card, 0, shared);
        assertEq(nft.ownerOf(TASK0), recipient);
    }

    function test_computeTaskHash_matches_internal_and_chainid_bound() public view {
        bytes32 expected = _hash(card, 5, "preimage-xyz");
        bytes32 actual = pool.computeTaskHash(card, 5, "preimage-xyz");
        assertEq(actual, expected);

        // sanity: a different chainid → different hash
        bytes32 otherChain = keccak256(abi.encode(block.chainid + 1, address(pool), card, uint8(5), "preimage-xyz"));
        assertTrue(actual != otherChain);
    }

    // ============================================================
    //                       withdrawExpired (task)
    // ============================================================

    function test_withdrawExpired_task_card_initiator_reclaims_all() public {
        _depositCardWith3Tasks(true);
        vm.warp(block.timestamp + MIN_LOCK + 1);

        vm.prank(initiator);
        pool.withdrawExpired(card);

        assertEq(nft.ownerOf(BASIC), initiator);
        assertEq(nft.ownerOf(TASK0), initiator);
        assertEq(nft.ownerOf(TASK1), initiator);
        assertEq(nft.ownerOf(TASK2), initiator);
        assertTrue(pool.cardClosed(card));
        assertFalse(pool.isLocked(card));
    }

    function test_withdrawExpired_task_card_after_basic_and_one_claim() public {
        _depositCardWith3Tasks(true);
        _withdrawBasic(cardPk, card, recipient);
        pool.claimTask(card, 1, preimage1);

        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.prank(initiator);
        pool.withdrawExpired(card);

        // recipient kept basic + claimed task 1
        assertEq(nft.ownerOf(BASIC), recipient);
        assertEq(nft.ownerOf(TASK1), recipient);
        // initiator reclaimed task 0 and task 2
        assertEq(nft.ownerOf(TASK0), initiator);
        assertEq(nft.ownerOf(TASK2), initiator);
        assertTrue(pool.cardClosed(card));
    }

    function test_withdrawExpired_task_card_no_basic_initiator_reclaims_tasks() public {
        _depositCardWith3Tasks(false);
        vm.warp(block.timestamp + MIN_LOCK + 1);

        vm.prank(initiator);
        pool.withdrawExpired(card);

        // basic stays with initiator (never deposited); tasks all returned
        assertEq(nft.ownerOf(BASIC), initiator);
        assertEq(nft.ownerOf(TASK0), initiator);
        assertEq(nft.ownerOf(TASK1), initiator);
        assertEq(nft.ownerOf(TASK2), initiator);
        assertTrue(pool.cardClosed(card));
    }

    function test_withdrawExpired_task_card_revert_not_initiator() public {
        _depositCardWith3Tasks(true);
        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.NotInitiator.selector, address(this)));
        pool.withdrawExpired(card);
    }

    function test_withdrawExpired_task_card_revert_not_expired() public {
        _depositCardWith3Tasks(true);
        uint256 exp = pool.cardExpire(card);
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.NotExpired.selector, card, exp));
        pool.withdrawExpired(card);
    }

    function test_withdrawExpired_task_card_double_close_reverts() public {
        _depositCardWith3Tasks(true);
        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.prank(initiator);
        pool.withdrawExpired(card);
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.CardClosed.selector, card));
        pool.withdrawExpired(card);
    }

    // ============================================================
    //                  batchWithdrawExpired (mixed)
    // ============================================================

    function test_batchWithdrawExpired_mixed_plain_and_task() public {
        // plain card on card2 (just deposit before warping)
        vm.prank(initiator);
        pool.deposit(card2, 110, MIN_LOCK);
        // task card on card
        _depositCardWith3Tasks(true);

        vm.warp(block.timestamp + MIN_LOCK + 1);

        address[] memory cards = new address[](2);
        cards[0] = card;
        cards[1] = card2;

        vm.prank(initiator);
        pool.batchWithdrawExpired(cards);

        // both fully reclaimed
        assertEq(nft.ownerOf(BASIC), initiator);
        assertEq(nft.ownerOf(TASK0), initiator);
        assertEq(nft.ownerOf(TASK1), initiator);
        assertEq(nft.ownerOf(TASK2), initiator);
        assertEq(nft.ownerOf(110), initiator);
        assertTrue(pool.cardClosed(card));
        // plain reclaim doesn't set closed, but sets unlockedAt
        assertEq(pool.cardUnlockedAt(card2), block.timestamp);
    }

    function test_batchWithdrawExpired_skips_already_closed_task() public {
        _depositCardWith3Tasks(true);
        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.prank(initiator);
        pool.withdrawExpired(card); // close first

        address[] memory cards = new address[](1);
        cards[0] = card;
        vm.prank(initiator);
        pool.batchWithdrawExpired(cards); // must not revert
        assertTrue(pool.cardClosed(card));
    }

    // ============================================================
    //                       batchDepositWithTasks
    // ============================================================

    function test_batchDepositWithTasks_ok() public {
        address[] memory addrs = new address[](2);
        addrs[0] = card;
        addrs[1] = card2;

        bool[] memory hasBasics = new bool[](2);
        hasBasics[0] = true;
        hasBasics[1] = false;

        uint256[] memory basics = new uint256[](2);
        basics[0] = BASIC; // pulled
        basics[1] = 0; // ignored (!hasBasic[1])

        bytes32[][] memory hashes = new bytes32[][](2);
        uint256[][] memory tids = new uint256[][](2);

        hashes[0] = new bytes32[](2);
        hashes[0][0] = _hash(card, 0, preimage0);
        hashes[0][1] = _hash(card, 1, preimage1);
        tids[0] = new uint256[](2);
        tids[0][0] = TASK0;
        tids[0][1] = TASK1;

        hashes[1] = new bytes32[](1);
        hashes[1][0] = _hash(card2, 0, "p");
        tids[1] = new uint256[](1);
        tids[1][0] = 120;

        vm.prank(initiator);
        pool.batchDepositWithTasks(addrs, hasBasics, basics, hashes, tids, MIN_LOCK);

        assertEq(pool.cardTaskCount(card), 2);
        assertEq(pool.cardTaskCount(card2), 1);
        assertTrue(pool.cardHasBasic(card));
        assertFalse(pool.cardHasBasic(card2));
        // 4 NFTs pulled (basic + 2 tasks for card, 1 task for card2)
        assertEq(nft.ownerOf(BASIC), address(pool));
        assertEq(nft.ownerOf(TASK0), address(pool));
        assertEq(nft.ownerOf(TASK1), address(pool));
        assertEq(nft.ownerOf(120), address(pool));
    }

    function test_batchDepositWithTasks_revert_length_mismatch() public {
        address[] memory addrs = new address[](2);
        bool[] memory hasBasics = new bool[](1); // mismatch
        uint256[] memory basics = new uint256[](2);
        bytes32[][] memory hashes = new bytes32[][](2);
        uint256[][] memory tids = new uint256[][](2);

        vm.prank(initiator);
        vm.expectRevert(IHongBaoNFTPool.ArrayLengthMismatch.selector);
        pool.batchDepositWithTasks(addrs, hasBasics, basics, hashes, tids, MIN_LOCK);
    }

    function test_batchDepositWithTasks_revert_empty_array() public {
        address[] memory addrs = new address[](0);
        bool[] memory hasBasics = new bool[](0);
        uint256[] memory basics = new uint256[](0);
        bytes32[][] memory hashes = new bytes32[][](0);
        uint256[][] memory tids = new uint256[][](0);

        vm.prank(initiator);
        vm.expectRevert(IHongBaoNFTPool.EmptyArray.selector);
        pool.batchDepositWithTasks(addrs, hasBasics, basics, hashes, tids, MIN_LOCK);
    }

    function test_batchDepositWithTasks_atomic_on_failure() public {
        // pre-create card1 as plain card → batch must atomically revert when the
        // first entry tries to create a task card on the same unlockAddress
        vm.prank(initiator);
        pool.deposit(card, BASIC, MIN_LOCK);

        address[] memory addrs = new address[](2);
        addrs[0] = card2; // would succeed
        addrs[1] = card; // CardExists → revert

        bool[] memory hasBasics = new bool[](2);
        hasBasics[0] = false;
        hasBasics[1] = false;

        uint256[] memory basics = new uint256[](2);

        bytes32[][] memory hashes = new bytes32[][](2);
        hashes[0] = new bytes32[](1);
        hashes[0][0] = bytes32(uint256(1));
        hashes[1] = new bytes32[](1);
        hashes[1][0] = bytes32(uint256(2));

        uint256[][] memory tids = new uint256[][](2);
        tids[0] = new uint256[](1);
        tids[0][0] = 120;
        tids[1] = new uint256[](1);
        tids[1][0] = TASK0;

        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.CardExists.selector, card));
        pool.batchDepositWithTasks(addrs, hasBasics, basics, hashes, tids, MIN_LOCK);

        // card2 must NOT have been partially created
        assertEq(pool.cardExpire(card2), 0);
        // its first task NFT must NOT have been transferred away
        assertEq(nft.ownerOf(120), initiator);
    }

    // ============================================================
    //                            views
    // ============================================================

    function test_isLocked_task_card_states() public {
        _depositCardWith3Tasks(true);
        assertTrue(pool.isLocked(card)); // before basic

        _withdrawBasic(cardPk, card, recipient);
        assertTrue(pool.isLocked(card)); // tasks still in pool

        pool.claimTask(card, 0, preimage0);
        pool.claimTask(card, 1, preimage1);
        pool.claimTask(card, 2, preimage2);
        // basic withdrawn + all tasks claimed -> nothing remains
        assertFalse(pool.isLocked(card));
    }

    function test_isLocked_task_card_no_basic_unbound_still_locked() public {
        _depositCardWith3Tasks(false);
        // pre-bind: tasks in pool -> locked
        assertTrue(pool.isLocked(card));
    }
}
