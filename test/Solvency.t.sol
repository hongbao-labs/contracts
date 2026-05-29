// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HongBaoTokenPool} from "../src/HongBao/token/HongBaoTokenPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Global solvency invariant: pool token balance == sum of every card's cardTotal.
/// If any entry credits without pulling, or any exit pays without debiting (or
/// debits the wrong card), this breaks and one card's funds eat another's.
contract SolvencyTest is Test {
    HongBaoTokenPool pool;
    MockERC20 token;
    address initiator = address(0xA11CE);

    // track every card we touch
    address[] cards;

    function setUp() public {
        token = new MockERC20("T", "T", 18);
        pool = new HongBaoTokenPool(address(token), initiator);
        token.mint(initiator, 10_000_000 ether);
        vm.prank(initiator);
        token.approve(address(pool), type(uint256).max);
    }

    function _track(address c) internal {
        for (uint256 i = 0; i < cards.length; i++) {
            if (cards[i] == c) return;
        }
        cards.push(c);
    }

    function _sumCardTotals() internal view returns (uint256 s) {
        for (uint256 i = 0; i < cards.length; i++) {
            s += pool.cardTotal(cards[i]);
        }
    }

    function _assertSolvent(string memory step) internal view {
        assertEq(token.balanceOf(address(pool)), _sumCardTotals(), step);
    }

    function _hash(address card, uint8 i, bytes memory n) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(pool), card, i, n));
    }

    function _mkTaskCard(uint256 pk, uint256 basic, uint256 t0, uint256 t1) internal returns (address card) {
        card = vm.addr(pk);
        _track(card);
        bytes32[] memory hashes = new bytes32[](2);
        uint256[] memory amts = new uint256[](2);
        hashes[0] = _hash(card, 0, abi.encode("p0", card));
        hashes[1] = _hash(card, 1, abi.encode("p1", card));
        amts[0] = t0;
        amts[1] = t1;
        vm.prank(initiator);
        pool.depositWithTasks(card, basic, hashes, amts, 1000);
    }

    function _withdraw(uint256 pk, address card, address to) internal {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, pool.getWithdrawDigest(card, to));
        pool.withdraw(card, to, v, r, s);
    }

    // ============ restricted mode: many cards, interleaved ============
    function test_global_solvency_restricted_mixed() public {
        // two plain cards
        address p1 = address(0x1001);
        address p2 = address(0x1002);
        _track(p1);
        _track(p2);
        vm.startPrank(initiator);
        pool.deposit(p1, 100 ether, 1000);
        pool.deposit(p2, 250 ether, 1000);
        vm.stopPrank();
        _assertSolvent("after plain deposits");

        // topup p1
        vm.prank(initiator);
        pool.deposit(p1, 50 ether, 1000);
        _assertSolvent("after topup p1");

        // two task cards
        address t1 = _mkTaskCard(0xAAA1, 10 ether, 20 ether, 30 ether); // total 60
        address t2 = _mkTaskCard(0xAAA2, 5 ether, 15 ether, 25 ether); // total 45
        _assertSolvent("after task deposits");

        // topup task card t1 basic
        vm.prank(initiator);
        pool.deposit(t1, 7 ether, 1000);
        _assertSolvent("after topup t1");

        // withdraw task card t1 -> user U1 (binds), then claim one task
        address u1 = address(0x5001);
        _withdraw(0xAAA1, t1, u1);
        _assertSolvent("after t1 basic withdraw");
        pool.claimTask(t1, 0, abi.encode("p0", t1));
        _assertSolvent("after t1 claim task0");

        // plain card p2 redeemed by holder (we don't have its key; simulate via a real card)
        // create a plain card with a known key instead:
        address pk3 = vm.addr(0xBBB3);
        _track(pk3);
        vm.prank(initiator);
        pool.deposit(pk3, 80 ether, 1000);
        _withdraw(0xBBB3, pk3, address(0x5002));
        _assertSolvent("after plain card pk3 withdraw");

        // expire everything (MIN_LOCK_TIME=0 so already expired); initiator reclaims leftovers
        vm.warp(block.timestamp + 2000);
        vm.startPrank(initiator);
        // p1 plain not redeemed -> reclaim
        pool.withdrawExpired(p1);
        _assertSolvent("after reclaim p1");
        pool.withdrawExpired(p2);
        _assertSolvent("after reclaim p2");
        // t1 task card: basic withdrawn + 1 task claimed, reclaim the rest
        pool.withdrawExpired(t1);
        _assertSolvent("after reclaim t1");
        // t2 task card: untouched, reclaim full
        pool.withdrawExpired(t2);
        _assertSolvent("after reclaim t2");
        vm.stopPrank();

        // pool should be empty now
        assertEq(token.balanceOf(address(pool)), 0, "pool not empty");
    }

    // ============ open mode: multi-depositor solvency ============
    function test_global_solvency_open_mode() public {
        HongBaoTokenPool open = new HongBaoTokenPool(address(token), address(0));
        address a = address(0xA);
        address b = address(0xB);
        token.mint(a, 1000 ether);
        token.mint(b, 1000 ether);
        vm.prank(a);
        token.approve(address(open), type(uint256).max);
        vm.prank(b);
        token.approve(address(open), type(uint256).max);

        address card = vm.addr(0xCC01);

        vm.prank(a);
        open.deposit(card, 60 ether, 1000);
        vm.prank(b);
        open.deposit(card, 40 ether, 1000);
        assertEq(token.balanceOf(address(open)), open.cardTotal(card), "open: after deposits");

        // A reclaims their share after expiry
        vm.warp(block.timestamp + 2000);
        vm.prank(a);
        open.withdrawExpired(card);
        assertEq(token.balanceOf(address(open)), open.cardTotal(card), "open: after A reclaim");

        // holder sweeps the rest (B's share) via signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xCC01, open.getWithdrawDigest(card, address(0xF00D)));
        open.withdraw(card, address(0xF00D), v, r, s);
        assertEq(token.balanceOf(address(open)), open.cardTotal(card), "open: after holder sweep");
        assertEq(open.cardTotal(card), 0, "open: card not drained");
    }
}
