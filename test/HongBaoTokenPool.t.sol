// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HongBaoTokenPool} from "../src/HongBao/token/HongBaoTokenPool.sol";
import {IHongBaoTokenPool} from "../src/HongBao/token/interfaces/IHongBaoTokenPool.sol";
import {ReentrancyGuard} from "../src/HongBao/shared/utils/ReentrancyGuard.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

// ================================================================
//                    RESTRICTED-MODE TESTS
//           (initiator != 0: only initiator may deposit)
// ================================================================

contract HongBaoTokenPoolRestrictedTest is Test {
    HongBaoTokenPool public pool;
    MockERC20 public token;

    address initiator = address(0xA);
    address recipient = address(0xCAFE);
    uint256 constant MIN_LOCK = 30 days;

    uint256 cardPk = 0xBEEF;
    address cardAddr;

    function setUp() public {
        token = new MockERC20("TestToken", "TT", 18);
        pool = new HongBaoTokenPool(address(token), initiator);
        cardAddr = vm.addr(cardPk);

        token.mint(initiator, 10000 ether);
        vm.prank(initiator);
        token.approve(address(pool), type(uint256).max);
    }

    // ---- helpers ----

    function _deposit(uint256 amount, uint256 lockTime) internal {
        vm.prank(initiator);
        pool.deposit(cardAddr, amount, lockTime);
    }

    function _deposit100() internal {
        _deposit(100 ether, MIN_LOCK);
    }

    function _sign(uint256 pk, address to) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = pool.getWithdrawDigest(cardAddr, to);
        (v, r, s) = vm.sign(pk, digest);
    }

    // ---- constructor ----

    function test_constructor_zero_token_reverts() public {
        vm.expectRevert(IHongBaoTokenPool.ZeroAddress.selector);
        new HongBaoTokenPool(address(0), initiator);
    }

    function test_constructor_sets_immutables() public view {
        assertEq(pool.lockedToken(), address(token));
        assertEq(pool.initiator(), initiator);
        assertEq(pool.MIN_LOCK_TIME(), 30 days);
    }

    // ---- deposit ----

    function test_deposit_ok() public {
        _deposit100();

        assertEq(pool.cardTotal(cardAddr), 100 ether);
        assertEq(pool.cardExpire(cardAddr), block.timestamp + MIN_LOCK);
        assertEq(pool.cardUnlockedAt(cardAddr), 0);
        assertEq(pool.depositRecord(cardAddr, initiator), 100 ether);
        assertEq(token.balanceOf(address(pool)), 100 ether);
        assertTrue(pool.isLocked(cardAddr));
    }

    function test_deposit_revert_not_initiator() public {
        address stranger = address(0xBAD);
        token.mint(stranger, 100 ether);
        vm.prank(stranger);
        token.approve(address(pool), type(uint256).max);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.NotInitiator.selector, stranger));
        pool.deposit(cardAddr, 100 ether, MIN_LOCK);
    }

    function test_deposit_revert_zero_amount() public {
        vm.prank(initiator);
        vm.expectRevert(IHongBaoTokenPool.ZeroAmount.selector);
        pool.deposit(cardAddr, 0, MIN_LOCK);
    }

    function test_deposit_revert_zero_unlockAddress() public {
        vm.prank(initiator);
        vm.expectRevert(IHongBaoTokenPool.ZeroAddress.selector);
        pool.deposit(address(0), 100 ether, MIN_LOCK);
    }

    function test_deposit_revert_lock_time_too_short() public {
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.LockTimeTooShort.selector, MIN_LOCK - 1, MIN_LOCK));
        pool.deposit(cardAddr, 100 ether, MIN_LOCK - 1);
    }

    function test_deposit_top_up_accumulates() public {
        _deposit100();
        uint256 expireBefore = pool.cardExpire(cardAddr);

        // warp halfway, top up with a "shorter" lockTime (ignored on top-up)
        vm.warp(block.timestamp + 10 days);
        vm.prank(initiator);
        pool.deposit(cardAddr, 50 ether, 1);

        assertEq(pool.cardTotal(cardAddr), 150 ether);
        assertEq(pool.cardExpire(cardAddr), expireBefore, "top-up must not change expire");
        assertEq(pool.depositRecord(cardAddr, initiator), 150 ether);
    }

    function test_deposit_revert_card_expired() public {
        _deposit100();
        vm.warp(block.timestamp + MIN_LOCK);

        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.CardExpired.selector, cardAddr));
        pool.deposit(cardAddr, 1 ether, 0);
    }

    function test_deposit_revert_already_unlocked_after_redeem() public {
        _deposit100();
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, recipient);
        pool.withdraw(cardAddr, recipient, v, r, s);

        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.AlreadyUnlocked.selector, cardAddr));
        pool.deposit(cardAddr, 1 ether, MIN_LOCK);
    }

    // ---- batchDeposit ----

    function test_batchDeposit_ok() public {
        address[] memory addrs = new address[](3);
        addrs[0] = vm.addr(0xB1);
        addrs[1] = vm.addr(0xB2);
        addrs[2] = vm.addr(0xB3);

        vm.prank(initiator);
        pool.batchDeposit(addrs, 50 ether, MIN_LOCK);

        assertEq(token.balanceOf(address(pool)), 150 ether);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(pool.cardTotal(addrs[i]), 50 ether);
            assertEq(pool.depositRecord(addrs[i], initiator), 50 ether);
        }
    }

    function test_batchDeposit_empty_array_reverts() public {
        address[] memory addrs = new address[](0);
        vm.prank(initiator);
        vm.expectRevert(IHongBaoTokenPool.EmptyArray.selector);
        pool.batchDeposit(addrs, 50 ether, MIN_LOCK);
    }

    function test_batchDeposit_tops_up_existing_card() public {
        // seed cardAddr first
        _deposit100();

        address[] memory addrs = new address[](2);
        addrs[0] = cardAddr; // existing → top-up
        addrs[1] = vm.addr(0xB2); // fresh

        vm.prank(initiator);
        pool.batchDeposit(addrs, 25 ether, MIN_LOCK);

        assertEq(pool.cardTotal(cardAddr), 125 ether);
        assertEq(pool.cardTotal(addrs[1]), 25 ether);
    }

    // ---- withdraw (signature) ----

    function test_withdraw_full_amount() public {
        _deposit100();
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, recipient);

        pool.withdraw(cardAddr, recipient, v, r, s);

        assertEq(token.balanceOf(recipient), 100 ether);
        assertEq(pool.cardTotal(cardAddr), 0);
        assertEq(pool.cardUnlockedAt(cardAddr), block.timestamp);
        assertFalse(pool.isLocked(cardAddr));
    }

    function test_withdraw_callable_by_anyone() public {
        _deposit100();
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, recipient);

        address random = address(0xBA5E);
        vm.prank(random);
        pool.withdraw(cardAddr, recipient, v, r, s);

        assertEq(token.balanceOf(recipient), 100 ether);
    }

    function test_withdraw_revert_invalid_sig() public {
        _deposit100();
        (uint8 v, bytes32 r, bytes32 s) = _sign(0xDEAD, recipient);

        vm.expectRevert(IHongBaoTokenPool.InvalidSignature.selector);
        pool.withdraw(cardAddr, recipient, v, r, s);
    }

    /// @dev L-1 audit fix: high-S signatures (the malleable "other half" of a
    ///      canonical signature) must be rejected.
    function test_withdraw_revert_high_s_signature() public {
        _deposit100();
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, recipient);

        // Flip to the high-S equivalent: s' = n - s, v' = 27 ^ 28 of original
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.expectRevert(IHongBaoTokenPool.InvalidSignature.selector);
        pool.withdraw(cardAddr, recipient, flippedV, r, highS);
    }

    function test_withdraw_revert_no_deposit() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, recipient);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.NoDeposit.selector, cardAddr));
        pool.withdraw(cardAddr, recipient, v, r, s);
    }

    function test_withdraw_revert_already_unlocked() public {
        _deposit100();
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, recipient);
        pool.withdraw(cardAddr, recipient, v, r, s);

        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.AlreadyUnlocked.selector, cardAddr));
        pool.withdraw(cardAddr, recipient, v, r, s);
    }

    function test_withdraw_revert_zero_to() public {
        _deposit100();
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, address(0));
        vm.expectRevert(IHongBaoTokenPool.ZeroAddress.selector);
        pool.withdraw(cardAddr, address(0), v, r, s);
    }

    function test_withdraw_works_after_expire() public {
        _deposit100();
        vm.warp(block.timestamp + MIN_LOCK + 1);

        // Signature still valid after expire, as long as nobody reclaimed yet.
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, recipient);
        pool.withdraw(cardAddr, recipient, v, r, s);

        assertEq(token.balanceOf(recipient), 100 ether);
    }

    // ---- withdrawExpired ----

    function test_withdrawExpired_ok() public {
        _deposit100();
        vm.warp(block.timestamp + MIN_LOCK + 1);

        uint256 before = token.balanceOf(initiator);
        vm.prank(initiator);
        pool.withdrawExpired(cardAddr);

        assertEq(token.balanceOf(initiator) - before, 100 ether);
        assertEq(pool.cardTotal(cardAddr), 0);
        assertEq(pool.depositRecord(cardAddr, initiator), 0);
    }

    function test_withdrawExpired_revert_not_expired() public {
        _deposit100();
        vm.prank(initiator);
        vm.expectRevert(
            abi.encodeWithSelector(IHongBaoTokenPool.NotExpired.selector, cardAddr, block.timestamp + MIN_LOCK)
        );
        pool.withdrawExpired(cardAddr);
    }

    function test_withdrawExpired_revert_no_share() public {
        _deposit100();
        vm.warp(block.timestamp + MIN_LOCK + 1);

        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.NoShare.selector, cardAddr, stranger));
        pool.withdrawExpired(cardAddr);
    }

    function test_withdrawExpired_revert_no_deposit() public {
        address empty = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.NoDeposit.selector, empty));
        pool.withdrawExpired(empty);
    }

    function test_withdrawExpired_revert_already_unlocked() public {
        _deposit100();
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, recipient);
        pool.withdraw(cardAddr, recipient, v, r, s);

        vm.warp(block.timestamp + MIN_LOCK + 1);
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoTokenPool.AlreadyUnlocked.selector, cardAddr));
        pool.withdrawExpired(cardAddr);
    }

    // ---- batchWithdrawExpired ----

    function test_batchWithdrawExpired_ok() public {
        uint256[3] memory pks = [uint256(0xB1), uint256(0xB2), uint256(0xB3)];
        address[] memory addrs = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            addrs[i] = vm.addr(pks[i]);
        }

        vm.prank(initiator);
        pool.batchDeposit(addrs, 100 ether, MIN_LOCK);
        vm.warp(block.timestamp + MIN_LOCK + 1);

        uint256 before = token.balanceOf(initiator);
        vm.prank(initiator);
        pool.batchWithdrawExpired(addrs);
        assertEq(token.balanceOf(initiator) - before, 300 ether);
    }

    function test_batchWithdrawExpired_skips_unlocked_entry() public {
        // Two cards; first is redeemed via signature, second is expired claim.
        uint256 pk2 = 0xB2;
        address addr2 = vm.addr(pk2);

        _deposit100();
        vm.prank(initiator);
        pool.deposit(addr2, 100 ether, MIN_LOCK);

        // Redeem card 1 with signature BEFORE expire.
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, recipient);
        pool.withdraw(cardAddr, recipient, v, r, s);

        vm.warp(block.timestamp + MIN_LOCK + 1);

        address[] memory addrs = new address[](2);
        addrs[0] = cardAddr; // should skip (unlockedAt != 0)
        addrs[1] = addr2;

        uint256 before = token.balanceOf(initiator);
        vm.prank(initiator);
        pool.batchWithdrawExpired(addrs);

        // Only addr2's 100 ether should come back.
        assertEq(token.balanceOf(initiator) - before, 100 ether);
    }

    function test_batchWithdrawExpired_skips_no_share_entry() public {
        // stranger calls batch with a list including cardAddr (their share == 0).
        _deposit100();
        vm.warp(block.timestamp + MIN_LOCK + 1);

        address stranger = address(0xBAD);
        address[] memory addrs = new address[](1);
        addrs[0] = cardAddr;

        uint256 before = token.balanceOf(stranger);
        vm.prank(stranger);
        pool.batchWithdrawExpired(addrs); // should NOT revert; just no-op
        assertEq(token.balanceOf(stranger), before);

        // initiator's share still intact.
        assertEq(pool.depositRecord(cardAddr, initiator), 100 ether);
    }

    function test_batchWithdrawExpired_reverts_not_expired() public {
        _deposit100();
        address[] memory addrs = new address[](1);
        addrs[0] = cardAddr;

        vm.prank(initiator);
        vm.expectRevert(
            abi.encodeWithSelector(IHongBaoTokenPool.NotExpired.selector, cardAddr, block.timestamp + MIN_LOCK)
        );
        pool.batchWithdrawExpired(addrs);
    }

    function test_batchWithdrawExpired_empty_array_reverts() public {
        address[] memory addrs = new address[](0);
        vm.prank(initiator);
        vm.expectRevert(IHongBaoTokenPool.EmptyArray.selector);
        pool.batchWithdrawExpired(addrs);
    }

    // ---- views ----

    function test_isLocked_and_isExpired() public {
        _deposit100();
        assertTrue(pool.isLocked(cardAddr));
        assertFalse(pool.isExpired(cardAddr));

        vm.warp(block.timestamp + MIN_LOCK);
        assertTrue(pool.isLocked(cardAddr));
        assertTrue(pool.isExpired(cardAddr));
    }

    function test_remainingLockTime() public {
        _deposit100();
        assertEq(pool.remainingLockTime(cardAddr), MIN_LOCK);

        vm.warp(block.timestamp + 10 days);
        assertEq(pool.remainingLockTime(cardAddr), MIN_LOCK - 10 days);

        vm.warp(block.timestamp + MIN_LOCK);
        assertEq(pool.remainingLockTime(cardAddr), 0);
    }

    function test_getWithdrawDigest_deterministic() public view {
        bytes32 d1 = pool.getWithdrawDigest(cardAddr, recipient);
        bytes32 d2 = pool.getWithdrawDigest(cardAddr, recipient);
        assertEq(d1, d2);

        bytes32 d3 = pool.getWithdrawDigest(cardAddr, address(0x1234));
        assertTrue(d1 != d3);
    }
}

