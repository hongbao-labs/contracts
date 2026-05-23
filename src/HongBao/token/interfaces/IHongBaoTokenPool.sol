// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHongBaoTokenPool
/// @notice Standard interface for a single-ERC20 redeemable lock pool ("red
///         packet"). A pool is bound to exactly one ERC20 token at deployment
///         and optionally bound to a single depositor ("initiator").
///
///         Two card flavors share the same pool:
///
///         1. **Plain card** (`taskCount == 0`)
///            Created by `deposit` / `batchDeposit`. The card's full balance is
///            redeemable to `to` via a one-shot EIP-712 device signature over
///            `Withdraw(unlockAddress, to)`. Existing integrations continue to
///            work unchanged.
///
///         2. **Task card** (`taskCount > 0`)
///            Created by `depositWithTasks`, restricted-mode only. Funds split
///            into a `basicAmount` (released to `to` on device-signature
///            withdraw) and 1..255 hashed bonus tasks. The signature now serves
///            as a *binding* of the recipient address: once `withdraw` runs,
///            `to` is locked in as `boundTo`. Each subsequent task is claimed by
///            anyone presenting its preimage; funds are forced to `boundTo`,
///            so leaking a preimage to a third party is non-fatal as long as
///            the device-signed binding has already happened to a trusted `to`.
///
///         A task hash is
///           keccak256(abi.encode(chainid, pool, unlockAddress, taskIdx, n))
///         — bound to this chain, this pool, this card, and this slot, so a
///         preimage cannot be reused across chains, pools, cards, or slots.
interface IHongBaoTokenPool {
    // ============================================================
    //                           EVENTS
    // ============================================================

    /// @notice Emitted on every plain deposit (incl. top-ups) and on the
    ///         basic-portion of a task card creation.
    /// @param depositor    The address that provided the funds.
    /// @param unlockAddress The card's public-key address.
    /// @param amount       The amount added by this deposit.
    /// @param newTotal     The resulting `totalAmount` on the card.
    /// @param expire       The card's immutable expiration timestamp.
    event Deposited(
        address indexed depositor, address indexed unlockAddress, uint256 amount, uint256 newTotal, uint256 expire
    );

    /// @notice Emitted once per task slot during `depositWithTasks`. The hash is
    ///         already bound to (pool, unlockAddress, taskIdx) by construction.
    event TaskDeposited(address indexed unlockAddress, uint8 indexed taskIdx, uint256 amount, bytes32 hash);

    /// @notice Emitted when a card is redeemed with a valid device signature.
    ///         For a task card, `amount` is the released `basicAmount` (may be
    ///         zero) and `to` becomes the immutable `boundTo` for subsequent
    ///         task claims.
    event Withdrawn(address indexed unlockAddress, address indexed to, uint256 amount);

    /// @notice Emitted when a task is successfully claimed; funds were sent to
    ///         the card's previously bound recipient.
    event TaskClaimed(address indexed unlockAddress, uint8 indexed taskIdx, address indexed to, uint256 amount);

    /// @notice Emitted when a depositor reclaims an expired plain card share,
    ///         or when `initiator` reclaims an expired task card's remainder.
    event WithdrawnExpired(address indexed depositor, address indexed unlockAddress, uint256 amount);

    // ============================================================
    //                           ERRORS
    // ============================================================

    error ZeroAmount();
    error ZeroAddress();
    error EmptyArray();
    error ArrayLengthMismatch();

    error NotInitiator(address caller);
    error OpenModeNotSupported();

    error LockTimeTooShort(uint256 provided, uint256 minimum);
    error CardExpired(address unlockAddress);
    error CardExists(address unlockAddress);
    error CardClosed(address unlockAddress);

    error NoDeposit(address unlockAddress);
    error AlreadyUnlocked(address unlockAddress);
    error NotExpired(address unlockAddress, uint256 expire);
    error NoShare(address unlockAddress, address depositor);

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

    /// @notice The ERC20 token locked by this pool. Immutable.
    function lockedToken() external view returns (address);

