// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHongBaoNFTPool
/// @notice Standard interface for a single-collection redeemable lock pool
///         for ERC721 NFTs ("NFT red packet"). A pool is bound to exactly one
///         ERC721 collection and exactly one `initiator` (sole depositor) at
///         deployment.
///
///         Two card flavors share the same pool:
///
///         1. **Plain card** (`taskCount == 0`) — created via `deposit` (pull)
///            or `onERC721Received` (push). Holds exactly one `tokenId`,
///            redeemed via a one-shot EIP-712 `Withdraw(unlockAddress, to)`
///            device signature, or reclaimed by `initiator` after expiry.
///            Backwards-compatible with the original NFT pool.
///
///         2. **Task card** (`taskCount > 0`) — created via `depositWithTasks`
///            (pull-only). Holds an optional "basic" NFT released on the
///            binding signature, plus 1..255 immutable preimage-gated task
///            slots each holding one NFT. The signature serves as a
///            *binding of the recipient*: once `withdraw` runs, `to` is
///            locked in as `boundTo` and each task NFT, when claimed, is
///            forced to that bound address. A task hash is
///              keccak256(abi.encode(chainid, pool, unlockAddress, taskIdx, n))
///            — bound to chain / pool / card / slot so a preimage cannot be
///            reused across any of them.
interface IHongBaoNFTPool {
    // ============================================================
    //                           EVENTS
    // ============================================================

    /// @notice Emitted on a successful deposit (pull or push, plain or task).
    ///         For task cards, `tokenId` is the basic NFT id (or 0 if no
    ///         basic), and N additional `TaskDeposited` events are emitted.
    event Deposited(address indexed depositor, address indexed unlockAddress, uint256 indexed tokenId, uint256 expire);

    /// @notice Emitted once per task slot during `depositWithTasks`. The hash
    ///         is already bound to (chainid, pool, unlockAddress, taskIdx).
    event TaskDeposited(address indexed unlockAddress, uint8 indexed taskIdx, uint256 tokenId, bytes32 hash);

    /// @notice Emitted when a card is redeemed with a valid device signature.
    ///         For plain cards, `tokenId` is the released NFT. For task cards,
    ///         `tokenId` is the basic NFT (or 0 if `!hasBasic` — pure binding);
    ///         in both cases `to` is recorded and, for task cards, becomes
    ///         the immutable `boundTo` for subsequent task claims.
    event Withdrawn(address indexed unlockAddress, address indexed to, uint256 indexed tokenId);

    /// @notice Emitted when a task slot is successfully claimed; NFT was sent
    ///         to the card's previously bound recipient.
    event TaskClaimed(address indexed unlockAddress, uint8 indexed taskIdx, address indexed to, uint256 tokenId);

    /// @notice Emitted when `initiator` reclaims an NFT (basic or task) from
    ///         an expired card.
    event WithdrawnExpired(address indexed initiator, address indexed unlockAddress, uint256 indexed tokenId);

    /// @notice Benign skip inside `batchWithdrawExpired` — entry was already
    ///         released / never deposited / already closed (task card). No
    ///         operator action needed.
    event BatchSkipped(address indexed unlockAddress);

    /// @notice Per-entry `safeTransferFrom` reverted inside a batch entry
    ///         point (`batchWithdraw` / `batchClaimTask` / `batchWithdrawExpired`).
    ///         Card / task state preserved for retry — needs operator attention.
    event BatchTransferFailed(address indexed unlockAddress, uint256 indexed tokenId);

    // ============================================================
    //                           ERRORS
    // ============================================================

    error ZeroAddress();
    error ZeroInitiator();
    error EmptyArray();
    error ArrayLengthMismatch();

    error WrongCollection(address sender);
    error MalformedData();

    error NotInitiator(address caller);

    error LockTimeTooShort(uint256 provided, uint256 minimum);
    error CardExists(address unlockAddress);
    error CardClosed(address unlockAddress);

    error NoDeposit(address unlockAddress);
    error AlreadyUnlocked(address unlockAddress);
    error NotExpired(address unlockAddress, uint256 expire);

    error InvalidSignature();

    error TaskArrayMismatch();
    error EmptyTaskArray();
    error TooManyTasks(uint256 count);
    error NotTaskCard(address unlockAddress);
    error InvalidTaskIndex(uint8 idx, uint8 count);
    error BasicNotCompleted(address unlockAddress);
    error TaskAlreadyClaimed(address unlockAddress, uint8 idx);
    error InvalidPreimage();

