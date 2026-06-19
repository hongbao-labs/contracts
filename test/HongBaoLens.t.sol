// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HongBaoTokenPool} from "../src/HongBao/token/HongBaoTokenPool.sol";
import {HongBaoNFTPool} from "../src/HongBao/nft/HongBaoNFTPool.sol";
import {HongBaoLens} from "../src/HongBao/lens/HongBaoLens.sol";
import {IHongBaoTokenPool} from "../src/HongBao/token/interfaces/IHongBaoTokenPool.sol";
import {IHongBaoNFTPool} from "../src/HongBao/nft/interfaces/IHongBaoNFTPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

contract HongBaoLensTest is Test {
    HongBaoLens lens;
    address initiator = address(0xA11CE);

    function setUp() public {
        lens = new HongBaoLens();
    }

    // ============ Token Pool ============

    function _hash(address pool, address card, uint8 idx, bytes memory n) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, pool, card, idx, n));
    }

    function test_token_plain_card_view() public {
        MockERC20 token = new MockERC20("T", "T", 18);
        HongBaoTokenPool pool = new HongBaoTokenPool(address(token), initiator);
        token.mint(initiator, 1000 ether);
        vm.startPrank(initiator);
        token.approve(address(pool), type(uint256).max);
        address card = address(0x1111);
        pool.deposit(card, 100 ether, 1000);
        vm.stopPrank();

        HongBaoLens.TokenCardView memory v = lens.getTokenCard(IHongBaoTokenPool(address(pool)), card);
        assertEq(v.totalAmount, 100 ether);
        assertEq(v.basicAmount, 100 ether);
        assertEq(v.taskCount, 0);
        assertEq(v.boundTo, address(0));
        assertFalse(v.closed);
        assertTrue(v.isLocked);
        assertFalse(v.isExpired);
        assertEq(v.tasks.length, 0);
        assertGt(v.remainingLockTime, 0);
    }

    function test_token_task_card_view_with_all_slots() public {
        MockERC20 token = new MockERC20("T", "T", 18);
        HongBaoTokenPool pool = new HongBaoTokenPool(address(token), initiator);
        token.mint(initiator, 1000 ether);
        vm.startPrank(initiator);
        token.approve(address(pool), type(uint256).max);

        uint256 cardPk = 0xBEEF;
        address card = vm.addr(cardPk);
        bytes32[] memory hashes = new bytes32[](3);
        uint256[] memory amts = new uint256[](3);
        hashes[0] = _hash(address(pool), card, 0, "p0");
        hashes[1] = _hash(address(pool), card, 1, "p1");
        hashes[2] = _hash(address(pool), card, 2, "p2");
        amts[0] = 20 ether;
        amts[1] = 30 ether;
        amts[2] = 40 ether;
        pool.depositWithTasks(card, 10 ether, hashes, amts, 1000);
        vm.stopPrank();

        // before basic withdraw
        HongBaoLens.TokenCardView memory v = lens.getTokenCard(IHongBaoTokenPool(address(pool)), card);
        assertEq(v.totalAmount, 100 ether);
        assertEq(v.basicAmount, 10 ether);
        assertEq(v.taskCount, 3);
        assertEq(v.boundTo, address(0));
        assertEq(v.tasks.length, 3);
        assertEq(v.tasks[0].amount, 20 ether);
        assertEq(v.tasks[1].amount, 30 ether);
        assertEq(v.tasks[2].amount, 40 ether);
        assertEq(v.tasks[0].hash, hashes[0]);
        assertEq(v.tasks[0].claimedAt, 0);

        // do basic withdraw + claim one task; view should reflect both
        address user = address(0xCAFE);
        (uint8 vSig, bytes32 r, bytes32 s) = vm.sign(cardPk, pool.getWithdrawDigest(card, user));
        pool.withdraw(card, user, vSig, r, s);
        pool.claimTask(card, 1, "p1");

        v = lens.getTokenCard(IHongBaoTokenPool(address(pool)), card);
        assertEq(v.basicAmount, 0, "basic consumed");
        // total started 100 = basic 10 + tasks 20+30+40. basic withdrawn -> 90.
        // task1 (30) claimed -> 60.
        assertEq(v.totalAmount, 60 ether, "total = tasks - claimed1");
        assertEq(v.boundTo, user, "boundTo bound");
        assertGt(v.unlockedAt, 0);
        assertGt(v.tasks[1].claimedAt, 0, "task1 claimedAt set");
        assertEq(v.tasks[0].claimedAt, 0, "task0 still unclaimed");
        assertEq(v.tasks[2].claimedAt, 0, "task2 still unclaimed");
    }

    function test_token_batch_cards_mixed() public {
        MockERC20 token = new MockERC20("T", "T", 18);
        HongBaoTokenPool pool = new HongBaoTokenPool(address(token), initiator);
        token.mint(initiator, 1000 ether);
        vm.startPrank(initiator);
        token.approve(address(pool), type(uint256).max);

        address plain = address(0x2222);
        pool.deposit(plain, 50 ether, 1000);

        uint256 cardPk = 0xC0FFEE;
        address task = vm.addr(cardPk);
        bytes32[] memory hashes = new bytes32[](1);
        uint256[] memory amts = new uint256[](1);
        hashes[0] = _hash(address(pool), task, 0, "x");
        amts[0] = 25 ether;
        pool.depositWithTasks(task, 5 ether, hashes, amts, 1000);
        vm.stopPrank();

        address[] memory cards = new address[](3);
        cards[0] = plain;
        cards[1] = task;
        cards[2] = address(0xDEAD); // non-existent

        HongBaoLens.TokenCardView[] memory views = lens.getTokenCards(IHongBaoTokenPool(address(pool)), cards);
        assertEq(views.length, 3);

        // plain
        assertEq(views[0].totalAmount, 50 ether);
        assertEq(views[0].taskCount, 0);
        assertEq(views[0].tasks.length, 0);

        // task
        assertEq(views[1].totalAmount, 30 ether);
        assertEq(views[1].taskCount, 1);
        assertEq(views[1].tasks.length, 1);
        assertEq(views[1].tasks[0].amount, 25 ether);

        // non-existent — all zeros, not locked
        assertEq(views[2].totalAmount, 0);
        assertEq(views[2].expire, 0);
        assertEq(views[2].taskCount, 0);
        assertFalse(views[2].isLocked);
    }

    function test_token_pool_info() public {
        MockERC20 token = new MockERC20("T", "T", 18);
        HongBaoTokenPool pool = new HongBaoTokenPool(address(token), initiator);
        HongBaoLens.TokenPoolInfo memory info = lens.getTokenPoolInfo(IHongBaoTokenPool(address(pool)));
        assertEq(info.lockedToken, address(token));
        assertEq(info.initiator, initiator);
        assertEq(info.minLockTime, pool.MIN_LOCK_TIME());
        assertEq(info.domainSeparator, pool.DOMAIN_SEPARATOR());
        assertEq(info.withdrawTypehash, pool.WITHDRAW_TYPEHASH());
        assertEq(info.maxTasksPerCard, pool.MAX_TASKS_PER_CARD());
    }

    // ============ NFT Pool ============

    function test_nft_card_view_and_batch() public {
        MockERC721 nft = new MockERC721("N", "N");
        HongBaoNFTPool pool = new HongBaoNFTPool(address(nft), initiator);
        nft.mint(initiator, 1);
        vm.startPrank(initiator);
        nft.setApprovalForAll(address(pool), true);
        address card = address(0x4444);
        pool.deposit(card, 1, 30 days); // NFT pool MIN_LOCK_TIME is 30 days
        vm.stopPrank();

        HongBaoLens.NFTCardView memory v = lens.getNFTCard(IHongBaoNFTPool(address(pool)), card);
        assertEq(v.tokenId, 1);
        assertGt(v.expire, 0);
        assertEq(v.unlockedAt, 0);
        assertTrue(v.isLocked);
        assertFalse(v.isExpired);

        address[] memory cards = new address[](2);
        cards[0] = card;
        cards[1] = address(0xDEAD); // none
        HongBaoLens.NFTCardView[] memory views = lens.getNFTCards(IHongBaoNFTPool(address(pool)), cards);
        assertEq(views[0].tokenId, 1);
        assertEq(views[1].expire, 0);
        assertFalse(views[1].isLocked);

        HongBaoLens.NFTPoolInfo memory info = lens.getNFTPoolInfo(IHongBaoNFTPool(address(pool)));
        assertEq(info.lockedCollection, address(nft));
        assertEq(info.initiator, initiator);
    }
}