    /// @notice The sole address authorized to deposit. `address(0)` means the
    ///         pool is permissionless and anyone may deposit plain cards.
    ///         Task cards are restricted-mode only.
    function initiator() external view returns (address);

    /// @notice Minimum allowed lock duration (seconds). Enforced on card creation.
    function MIN_LOCK_TIME() external view returns (uint256);

    /// @notice Maximum number of tasks per task card.
    function MAX_TASKS_PER_CARD() external view returns (uint8);

    /// @notice EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice EIP-712 type hash for the withdraw signature.
    function WITHDRAW_TYPEHASH() external view returns (bytes32);

    /// @notice Current claimable balance of a card (basic + unclaimed tasks).
    function cardTotal(address unlockAddress) external view returns (uint256);

    /// @notice Expiration timestamp of a card (0 if the card has never received
    ///         a deposit).
    function cardExpire(address unlockAddress) external view returns (uint256);

    /// @notice Timestamp at which a card was first redeemed (0 if not yet).
    ///         For task cards, set by the device-signature `withdraw` that
    ///         binds `to`; the card itself can still pay out via `claimTask`.
    function cardUnlockedAt(address unlockAddress) external view returns (uint256);

    /// @notice Amount released on the next device-signature `withdraw`. For
    ///         plain cards this mirrors `cardTotal`; for task cards this is
    ///         the basic portion (top-ups go into this slot until withdraw).
    function cardBasicAmount(address unlockAddress) external view returns (uint256);

    /// @notice Number of bonus task slots on the card. `0` = plain card.
    function cardTaskCount(address unlockAddress) external view returns (uint8);

    /// @notice Recipient bound by the device-signature withdraw on a task card,
    ///         or `address(0)` if not yet bound (or a plain card).
    function cardBoundTo(address unlockAddress) external view returns (address);

    /// @notice True iff a task card has been fully reclaimed by the initiator
    ///         via `withdrawExpired`. A closed task card refuses further
    ///         claims and top-ups.
    function cardClosed(address unlockAddress) external view returns (bool);

    /// @notice A depositor's outstanding share on a card, reclaimable after
    ///         expiration via `withdrawExpired`.
    function depositRecord(address unlockAddress, address depositor) external view returns (uint256);

    /// @notice True if the card has funds and is still claimable by holders.
    ///         For plain cards: balance > 0 and not yet redeemed.
    ///         For task cards: balance > 0 and not yet closed by the initiator.
    function isLocked(address unlockAddress) external view returns (bool);

    /// @notice True if the card is locked and past its expiration time.
    function isExpired(address unlockAddress) external view returns (bool);

    /// @notice Seconds remaining until `cardExpire`; 0 if already expired,
    ///         already closed/redeemed, or empty.
    function remainingLockTime(address unlockAddress) external view returns (uint256);

    /// @notice Compute the EIP-712 digest a device must sign.
    function getWithdrawDigest(address unlockAddress, address to) external view returns (bytes32);

    /// @notice Read a task slot.
    function task(address unlockAddress, uint8 taskIdx)
        external
        view
        returns (bytes32 hash, uint256 amount, uint256 claimedAt);

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

    /// @notice Deposit `amount` of `lockedToken` into `unlockAddress`.
    ///         - First deposit creates a plain card; `lockTime` must be
    ///           `>= MIN_LOCK_TIME`.
    ///         - Subsequent deposits (top-ups) ignore `lockTime`. On a task
    ///           card, the top-up is added to `basicAmount` only — task slots
    ///           are immutable.
    ///         - Top-ups require the card to be neither redeemed (plain) /
    ///           bound (task) nor expired nor closed.
    function deposit(address unlockAddress, uint256 amount, uint256 lockTime) external;

    /// @notice Deposit the same `amount` to each of `unlockAddresses`.
    function batchDeposit(address[] calldata unlockAddresses, uint256 amount, uint256 lockTime) external;