    // ============================================================
    //                         STATE VIEWS
    // ============================================================

    /// @notice The ERC721 collection locked by this pool. Immutable.
    function lockedCollection() external view returns (address);

    /// @notice The sole address authorized to deposit and to reclaim expired
    ///         NFTs. Guaranteed non-zero.
    function initiator() external view returns (address);

    /// @notice Minimum allowed lock duration (seconds). Enforced on deposit.
    function MIN_LOCK_TIME() external view returns (uint256);

    /// @notice Maximum number of tasks per task card.
    function MAX_TASKS_PER_CARD() external view returns (uint8);

    /// @notice EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice EIP-712 type hash for the withdraw signature.
    function WITHDRAW_TYPEHASH() external view returns (bytes32);

    /// @notice For plain cards: the locked tokenId. For task cards with
    ///         `hasBasic`: the basic NFT id (set to 0 after basic withdraw).
    ///         For task cards with `!hasBasic`: 0. Note: tokenId zero is a
    ///         legitimate ERC721 value; use `cardExpire() != 0` for existence.
    function cardTokenId(address unlockAddress) external view returns (uint256);

    /// @notice Expiration timestamp (0 iff the card has never received a deposit).
    function cardExpire(address unlockAddress) external view returns (uint256);

    /// @notice Timestamp at which a card's basic NFT (plain or task) left the
    ///         pool, or — for plain cards — when it was redeemed/reclaimed.
    function cardUnlockedAt(address unlockAddress) external view returns (uint256);

    /// @notice Number of bonus task slots on the card. `0` = plain card.
    function cardTaskCount(address unlockAddress) external view returns (uint8);

    /// @notice Whether this task card holds a basic NFT (released on
    ///         `withdraw`). Always `false` for plain cards (they use the
    ///         legacy `tokenId` slot directly).
    function cardHasBasic(address unlockAddress) external view returns (bool);

    /// @notice Recipient bound by the device-signature `withdraw` on a task
    ///         card. `address(0)` for plain cards or task cards not yet bound.
    function cardBoundTo(address unlockAddress) external view returns (address);

    /// @notice True iff a task card has been reclaimed and closed by the
    ///         initiator via `withdrawExpired`. Closed task cards reject all
    ///         further `withdraw` / `claimTask` attempts.
    function cardClosed(address unlockAddress) external view returns (bool);

    /// @notice True iff the card still holds at least one NFT and is not closed.
    ///         For plain cards: NFT still in the pool. For task cards:
    ///         basic (if `hasBasic` & not yet withdrawn) or any unclaimed task.
    function isLocked(address unlockAddress) external view returns (bool);

    /// @notice True if the card is locked and past its expiration time.
    function isExpired(address unlockAddress) external view returns (bool);

    /// @notice Seconds remaining until `cardExpire`; 0 if already expired,
    ///         already redeemed/closed, or the card does not exist.
    function remainingLockTime(address unlockAddress) external view returns (uint256);

    /// @notice Compute the EIP-712 digest a device must sign.
    function getWithdrawDigest(address unlockAddress, address to) external view returns (bytes32);

    /// @notice Read a task slot.
    function task(address unlockAddress, uint8 taskIdx)
        external
        view
        returns (bytes32 hash, uint256 tokenId, uint256 claimedAt);

    /// @notice Compute the storage key for a task slot. Useful for off-chain
    ///         tooling; on-chain code uses the same formula internally.
    function taskKey(address unlockAddress, uint8 taskIdx) external pure returns (bytes32);

    /// @notice Compute the canonical task hash for `(chainid, pool,
    ///         unlockAddress, taskIdx, n)`. Off-chain depositors use this to
    ///         commit; claimers use it to sanity-check a preimage before
    ///         submitting on-chain.
    function computeTaskHash(address unlockAddress, uint8 taskIdx, bytes calldata n)
        external
        view
        returns (bytes32);

    // ============================================================
    //                          MUTATIONS
    // ============================================================

    /// @notice Pull-path plain-card deposit. Initiator must have previously
    ///         approved this pool for `tokenId` (or set approval for all).
    ///         `lockTime` must be `>= MIN_LOCK_TIME`. Cards are one-shot:
    ///         a given `unlockAddress` can only ever be deposited to once
    ///         on this pool.
    function deposit(address unlockAddress, uint256 tokenId, uint256 lockTime) external;

