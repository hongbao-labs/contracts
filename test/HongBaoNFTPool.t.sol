// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HongBaoNFTPool} from "../src/HongBao/nft/HongBaoNFTPool.sol";
import {IHongBaoNFTPool} from "../src/HongBao/nft/interfaces/IHongBaoNFTPool.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockNonReceiver} from "./mocks/MockNonReceiver.sol";

contract HongBaoNFTPoolTest is Test {
    HongBaoNFTPool public pool;
    MockERC721 public nft;

    address initiator = address(0xA);
    address recipient = address(0xCAFE);
    uint256 constant MIN_LOCK = 30 days;

    uint256 cardPk = 0xBEEF;
    address cardAddr;

    function setUp() public {
        nft = new MockERC721("TestNFT", "TNFT");
        pool = new HongBaoNFTPool(address(nft), initiator);
        cardAddr = vm.addr(cardPk);

        vm.prank(initiator);
        nft.setApprovalForAll(address(pool), true);
    }

    // ---- helpers ----

    function _depositPull(address unlock, uint256 tokenId, uint256 lockTime) internal {
        if (nft.ownerOf(tokenId) == address(0)) nft.mint(initiator, tokenId);
        vm.prank(initiator);
        pool.deposit(unlock, tokenId, lockTime);
    }

    function _sign(uint256 pk, address unlock, address to) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = pool.getWithdrawDigest(unlock, to);
        (v, r, s) = vm.sign(pk, digest);
    }

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    function test_constructor_sets_immutables() public view {
        assertEq(pool.lockedCollection(), address(nft));
        assertEq(pool.initiator(), initiator);
        assertEq(pool.MIN_LOCK_TIME(), 30 days);
        assertTrue(pool.DOMAIN_SEPARATOR() != bytes32(0));
    }

    // ============================================================
    //                    DEPOSIT — PULL PATH
    // ============================================================

    function test_deposit_pull_ok() public {
        _depositPull(cardAddr, 1, MIN_LOCK);

        assertEq(pool.cardTokenId(cardAddr), 1);
        assertEq(pool.cardExpire(cardAddr), block.timestamp + MIN_LOCK);
        assertEq(nft.ownerOf(1), address(pool));
        assertTrue(pool.isLocked(cardAddr));
    }

    function test_deposit_revert_not_initiator() public {
        address stranger = address(0xBAD);
        nft.mint(stranger, 100);
        vm.prank(stranger);
        nft.setApprovalForAll(address(pool), true);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.NotInitiator.selector, stranger));
        pool.deposit(cardAddr, 100, MIN_LOCK);
    }

    function test_deposit_revert_lock_time_too_short() public {
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.LockTimeTooShort.selector, MIN_LOCK - 1, MIN_LOCK));
        pool.deposit(cardAddr, 1, MIN_LOCK - 1);
    }

    function test_deposit_revert_card_exists_even_after_withdraw() public {
        _depositPull(cardAddr, 1, MIN_LOCK);

        // Redeem the card.
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, cardAddr, recipient);
        pool.withdraw(cardAddr, recipient, v, r, s);

        // Same unlockAddress must remain locked forever — one-shot invariant.
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.CardExists.selector, cardAddr));
        pool.deposit(cardAddr, 2, MIN_LOCK);
    }

    // ============================================================
    //                    DEPOSIT — PUSH PATH
    // ============================================================

    function test_deposit_push_ok() public {
        nft.mint(initiator, 1);
        bytes memory data = abi.encode(cardAddr, MIN_LOCK);
        vm.prank(initiator);
        nft.safeTransferFrom(initiator, address(pool), 1, data);

        assertEq(pool.cardTokenId(cardAddr), 1);
        assertEq(pool.cardExpire(cardAddr), block.timestamp + MIN_LOCK);
        assertEq(nft.ownerOf(1), address(pool));
    }

    function test_deposit_push_revert_wrong_from() public {
        // Pranking as the collection lets us assert the pool's revert directly,
        // without it being re-wrapped by the mock's safeTransferFrom catch.
        address stranger = address(0xBAD);
        bytes memory data = abi.encode(cardAddr, MIN_LOCK);
        vm.prank(address(nft));
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.NotInitiator.selector, stranger));
        pool.onERC721Received(address(0), stranger, 1, data);
    }

    function test_deposit_push_revert_malformed_data() public {
        bytes memory badData = abi.encode(cardAddr); // 32 bytes, not 64
        vm.prank(address(nft));
        vm.expectRevert(IHongBaoNFTPool.MalformedData.selector);
        pool.onERC721Received(address(0), initiator, 1, badData);
    }

    function test_deposit_push_revert_wrong_collection() public {
        // Direct call to onERC721Received from a stranger contract address.
        MockERC721 imposter = new MockERC721("Imposter", "IMP");
        bytes memory data = abi.encode(cardAddr, MIN_LOCK);
        vm.prank(address(imposter));
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.WrongCollection.selector, address(imposter)));
        pool.onERC721Received(address(0), initiator, 1, data);
    }

    // ============================================================
    //                          WITHDRAW
    // ============================================================

    function test_withdraw_ok() public {
        _depositPull(cardAddr, 1, MIN_LOCK);
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, cardAddr, recipient);

        pool.withdraw(cardAddr, recipient, v, r, s);

        assertEq(nft.ownerOf(1), recipient);
        assertEq(pool.cardUnlockedAt(cardAddr), block.timestamp);
        assertFalse(pool.isLocked(cardAddr));
    }

    function test_withdraw_revert_invalid_signature() public {
        _depositPull(cardAddr, 1, MIN_LOCK);
        // Sign with the wrong key.
        uint256 wrongPk = 0xDEAD;
        (uint8 v, bytes32 r, bytes32 s) = _sign(wrongPk, cardAddr, recipient);

        vm.expectRevert(IHongBaoNFTPool.InvalidSignature.selector);
        pool.withdraw(cardAddr, recipient, v, r, s);
    }

    function test_withdraw_revert_already_unlocked() public {
        _depositPull(cardAddr, 1, MIN_LOCK);
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, cardAddr, recipient);
        pool.withdraw(cardAddr, recipient, v, r, s);

        // Replay the same signature.
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.AlreadyUnlocked.selector, cardAddr));
        pool.withdraw(cardAddr, recipient, v, r, s);
    }

    /// @dev Documents the sharp edge: signing for a `to` that cannot accept
    ///      ERC721 burns the card. The transfer reverts, card state is
    ///      preserved, but the device-signed (unlockAddress, to) pair cannot
    ///      be reused — `to` is committed in the signature.
    function test_withdraw_revert_to_non_receiver() public {
        _depositPull(cardAddr, 1, MIN_LOCK);

        MockNonReceiver badTo = new MockNonReceiver();
        (uint8 v, bytes32 r, bytes32 s) = _sign(cardPk, cardAddr, address(badTo));

        vm.expectRevert(MockERC721.NonReceiver.selector);
        pool.withdraw(cardAddr, address(badTo), v, r, s);

        // Card state preserved — NFT is still in the pool, card is still locked.
        assertEq(nft.ownerOf(1), address(pool));
        assertEq(pool.cardUnlockedAt(cardAddr), 0);
    }

    // ============================================================
    //                       WITHDRAW EXPIRED
    // ============================================================

    function test_withdrawExpired_ok() public {
        _depositPull(cardAddr, 1, MIN_LOCK);
        vm.warp(block.timestamp + MIN_LOCK);

        vm.prank(initiator);
        pool.withdrawExpired(cardAddr);

        assertEq(nft.ownerOf(1), initiator);
        assertEq(pool.cardUnlockedAt(cardAddr), block.timestamp);
    }

    function test_withdrawExpired_revert_not_expired() public {
        _depositPull(cardAddr, 1, MIN_LOCK);

        vm.prank(initiator);
        vm.expectRevert(
            abi.encodeWithSelector(IHongBaoNFTPool.NotExpired.selector, cardAddr, block.timestamp + MIN_LOCK)
        );
        pool.withdrawExpired(cardAddr);
    }

    // ============================================================
    //                  BATCH WITHDRAW EXPIRED
    // ============================================================

    function test_batchWithdrawExpired_ok_emits_skipped() public {
        address card1 = vm.addr(0x1);
        address card2 = vm.addr(0x2);
        address card3 = vm.addr(0x3); // no deposit on this one
        address card4 = vm.addr(0x4); // already redeemed via signature

        _depositPull(card1, 1, MIN_LOCK);
        _depositPull(card2, 2, MIN_LOCK);
        _depositPull(card4, 4, MIN_LOCK);

        // Redeem card4 before expiry.
        (uint8 v, bytes32 r, bytes32 s) = _sign(0x4, card4, recipient);
        pool.withdraw(card4, recipient, v, r, s);

        vm.warp(block.timestamp + MIN_LOCK);

        address[] memory addrs = new address[](4);
        addrs[0] = card1;
        addrs[1] = card3; // no deposit → skipped
        addrs[2] = card4; // already unlocked → skipped
        addrs[3] = card2;

        vm.expectEmit(true, false, false, true);
        emit IHongBaoNFTPool.BatchSkipped(card3);
        vm.expectEmit(true, false, false, true);
        emit IHongBaoNFTPool.BatchSkipped(card4);

        vm.prank(initiator);
        pool.batchWithdrawExpired(addrs);

        assertEq(nft.ownerOf(1), initiator);
        assertEq(nft.ownerOf(2), initiator);
        assertEq(nft.ownerOf(4), recipient); // not disturbed
    }

    function test_batchWithdrawExpired_revert_not_expired() public {
        address cardOld = vm.addr(0x1);
        address cardNew = vm.addr(0x2);

        _depositPull(cardOld, 1, MIN_LOCK);
        vm.warp(block.timestamp + 1 days);
        _depositPull(cardNew, 2, MIN_LOCK); // expires later

        vm.warp(block.timestamp + MIN_LOCK - 1 days); // only cardOld is expired

        address[] memory addrs = new address[](2);
        addrs[0] = cardOld;
        addrs[1] = cardNew;

        vm.startPrank(initiator);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.NotExpired.selector, cardNew, pool.cardExpire(cardNew)));
        pool.batchWithdrawExpired(addrs);
        vm.stopPrank();

        // cardOld state is unchanged because the whole tx reverts.
        assertEq(nft.ownerOf(1), address(pool));
        assertEq(pool.cardUnlockedAt(cardOld), 0);
    }

    function test_batchWithdrawExpired_skip_on_transfer_failure() public {
        address card1 = vm.addr(0x1);
        address card2 = vm.addr(0x2);

        _depositPull(card1, 1, MIN_LOCK);
        _depositPull(card2, 2, MIN_LOCK);

        // tokenId 1 will fail to transfer.
        nft.curse(1);

        vm.warp(block.timestamp + MIN_LOCK);

        address[] memory addrs = new address[](2);
        addrs[0] = card1;
        addrs[1] = card2;

        vm.expectEmit(true, false, false, true);
        emit IHongBaoNFTPool.BatchSkipped(card1);

        vm.prank(initiator);
        pool.batchWithdrawExpired(addrs);

        // card1 stuck (cursed), card2 reclaimed.
        assertEq(nft.ownerOf(1), address(pool));
        assertEq(pool.cardUnlockedAt(card1), 0, "card1 state preserved");
        assertEq(nft.ownerOf(2), initiator);
        assertEq(pool.cardUnlockedAt(card2), block.timestamp);
    }

    function test_batchWithdrawExpired_revert_not_initiator() public {
        _depositPull(cardAddr, 1, MIN_LOCK);
        vm.warp(block.timestamp + MIN_LOCK);

        address[] memory addrs = new address[](1);
        addrs[0] = cardAddr;

        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHongBaoNFTPool.NotInitiator.selector, stranger));
        pool.batchWithdrawExpired(addrs);
    }
}