    /// @notice Create a task card. Restricted-mode pools only.
    ///         The card holds `basicAmount + sum(taskAmounts)` in total.
    ///         `taskHashes[i]` must equal
    ///           `keccak256(abi.encode(block.chainid, address(this),
    ///                                  unlockAddress, uint8(i), preimage_i))`
    ///         for `claimTask` to succeed later. `taskHashes.length` must be
    ///         in `[1, 255]` and match `taskAmounts.length`. Task slots are
    ///         immutable after creation — only `basicAmount` may be topped
    ///         up via `deposit`.
    function depositWithTasks(
        address unlockAddress,
        uint256 basicAmount,
        bytes32[] calldata taskHashes,
        uint256[] calldata taskAmounts,
        uint256 lockTime
    ) external;

    /// @notice Atomic batch of `depositWithTasks`. Each card has its own
    ///         `basicAmount` and `(taskHashes, taskAmounts)` pair. All cards
    ///         share `lockTime`. Reverts the whole batch on any single failure.
    function batchDepositWithTasks(
        address[] calldata unlockAddresses,
        uint256[] calldata basicAmounts,
        bytes32[][] calldata taskHashes,
        uint256[][] calldata taskAmounts,
        uint256 lockTime
    ) external;

    /// @notice Redeem a card with a valid device signature.
    ///         - Plain card: transfers full balance to `to`; card is consumed.
    ///         - Task card: transfers `basicAmount` to `to` (may be 0), records
    ///           `boundTo = to`, marks `unlockedAt`. Task slots remain
    ///           claimable; their funds will be forced to this `to`.
    ///         Callable by anyone; `msg.sender` pays gas.
    function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s) external;

    /// @notice Batch variant of `withdraw`, intended for relayer / sponsor use.
    ///         Entries that would individually revert (already redeemed, card
    ///         closed, empty card, invalid signature, zero `to`) are **silently
    ///         skipped** so one bad request does not poison the batch. All
    ///         input arrays must share the same length. Off-chain consumers
    ///         detect outcome via `Withdrawn` event presence per `unlockAddress`.
    function batchWithdraw(
        address[] calldata unlockAddresses,
        address[] calldata tos,
        uint8[] calldata vs,
        bytes32[] calldata rs,
        bytes32[] calldata ss
    ) external;

    /// @notice Claim a task slot. Anyone may call; the slot's amount is forced
    ///         to the card's previously bound recipient. Requires:
    ///           - the card is a task card and not closed,
    ///           - the device-signature `withdraw` has already bound `boundTo`,
    ///           - this task slot is not yet claimed,
    ///           - `keccak256(abi.encode(block.chainid, address(this),
    ///                                   unlockAddress, taskIdx, n))
    ///              == taskHashes[taskIdx]`.
    function claimTask(address unlockAddress, uint8 taskIdx, bytes calldata n) external;

    /// @notice Batch variant of `claimTask`, intended for relayer / sponsor use.
    ///         Entries that would individually revert (not a task card, idx
    ///         out of range, card closed, basic not completed, slot already
    ///         claimed, preimage mismatch) are **silently skipped** so one bad
    ///         request does not poison the batch. All input arrays must share
    ///         the same length. Off-chain consumers detect outcome via the
    ///         `TaskClaimed` event presence per `(unlockAddress, taskIdx)`.
    function batchClaimTask(
        address[] calldata unlockAddresses,
        uint8[] calldata taskIdxs,
        bytes[] calldata preimages
    ) external;

    /// @notice After expiration, reclaim funds.
    ///         - Plain card: caller reclaims their own depositRecord share.
    ///         - Task card: `initiator` reclaims the entire remainder
    ///           (unclaimed basic + unclaimed tasks) and closes the card. Once
    ///           closed, `withdraw` and `claimTask` revert.
    function withdrawExpired(address unlockAddress) external;

    /// @notice Batch variant of `withdrawExpired`. Entries that have already
    ///         been redeemed (plain) / closed (task) and entries on which the
    ///         caller has no claim are silently skipped. Entries whose lock
    ///         has not yet expired cause the batch to revert.
    function batchWithdrawExpired(address[] calldata unlockAddresses) external;
}
