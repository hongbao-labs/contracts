// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {HongBaoTokenPool} from "../src/HongBao/token/HongBaoTokenPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ExpireBugTest is Test {
    HongBaoTokenPool pool;
    MockERC20 token;
    address initiator = address(0xA11CE);
    uint256 cardPk = 0xCAFE;
    address card;

    function setUp() public {
        token = new MockERC20("T", "T", 18);
        pool = new HongBaoTokenPool(address(token), initiator);
        card = vm.addr(cardPk);
        token.mint(initiator, 1_000_000 ether);
        vm.prank(initiator);
        token.approve(address(pool), type(uint256).max);
    }

    function _hash(uint8 i, bytes memory n) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(pool), card, i, n));
    }

    // Project funds a task card with a LARGE basic. Intent: if the holder never
    // engages during the lock window, the project reclaims everything after expiry.
    function test_project_cannot_reclaim_after_expiry_holder_frontruns() public {
        bytes32[] memory hashes = new bytes32[](1);
        uint256[] memory amts = new uint256[](1);
        hashes[0] = _hash(0, "p0");
        amts[0] = 1 ether; // tiny bonus
        vm.prank(initiator);
        pool.depositWithTasks(card, 100 ether, hashes, amts, 1000); // basic = 100, total = 101

        // lock expires; holder did NOTHING during the window
        vm.warp(block.timestamp + 2000);

        // project wants to reclaim all 101. But a holder (just needs the card key,
        // no preimage, no real task) front-runs the reclaim AFTER expiry:
        address grabber = address(0xBAD);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cardPk, pool.getWithdrawDigest(card, grabber));
        pool.withdraw(card, grabber, v, r, s); // <-- no expire check, succeeds post-expiry

        console.log("grabber got (basic):", token.balanceOf(grabber) / 1e18);

        uint256 before = token.balanceOf(initiator);
        vm.prank(initiator);
        pool.withdrawExpired(card);
        uint256 reclaimed = token.balanceOf(initiator) - before;
        console.log("project reclaimed:    ", reclaimed / 1e18);

        // The project deposited 101 but recovers only the 1 bonus; the 100 basic
        // was siphoned post-expiry by anyone holding the card key.
        assertEq(token.balanceOf(grabber), 100 ether, "grabber siphoned the basic post-expiry");
        assertEq(reclaimed, 1 ether, "project only got the bonus back");
    }

    // Same idea on a plain card: post-expiry the holder can still sweep it,
    // so the project's expiry-reclaim safety is only advisory.
    function test_plain_card_holder_sweeps_after_expiry() public {
        vm.prank(initiator);
        pool.deposit(card, 500 ether, 1000);

        vm.warp(block.timestamp + 2000); // expired

        address grabber = address(0xBAD);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cardPk, pool.getWithdrawDigest(card, grabber));
        pool.withdraw(card, grabber, v, r, s); // succeeds post-expiry

        assertEq(token.balanceOf(grabber), 500 ether, "swept post-expiry");

        // project reclaim now fails
        vm.prank(initiator);
        vm.expectRevert();
        pool.withdrawExpired(card);
    }
}
