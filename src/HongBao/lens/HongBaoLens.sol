// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHongBaoTokenPool} from "../token/interfaces/IHongBaoTokenPool.sol";
import {IHongBaoNFTPool} from "../nft/interfaces/IHongBaoNFTPool.sol";

/// @title HongBaoLens
/// @notice Read-only aggregator for `HongBaoTokenPool` / `HongBaoNFTPool`.
///         Collapses many per-card view calls (including dynamic task slots)
///         into a single eth_call, drastically reducing RPC traffic for
///         wallets and dashboards.
///
/// @dev    Stateless and permissionless. Deploy once per chain and reuse for
///         every pool — does not require pool modification or redeployment.
contract HongBaoLens {
    // ============================================================
    //                          STRUCTS
    // ============================================================

    struct TokenTaskView {
        bytes32 hash;
        uint256 amount;
        uint256 claimedAt; // 0 = unclaimed
    }

    struct TokenCardView {
        // raw card fields
        uint256 totalAmount;
        uint256 expire;
        uint256 unlockedAt;
        uint256 basicAmount;
        address boundTo;
        uint8 taskCount; // 0 = plain card; >0 = task card
        bool closed;
        // derived view-helpers
        bool isLocked;
        bool isExpired;
        uint256 remainingLockTime;
        // task slots; length == taskCount (empty for plain cards)
        TokenTaskView[] tasks;
    }

    struct NFTCardView {
        uint256 tokenId;
        uint256 expire;
        uint256 unlockedAt;
        bool isLocked;
        bool isExpired;
        uint256 remainingLockTime;
    }

    struct TokenPoolInfo {
        address lockedToken;
        address initiator;
        uint256 minLockTime;
        bytes32 domainSeparator;
        bytes32 withdrawTypehash;
        uint8 maxTasksPerCard;
    }

    struct NFTPoolInfo {
        address lockedCollection;
        address initiator;
        uint256 minLockTime;
        bytes32 domainSeparator;
        bytes32 withdrawTypehash;
    }

    // ============================================================
    //                       TOKEN POOL LENS
    // ============================================================

    /// @notice Fetch one card's complete state (incl. all task slots) in one call.
    function getTokenCard(IHongBaoTokenPool pool, address unlockAddress)
        public
        view
        returns (TokenCardView memory v)
    {
        v.totalAmount = pool.cardTotal(unlockAddress);
        v.expire = pool.cardExpire(unlockAddress);
        v.unlockedAt = pool.cardUnlockedAt(unlockAddress);
        v.basicAmount = pool.cardBasicAmount(unlockAddress);
        v.boundTo = pool.cardBoundTo(unlockAddress);
        v.taskCount = pool.cardTaskCount(unlockAddress);
        v.closed = pool.cardClosed(unlockAddress);
        v.isLocked = pool.isLocked(unlockAddress);
        v.isExpired = pool.isExpired(unlockAddress);
        v.remainingLockTime = pool.remainingLockTime(unlockAddress);

        if (v.taskCount > 0) {
            v.tasks = new TokenTaskView[](v.taskCount);
            for (uint8 i = 0; i < v.taskCount;) {
                (bytes32 hash_, uint256 amount, uint256 claimedAt) = pool.task(unlockAddress, i);
                v.tasks[i] = TokenTaskView({hash: hash_, amount: amount, claimedAt: claimedAt});
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @notice Batch fetch many cards from one pool in a single call.
    function getTokenCards(IHongBaoTokenPool pool, address[] calldata unlockAddresses)
        external
        view
        returns (TokenCardView[] memory views)
    {
        uint256 n = unlockAddresses.length;
        views = new TokenCardView[](n);
        for (uint256 i = 0; i < n;) {
            views[i] = getTokenCard(pool, unlockAddresses[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Fetch a token pool's immutable / pool-level fields in one call.
    function getTokenPoolInfo(IHongBaoTokenPool pool) external view returns (TokenPoolInfo memory info) {
        info.lockedToken = pool.lockedToken();
        info.initiator = pool.initiator();
        info.minLockTime = pool.MIN_LOCK_TIME();
        info.domainSeparator = pool.DOMAIN_SEPARATOR();
        info.withdrawTypehash = pool.WITHDRAW_TYPEHASH();
        info.maxTasksPerCard = pool.MAX_TASKS_PER_CARD();
    }

    // ============================================================
    //                        NFT POOL LENS
    // ============================================================

    /// @notice Fetch one NFT card's complete state in one call.
    function getNFTCard(IHongBaoNFTPool pool, address unlockAddress) public view returns (NFTCardView memory v) {
        v.tokenId = pool.cardTokenId(unlockAddress);
        v.expire = pool.cardExpire(unlockAddress);
        v.unlockedAt = pool.cardUnlockedAt(unlockAddress);
        v.isLocked = pool.isLocked(unlockAddress);
        v.isExpired = pool.isExpired(unlockAddress);
        v.remainingLockTime = pool.remainingLockTime(unlockAddress);
    }

    /// @notice Batch fetch many NFT cards from one pool in a single call.
    function getNFTCards(IHongBaoNFTPool pool, address[] calldata unlockAddresses)
        external
        view
        returns (NFTCardView[] memory views)
    {
        uint256 n = unlockAddresses.length;
        views = new NFTCardView[](n);
        for (uint256 i = 0; i < n;) {
            views[i] = getNFTCard(pool, unlockAddresses[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Fetch an NFT pool's immutable / pool-level fields in one call.
    function getNFTPoolInfo(IHongBaoNFTPool pool) external view returns (NFTPoolInfo memory info) {
        info.lockedCollection = pool.lockedCollection();
        info.initiator = pool.initiator();
        info.minLockTime = pool.MIN_LOCK_TIME();
        info.domainSeparator = pool.DOMAIN_SEPARATOR();
        info.withdrawTypehash = pool.WITHDRAW_TYPEHASH();
    }
}