    /// @notice Pull-only task-card creation. Initiator must own and have
    ///         approved every NFT involved (basic if `hasBasic`, plus every
    ///         task tokenId). All transfers happen atomically — any single
    ///         `transferFrom` revert (e.g. unapproved tokenId) reverts the
    ///         whole call and rolls back state.
    ///
    ///         `taskHashes[i]` must equal `keccak256(abi.encode(block.chainid,
    ///         address(this), unlockAddress, uint8(i), preimage_i))` for
    ///         `claimTask` to succeed later. `taskHashes.length` must be in
    ///         `[1, MAX_TASKS_PER_CARD]` and match `taskTokenIds.length`.
    ///         Task slots are immutable after creation.
    function depositWithTasks(
        address unlockAddress,
        bool hasBasic,
        uint256 basicTokenId,
        bytes32[] calldata taskHashes,
        uint256[] calldata taskTokenIds,
        uint256 lockTime
    ) external;

    /// @notice Atomic batch of `depositWithTasks`. All input arrays must share
    ///         the same length. Reverts the whole batch on any single failure.
    function batchDepositWithTasks(
        address[] calldata unlockAddresses,
        bool[] calldata hasBasics,
        uint256[] calldata basicTokenIds,
        bytes32[][] calldata taskHashes,
        uint256[][] calldata taskTokenIds,
        uint256 lockTime
    ) external;

    /// @notice Redeem a card with a valid device signature.
    ///         - Plain card: transfers the NFT to `to`; card is consumed.
    ///         - Task card: transfers `basic` NFT to `to` (if `hasBasic`),
    ///           records `boundTo = to`, marks `unlockedAt`. Task slots remain
    ///           claimable; their NFTs will be forced to this `to`.
    ///         Callable by anyone; `msg.sender` pays gas.
    function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s) external;

    /// @notice Batch variant of `withdraw`, intended for relayer use.
    ///         Entries that would individually revert (already redeemed, card
    ///         closed, no deposit, invalid signature, zero `to`) are silently
    ///         skipped. Per-entry `safeTransferFrom` failures emit
    ///         `BatchTransferFailed` and leave state untouched for retry. All
    ///         input arrays must share the same length.
    function batchWithdraw(
        address[] calldata unlockAddresses,
        address[] calldata tos,
        uint8[] calldata vs,
        bytes32[] calldata rs,
        bytes32[] calldata ss
    ) external;

    /// @notice Claim a task slot. Anyone may call; the slot's NFT is forced
    ///         to the card's previously bound recipient. Requires:
    ///           - the card is a task card and not closed,
    ///           - the device-signature `withdraw` has already bound `boundTo`,
    ///           - this task slot is not yet claimed,
    ///           - `keccak256(abi.encode(block.chainid, address(this),
    ///                                   unlockAddress, taskIdx, n))
    ///              == taskHashes[taskIdx]`.
    function claimTask(address unlockAddress, uint8 taskIdx, bytes calldata n) external;

    /// @notice Batch variant of `claimTask`. Per-entry failures (not a task
    ///         card, out-of-range, closed, basic not completed, already
    ///         claimed, preimage mismatch) are silently skipped. Per-entry
    ///         `safeTransferFrom` failures emit `BatchTransferFailed` and
    ///         leave the slot unclaimed for retry.
    function batchClaimTask(
        address[] calldata unlockAddresses,
        uint8[] calldata taskIdxs,
        bytes[] calldata preimages
    ) external;

    /// @notice After expiration, the initiator reclaims unclaimed NFTs.
    ///         - Plain card: transfers the still-held NFT to initiator.
    ///         - Task card: transfers the basic NFT (if `hasBasic` and not yet
    ///           withdrawn) plus every unclaimed task NFT to initiator,
    ///           sets `closed = true`. Reverts on first transfer failure.
    function withdrawExpired(address unlockAddress) external;

    /// @notice Batch variant of `withdrawExpired`. Already-released /
    ///         never-deposited / closed entries are skipped (`BatchSkipped`).
    ///         Not-yet-expired entries revert the batch (programming error).
    ///         Per-entry / per-slot transfer failures emit
    ///         `BatchTransferFailed`; for task cards, the card is closed only
    ///         when every slot succeeded — partial failures leave the card
    ///         open for retry.
    function batchWithdrawExpired(address[] calldata unlockAddresses) external;
}