// ================================================================
//                      OPEN-MODE TESTS
//         (initiator == 0: anyone may deposit / top-up)
// ================================================================

contract HongBaoTokenPoolOpenTest is Test {
    HongBaoTokenPool public pool;
    MockERC20 public token;

    address alice = address(0xA1);
    address bob = address(0xB1);
    address recipient = address(0xCAFE);
    uint256 constant MIN_LOCK = 30 days;

    uint256 cardPk = 0xBEEF;
    address cardAddr;

    function setUp() public {
        token = new MockERC20("TestToken", "TT", 18);
        pool = new HongBaoTokenPool(address(token), address(0));
        cardAddr = vm.addr(cardPk);

        token.mint(alice, 10000 ether);
        token.mint(bob, 10000 ether);
        vm.prank(alice);
        token.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        token.approve(address(pool), type(uint256).max);
    }

    function test_anyone_can_deposit() public {
        vm.prank(alice);
        pool.deposit(cardAddr, 100 ether, MIN_LOCK);

        vm.prank(bob);
        pool.deposit(cardAddr, 50 ether, 0); // top-up, lockTime ignored

        assertEq(pool.cardTotal(cardAddr), 150 ether);
        assertEq(pool.depositRecord(cardAddr, alice), 100 ether);
        assertEq(pool.depositRecord(cardAddr, bob), 50 ether);
    }

    function test_redemption_sweeps_all_depositors() public {
        vm.prank(alice);
        pool.deposit(cardAddr, 100 ether, MIN_LOCK);
        vm.prank(bob);
        pool.deposit(cardAddr, 50 ether, 0);

        bytes32 digest = pool.getWithdrawDigest(cardAddr, recipient);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cardPk, digest);

        pool.withdraw(cardAddr, recipient, v, r, s);

        // Full pool sweep, regardless of depositor.
        assertEq(token.balanceOf(recipient), 150 ether);
    }

    function test_expired_each_depositor_reclaims_own_share() public {
        vm.prank(alice);
        pool.deposit(cardAddr, 100 ether, MIN_LOCK);
        vm.prank(bob);
        pool.deposit(cardAddr, 50 ether, 0);

        vm.warp(block.timestamp + MIN_LOCK + 1);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        pool.withdrawExpired(cardAddr);
        vm.prank(bob);
        pool.withdrawExpired(cardAddr);

        assertEq(token.balanceOf(alice) - aliceBefore, 100 ether);
        assertEq(token.balanceOf(bob) - bobBefore, 50 ether);
        assertEq(pool.cardTotal(cardAddr), 0);
    }

    /// @notice Demonstrates the grief-mitigation property: an adversary's
    ///         dust-deposit front-run does not prevent the project's intended
    ///         deposit nor does it capture the intended payout.
    function test_grief_mitigation_topup_model() public {
        // Attacker front-runs with 1 wei.
        vm.prank(bob);
        pool.deposit(cardAddr, 1, MIN_LOCK);

        // Project's intended deposit lands as a top-up.
        vm.prank(alice);
        pool.deposit(cardAddr, 100 ether, 0);

        // User redeems the full card — attacker's dust goes along, their loss.
        bytes32 digest = pool.getWithdrawDigest(cardAddr, recipient);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cardPk, digest);
        pool.withdraw(cardAddr, recipient, v, r, s);

        assertEq(token.balanceOf(recipient), 100 ether + 1);
    }
}
