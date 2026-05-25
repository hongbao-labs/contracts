// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HongBaoTokenPool} from "../src/HongBao/token/HongBaoTokenPool.sol";
import {IHongBaoTokenPool} from "../src/HongBao/token/interfaces/IHongBaoTokenPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

// ================================================================
//                       TASK CARD TESTS
//  (depositWithTasks / claimTask / batchDepositWithTasks / topup
//   into task card / withdrawExpired closes task card)
// ================================================================

contract HongBaoTokenPoolTaskTest is Test {
    HongBaoTokenPool public pool;
    MockERC20 public token;

    address initiator = address(0xA);
    address recipient = address(0xCAFE);
    uint256 constant MIN_LOCK = 30 days;

    // Card 1
    uint256 card1Pk = 0xBEEF;
    address card1;
    bytes preimage1A = "task-1-A";
    bytes preimage1B = "task-1-B";
    bytes preimage1C = "task-1-C";

    // Card 2
    uint256 card2Pk = 0xC0FFEE;
    address card2;

    function setUp() public {
        token = new MockERC20("TestToken", "TT", 18);
        pool = new HongBaoTokenPool(address(token), initiator);
        card1 = vm.addr(card1Pk);
        card2 = vm.addr(card2Pk);

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

    function _depositCard1With3Tasks(uint256 basicAmount, uint256[3] memory amts) internal {
        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = _hashTask(card1, 0, preimage1A);
        hashes[1] = _hashTask(card1, 1, preimage1B);
        hashes[2] = _hashTask(card1, 2, preimage1C);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = amts[0];
        amounts[1] = amts[1];
        amounts[2] = amts[2];
        vm.prank(initiator);
        pool.depositWithTasks(card1, basicAmount, hashes, amounts, MIN_LOCK);
    }

    function _withdrawBasic(uint256 pk, address unlockAddress, address to) internal {
        (uint8 v, bytes32 r, bytes32 s) = _sign(pk, unlockAddress, to);
        pool.withdraw(unlockAddress, to, v, r, s);
    }

    // ============ depositWithTasks: happy path ============

    function test_depositWithTasks_ok() public {
        _depositCard1With3Tasks(50 ether, [uint256(20 ether), 30 ether, 100 ether]);

        assertEq(pool.cardTotal(card1), 200 ether);
        assertEq(pool.cardBasicAmount(card1), 50 ether);
        assertEq(pool.cardTaskCount(card1), 3);
        assertEq(pool.cardBoundTo(card1), address(0));
        assertEq(pool.cardClosed(card1), false);
        assertEq(token.balanceOf(address(pool)), 200 ether);
        assertEq(pool.depositRecord(card1, initiator), 200 ether);

        (bytes32 h0, uint256 a0, uint256 c0) = pool.task(card1, 0);
        assertEq(h0, _hashTask(card1, 0, preimage1A));
        assertEq(a0, 20 ether);
        assertEq(c0, 0);
    }

    function test_depositWithTasks_zero_basic_ok() public {
        _depositCard1With3Tasks(0, [uint256(10 ether), 10 ether, 10 ether]);
        assertEq(pool.cardBasicAmount(card1), 0);
        assertEq(pool.cardTotal(card1), 30 ether);
    }

    // ============ depositWithTasks: rejections ============

    function test_depositWithTasks_revert_open_mode() public {
        HongBaoTokenPool openPool = new HongBaoTokenPool(address(token), address(0));
        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(uint256(1));
        uint256[] memory a = new uint256[](1);
        a[0] = 1 ether;
        token.approve(address(openPool), type(uint256).max);
        vm.expectRevert(IHongBaoTokenPool.OpenModeNotSupported.selector);
        openPool.depositWithTasks(card1, 0, h, a, MIN_LOCK);
    }

    function test_depositWithTasks_revert_not_initiator() public {
        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(uint256(1));
        uint256[] memory a = new uint256[](1);
        a[0] = 1 ether;
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.NotInitiator.selector, address(this)));
        pool.depositWithTasks(card1, 0, h, a, MIN_LOCK);
    }

    function test_depositWithTasks_revert_zero_unlockAddress() public {
        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(uint256(1));
        uint256[] memory a = new uint256[](1);
        a[0] = 1 ether;
        vm.prank(initiator);
        vm.expectRevert(IHongBaoTokenPool.ZeroAddress.selector);
        pool.depositWithTasks(address(0), 0, h, a, MIN_LOCK);
    }

    function test_depositWithTasks_revert_lock_time_too_short() public {
        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(uint256(1));
        uint256[] memory a = new uint256[](1);
        a[0] = 1 ether;
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.LockTimeTooShort.selector, MIN_LOCK - 1, MIN_LOCK));
        pool.depositWithTasks(card1, 0, h, a, MIN_LOCK - 1);
    }

    function test_depositWithTasks_revert_array_mismatch() public {
        bytes32[] memory h = new bytes32[](2);
        uint256[] memory a = new uint256[](3);
        vm.prank(initiator);
        vm.expectRevert(IHongBaoTokenPool.TaskArrayMismatch.selector);
        pool.depositWithTasks(card1, 0, h, a, MIN_LOCK);
    }

    function test_depositWithTasks_revert_empty_task_array() public {
        bytes32[] memory h = new bytes32[](0);
        uint256[] memory a = new uint256[](0);
        vm.prank(initiator);
        vm.expectRevert(IHongBaoTokenPool.EmptyTaskArray.selector);
        pool.depositWithTasks(card1, 1 ether, h, a, MIN_LOCK);
    }

    function test_depositWithTasks_revert_too_many_tasks() public {
        bytes32[] memory h = new bytes32[](256);
        uint256[] memory a = new uint256[](256);
        for (uint256 i = 0; i < 256; i++) {
            a[i] = 1;
        }
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.TooManyTasks.selector, 256));
        pool.depositWithTasks(card1, 0, h, a, MIN_LOCK);
    }

    function test_depositWithTasks_max_tasks_ok() public {
        bytes32[] memory h = new bytes32[](255);
        uint256[] memory a = new uint256[](255);
        for (uint256 i = 0; i < 255; i++) {
            h[i] = _hashTask(card1, uint8(i), abi.encodePacked("p", i));
            a[i] = 1 ether;
        }
        vm.prank(initiator);
        pool.depositWithTasks(card1, 0, h, a, MIN_LOCK);
        assertEq(pool.cardTaskCount(card1), 255);
        assertEq(pool.cardTotal(card1), 255 ether);
    }

    function test_depositWithTasks_revert_zero_task_amount() public {
        bytes32[] memory h = new bytes32[](2);
        h[0] = bytes32(uint256(1));
        h[1] = bytes32(uint256(2));
        uint256[] memory a = new uint256[](2);
        a[0] = 1 ether;
        a[1] = 0;
        vm.prank(initiator);
        vm.expectRevert(IHongBaoTokenPool.ZeroAmount.selector);
        pool.depositWithTasks(card1, 0, h, a, MIN_LOCK);
    }

    function test_depositWithTasks_revert_card_exists_plain() public {
        // create plain card first
        vm.prank(initiator);
        pool.deposit(card1, 1 ether, MIN_LOCK);

        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(uint256(1));
        uint256[] memory a = new uint256[](1);
        a[0] = 1 ether;
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.CardExists.selector, card1));
        pool.depositWithTasks(card1, 0, h, a, MIN_LOCK);
    }

    function test_depositWithTasks_revert_card_exists_task() public {
        _depositCard1With3Tasks(10 ether, [uint256(10 ether), 10 ether, 10 ether]);

        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(uint256(1));
        uint256[] memory a = new uint256[](1);
        a[0] = 1 ether;
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.CardExists.selector, card1));
        pool.depositWithTasks(card1, 0, h, a, MIN_LOCK);
    }

    // ============ topup into task card ============

    function test_deposit_topup_into_task_card_basic() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);

        vm.prank(initiator);
        pool.deposit(card1, 5 ether, 0); // lockTime ignored on topup

        assertEq(pool.cardBasicAmount(card1), 15 ether);
        assertEq(pool.cardTotal(card1), 105 ether);

        // task slots untouched
        (, uint256 a0,) = pool.task(card1, 0);
        (, uint256 a1,) = pool.task(card1, 1);
        (, uint256 a2,) = pool.task(card1, 2);
        assertEq(a0, 20 ether);
        assertEq(a1, 30 ether);
        assertEq(a2, 40 ether);
    }

    function test_deposit_topup_blocked_after_basic_completed() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        _withdrawBasic(card1Pk, card1, recipient);

        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.AlreadyUnlocked.selector, card1));
        pool.deposit(card1, 5 ether, 0);
    }

    function test_deposit_topup_blocked_after_close() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.prank(initiator);
        pool.withdrawExpired(card1);

        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.CardClosed.selector, card1));
        pool.deposit(card1, 5 ether, 0);
    }

    // ============ withdraw on task card ============

    function test_withdraw_task_card_releases_basic_and_binds() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        uint256 balBefore = token.balanceOf(recipient);

        _withdrawBasic(card1Pk, card1, recipient);

        assertEq(token.balanceOf(recipient) - balBefore, 10 ether);
        assertEq(pool.cardBoundTo(card1), recipient);
        assertEq(pool.cardBasicAmount(card1), 0);
        assertEq(pool.cardTotal(card1), 90 ether);
        assertEq(pool.cardUnlockedAt(card1), block.timestamp);
    }

    function test_withdraw_task_card_with_zero_basic() public {
        _depositCard1With3Tasks(0, [uint256(10 ether), 10 ether, 10 ether]);
        uint256 balBefore = token.balanceOf(recipient);

        _withdrawBasic(card1Pk, card1, recipient);

        assertEq(token.balanceOf(recipient) - balBefore, 0);
        assertEq(pool.cardBoundTo(card1), recipient);
        assertEq(pool.cardTotal(card1), 30 ether);
    }

    function test_withdraw_task_card_twice_reverts() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        _withdrawBasic(card1Pk, card1, recipient);

        (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, recipient);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.AlreadyUnlocked.selector, card1));
        pool.withdraw(card1, recipient, v, r, s);
    }

    function test_withdraw_task_card_after_close_reverts() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.prank(initiator);
        pool.withdrawExpired(card1);

        (uint8 v, bytes32 r, bytes32 s) = _sign(card1Pk, card1, recipient);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.CardClosed.selector, card1));
        pool.withdraw(card1, recipient, v, r, s);
    }

    // ============ claimTask: happy + rejections ============

    function test_claimTask_happy() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        _withdrawBasic(card1Pk, card1, recipient);

        uint256 balBefore = token.balanceOf(recipient);
        pool.claimTask(card1, 1, preimage1B);

        assertEq(token.balanceOf(recipient) - balBefore, 30 ether);
        (,, uint256 claimedAt) = pool.task(card1, 1);
        assertEq(claimedAt, block.timestamp);
        assertEq(pool.cardTotal(card1), 60 ether);
    }

    function test_claimTask_callable_by_anyone() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        _withdrawBasic(card1Pk, card1, recipient);

        address random = address(0xDEAD);
        vm.prank(random);
        pool.claimTask(card1, 0, preimage1A);

        // funds still go to boundTo, not msg.sender
        assertEq(token.balanceOf(random), 0);
        assertEq(token.balanceOf(recipient), 10 ether + 20 ether);
    }

    function test_claimTask_revert_before_basic() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.BasicNotCompleted.selector, card1));
        pool.claimTask(card1, 0, preimage1A);
    }

    function test_claimTask_revert_wrong_preimage() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        _withdrawBasic(card1Pk, card1, recipient);
        vm.expectRevert(IHongBaoTokenPool.InvalidPreimage.selector);
        pool.claimTask(card1, 0, "wrong");
    }

    function test_claimTask_revert_index_out_of_range() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        _withdrawBasic(card1Pk, card1, recipient);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.InvalidTaskIndex.selector, uint8(3), uint8(3)));
        pool.claimTask(card1, 3, preimage1A);
    }

    function test_claimTask_revert_already_claimed() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        _withdrawBasic(card1Pk, card1, recipient);
        pool.claimTask(card1, 0, preimage1A);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.TaskAlreadyClaimed.selector, card1, uint8(0)));
        pool.claimTask(card1, 0, preimage1A);
    }

    function test_claimTask_revert_plain_card() public {
        vm.prank(initiator);
        pool.deposit(card1, 1 ether, MIN_LOCK);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.NotTaskCard.selector, card1));
        pool.claimTask(card1, 0, preimage1A);
    }

    function test_claimTask_revert_after_close() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        _withdrawBasic(card1Pk, card1, recipient);
        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.prank(initiator);
        pool.withdrawExpired(card1);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.CardClosed.selector, card1));
        pool.claimTask(card1, 0, preimage1A);
    }

    function test_claimTask_works_past_expire_before_close() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        _withdrawBasic(card1Pk, card1, recipient);

        vm.warp(block.timestamp + MIN_LOCK + 100);
        // initiator hasn't reclaimed yet → claim should still succeed
        pool.claimTask(card1, 0, preimage1A);
        assertEq(token.balanceOf(recipient), 10 ether + 20 ether);
    }

    // ============ hash binding: cross-card preimage reuse fails ============

    function test_preimage_reuse_across_cards_fails() public {
        // Card1 task 0 uses preimage "shared"
        bytes memory shared = "shared";
        bytes32[] memory h1 = new bytes32[](1);
        h1[0] = _hashTask(card1, 0, shared);
        uint256[] memory a1 = new uint256[](1);
        a1[0] = 5 ether;
        vm.prank(initiator);
        pool.depositWithTasks(card1, 1 ether, h1, a1, MIN_LOCK);

        // Card2 task 0 ALSO commits to the same hash bytes — but bound to card2, not card1
        bytes32[] memory h2 = new bytes32[](1);
        h2[0] = _hashTask(card1, 0, shared); // intentionally cross-bound hash
        uint256[] memory a2 = new uint256[](1);
        a2[0] = 5 ether;
        vm.prank(initiator);
        pool.depositWithTasks(card2, 1 ether, h2, a2, MIN_LOCK);

        // Complete basics on both cards
        _withdrawBasic(card1Pk, card1, recipient);
        _withdrawBasic(card2Pk, card2, address(0xBEAD));

        // Submitting `shared` to card2's task 0 should fail — hash mismatch
        // (computeTaskHash binds to (pool, card2, 0, shared) which differs from h2[0]).
        vm.expectRevert(IHongBaoTokenPool.InvalidPreimage.selector);
        pool.claimTask(card2, 0, shared);

        // Card1 still accepts it.
        pool.claimTask(card1, 0, shared);
    }

    // ============ withdrawExpired on task card ============

    function test_withdrawExpired_task_card_initiator_reclaims() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        _withdrawBasic(card1Pk, card1, recipient);
        pool.claimTask(card1, 0, preimage1A);
        // remaining = total(100) - basic(10) - task0(20) = 70 (tasks 1 and 2)

        vm.warp(block.timestamp + MIN_LOCK + 1);
        uint256 balBefore = token.balanceOf(initiator);
        vm.prank(initiator);
        pool.withdrawExpired(card1);

        assertEq(token.balanceOf(initiator) - balBefore, 70 ether);
        assertEq(pool.cardClosed(card1), true);
        assertEq(pool.cardTotal(card1), 0);
    }

    function test_withdrawExpired_task_card_no_basic_done() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        vm.warp(block.timestamp + MIN_LOCK + 1);
        uint256 balBefore = token.balanceOf(initiator);
        vm.prank(initiator);
        pool.withdrawExpired(card1);

        assertEq(token.balanceOf(initiator) - balBefore, 100 ether);
        assertEq(pool.cardClosed(card1), true);
    }

    function test_withdrawExpired_task_card_revert_not_initiator() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.NotInitiator.selector, address(this)));
        pool.withdrawExpired(card1);
    }

    function test_withdrawExpired_task_card_revert_not_expired() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        uint256 exp = pool.cardExpire(card1);
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.NotExpired.selector, card1, exp));
        pool.withdrawExpired(card1);
    }

    function test_withdrawExpired_task_card_double_close_reverts() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.prank(initiator);
        pool.withdrawExpired(card1);
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.CardClosed.selector, card1));
        pool.withdrawExpired(card1);
    }

    // ============ batchWithdrawExpired: task card mixed with plain ============

    function test_batchWithdrawExpired_mixed_plain_and_task() public {
        // plain card on card2, task card on card1
        vm.prank(initiator);
        pool.deposit(card2, 50 ether, MIN_LOCK);
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);

        vm.warp(block.timestamp + MIN_LOCK + 1);

        address[] memory cards = new address[](2);
        cards[0] = card1;
        cards[1] = card2;

        uint256 balBefore = token.balanceOf(initiator);
        vm.prank(initiator);
        pool.batchWithdrawExpired(cards);

        // both reclaimed; initiator receives 100 (task card) + 50 (plain card)
        assertEq(token.balanceOf(initiator) - balBefore, 150 ether);
        assertEq(pool.cardClosed(card1), true);
        assertEq(pool.cardTotal(card2), 0);
    }

    function test_batchWithdrawExpired_skips_already_closed_task() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        vm.prank(initiator);
        pool.deposit(card2, 50 ether, MIN_LOCK);

        vm.warp(block.timestamp + MIN_LOCK + 1);

        // close card1 first
        vm.prank(initiator);
        pool.withdrawExpired(card1);

        address[] memory cards = new address[](2);
        cards[0] = card1; // already closed → skip
        cards[1] = card2;

        vm.prank(initiator);
        pool.batchWithdrawExpired(cards); // must not revert

        assertEq(pool.cardClosed(card1), true);
        assertEq(pool.cardTotal(card2), 0);
    }

    // ============ batchDepositWithTasks ============

    function test_batchDepositWithTasks_ok() public {
        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card2;

        uint256[] memory basics = new uint256[](2);
        basics[0] = 10 ether;
        basics[1] = 5 ether;

        bytes32[][] memory hashes = new bytes32[][](2);
        uint256[][] memory amounts = new uint256[][](2);

        hashes[0] = new bytes32[](2);
        hashes[0][0] = _hashTask(card1, 0, preimage1A);
        hashes[0][1] = _hashTask(card1, 1, preimage1B);
        amounts[0] = new uint256[](2);
        amounts[0][0] = 20 ether;
        amounts[0][1] = 30 ether;

        hashes[1] = new bytes32[](1);
        hashes[1][0] = _hashTask(card2, 0, "card2-only");
        amounts[1] = new uint256[](1);
        amounts[1][0] = 15 ether;

        uint256 balBefore = token.balanceOf(initiator);
        vm.prank(initiator);
        pool.batchDepositWithTasks(addrs, basics, hashes, amounts, MIN_LOCK);

        // card1: 10 + 20 + 30 = 60; card2: 5 + 15 = 20; total = 80
        assertEq(token.balanceOf(address(pool)), 80 ether);
        assertEq(balBefore - token.balanceOf(initiator), 80 ether);
        assertEq(pool.cardTaskCount(card1), 2);
        assertEq(pool.cardTaskCount(card2), 1);
        assertEq(pool.cardTotal(card1), 60 ether);
        assertEq(pool.cardTotal(card2), 20 ether);
    }

    function test_batchDepositWithTasks_revert_array_length_mismatch() public {
        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card2;
        uint256[] memory basics = new uint256[](1); // mismatched
        bytes32[][] memory hashes = new bytes32[][](2);
        uint256[][] memory amounts = new uint256[][](2);

        vm.prank(initiator);
        vm.expectRevert(IHongBaoTokenPool.ArrayLengthMismatch.selector);
        pool.batchDepositWithTasks(addrs, basics, hashes, amounts, MIN_LOCK);
    }

    function test_batchDepositWithTasks_revert_empty_array() public {
        address[] memory addrs = new address[](0);
        uint256[] memory basics = new uint256[](0);
        bytes32[][] memory hashes = new bytes32[][](0);
        uint256[][] memory amounts = new uint256[][](0);

        vm.prank(initiator);
        vm.expectRevert(IHongBaoTokenPool.EmptyArray.selector);
        pool.batchDepositWithTasks(addrs, basics, hashes, amounts, MIN_LOCK);
    }

    function test_batchDepositWithTasks_atomic_on_failure() public {
        // pre-create card1 as plain card → batch must atomically revert
        vm.prank(initiator);
        pool.deposit(card1, 1 ether, MIN_LOCK);

        address[] memory addrs = new address[](2);
        addrs[0] = card2; // fresh
        addrs[1] = card1; // already exists, should cause whole batch to revert

        uint256[] memory basics = new uint256[](2);
        basics[0] = 1 ether;
        basics[1] = 1 ether;

        bytes32[][] memory hashes = new bytes32[][](2);
        hashes[0] = new bytes32[](1);
        hashes[0][0] = bytes32(uint256(1));
        hashes[1] = new bytes32[](1);
        hashes[1][0] = bytes32(uint256(2));

        uint256[][] memory amounts = new uint256[][](2);
        amounts[0] = new uint256[](1);
        amounts[0][0] = 1 ether;
        amounts[1] = new uint256[](1);
        amounts[1][0] = 1 ether;

        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.CardExists.selector, card1));
        pool.batchDepositWithTasks(addrs, basics, hashes, amounts, MIN_LOCK);

        // card2 must NOT have been partially created
        assertEq(pool.cardExpire(card2), 0);
        assertEq(pool.cardTotal(card2), 0);
    }

    // ============ views ============

    function test_isLocked_task_card_states() public {
        _depositCard1With3Tasks(10 ether, [uint256(20 ether), 30 ether, 40 ether]);
        assertTrue(pool.isLocked(card1)); // before basic

        _withdrawBasic(card1Pk, card1, recipient);
        assertTrue(pool.isLocked(card1)); // after basic, tasks still claimable

        pool.claimTask(card1, 0, preimage1A);
        pool.claimTask(card1, 1, preimage1B);
        pool.claimTask(card1, 2, preimage1C);
        // all tasks claimed → total == 0 → not locked
        assertFalse(pool.isLocked(card1));
    }

    function test_computeTaskHash_matches_internal() public view {
        bytes32 expected = _hashTask(card1, 5, "preimage-xyz");
        bytes32 actual = pool.computeTaskHash(card1, 5, "preimage-xyz");
        assertEq(actual, expected);
    }

    function test_computeTaskHash_includes_chainid() public view {
        // Hash with the active chainid (what the contract uses) matches.
        bytes32 onChain = pool.computeTaskHash(card1, 0, preimage1A);
        bytes32 sameChain = keccak256(abi.encode(block.chainid, address(pool), card1, uint8(0), preimage1A));
        assertEq(onChain, sameChain);

        // Hash crafted with a different chainid must NOT match (cross-chain
        // replay protection — L-4 audit fix).
        bytes32 otherChain = keccak256(abi.encode(block.chainid + 1, address(pool), card1, uint8(0), preimage1A));
        assertTrue(onChain != otherChain);
    }

    function test_claimTask_revert_wrong_chainid_hash() public {
        // Project misconfigures: commits a hash computed without chainid (the
        // old/insecure formula). claimTask should reject because the contract
        // recomputes with chainid included.
        bytes32 buggyHash = keccak256(abi.encode(address(pool), card1, uint8(0), preimage1A));
        bytes32[] memory h = new bytes32[](1);
        h[0] = buggyHash;
        uint256[] memory a = new uint256[](1);
        a[0] = 5 ether;
        vm.prank(initiator);
        pool.depositWithTasks(card1, 1 ether, h, a, MIN_LOCK);
        _withdrawBasic(card1Pk, card1, recipient);
        vm.expectRevert(IHongBaoTokenPool.InvalidPreimage.selector);
        pool.claimTask(card1, 0, preimage1A);
    }
}
