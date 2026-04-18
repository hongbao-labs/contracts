// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHongBaoPool
/// @notice Standard interface for a single-token, one-shot-signature redeemable
///         lock pool ("red packet"). A pool is bound to exactly one ERC20 token
///         at deployment and optionally bound to a single depositor ("initiator").
///
///         Each "card" is identified by an EVM address derived from a single-use
///         private key held by a hardware device. The device may sign exactly one
///         `Withdraw(address unlockAddress, address to)` EIP-712 message over its
///         lifetime. Presentation of that signature redeems the card's full
///         balance to `to`. If the card is never redeemed and its lock expires,
///         each depositor may reclaim their own contribution.
interface IHongBaoPool {
    // ============================================================
    //                           EVENTS
    // ============================================================

    /// @notice Emitted on every deposit (including top-ups).
    /// @param depositor    The address that provided the funds.
    /// @param unlockAddress The card's public-key address.
    /// @param amount       The amount added by this deposit.
    /// @param newTotal     The resulting `totalAmount` on the card.
    /// @param expire       The card's immutable expiration timestamp.
    event Deposited(
        address indexed depositor,
        address indexed unlockAddress,
        uint256 amount,
        uint256 newTotal,
        uint256 expire
    );

    /// @notice Emitted when a card is redeemed with a valid device signature.
    event Withdrawn(address indexed unlockAddress, address indexed to, uint256 amount);

    /// @notice Emitted when a depositor reclaims their share after expiration.
    event WithdrawnExpired(address indexed depositor, address indexed unlockAddress, uint256 amount);

    // ============================================================
    //                           ERRORS
    // ============================================================

    error ZeroAmount();
    error ZeroAddress();
    error EmptyArray();

    error NotInitiator(address caller);

    error LockTimeTooShort(uint256 provided, uint256 minimum);
    error CardExpired(address unlockAddress);

    error NoDeposit(address unlockAddress);
    error AlreadyUnlocked(address unlockAddress);
    error NotExpired(address unlockAddress, uint256 expire);
    error NoShare(address unlockAddress, address depositor);

    error InvalidSignature();

    // ============================================================
    //                         STATE VIEWS
    // ============================================================

    /// @notice The ERC20 token locked by this pool. Immutable.
    function lockedToken() external view returns (address);

    /// @notice The sole address authorized to deposit. `address(0)` means the
    ///         pool is permissionless and anyone may deposit.
    function initiator() external view returns (address);

    /// @notice Minimum allowed lock duration (seconds). Enforced on the first
    ///         deposit to a card.
    function MIN_LOCK_TIME() external view returns (uint256);

    /// @notice EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice EIP-712 type hash for the withdraw signature.
    function WITHDRAW_TYPEHASH() external view returns (bytes32);

    /// @notice Current claimable balance of a card.
    function cardTotal(address unlockAddress) external view returns (uint256);

    /// @notice Expiration timestamp of a card (0 if the card has never received
    ///         a deposit).
    function cardExpire(address unlockAddress) external view returns (uint256);

    /// @notice Timestamp at which a card was redeemed (0 if not redeemed).
    function cardUnlockedAt(address unlockAddress) external view returns (uint256);

    /// @notice A depositor's outstanding share on a card, reclaimable after
    ///         expiration via `withdrawExpired`.
    function depositRecord(address unlockAddress, address depositor) external view returns (uint256);

    /// @notice True if the card has funds and has not been redeemed.
    function isLocked(address unlockAddress) external view returns (bool);

    /// @notice True if the card is locked and past its expiration time.
    function isExpired(address unlockAddress) external view returns (bool);

    /// @notice Seconds remaining until `cardExpire`; 0 if already expired, unredeemed, or empty.
    function remainingLockTime(address unlockAddress) external view returns (uint256);

    /// @notice Compute the EIP-712 digest a device must sign.
    function getWithdrawDigest(address unlockAddress, address to) external view returns (bytes32);

    // ============================================================
    //                          MUTATIONS
    // ============================================================

    /// @notice Deposit `amount` of `lockedToken` into `unlockAddress`.
    ///         - First deposit sets the card's expiration to
    ///           `block.timestamp + lockTime`; `lockTime` must be
    ///           `>= MIN_LOCK_TIME`.
    ///         - Subsequent deposits (top-ups) ignore `lockTime` and require
    ///           the card to be neither redeemed nor expired.
    function deposit(address unlockAddress, uint256 amount, uint256 lockTime) external;

    /// @notice Deposit the same `amount` to each of `unlockAddresses`. On a
    ///         fresh card the `lockTime` is applied; on an existing card the
    ///         deposit is treated as a top-up.
    function batchDeposit(address[] calldata unlockAddresses, uint256 amount, uint256 lockTime) external;

    /// @notice Redeem a card's full balance to `to` using a device signature.
    ///         Callable by anyone; `msg.sender` pays gas.
    function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s) external;

    /// @notice After expiration and before redemption, reclaim the caller's
    ///         share on a card.
    function withdrawExpired(address unlockAddress) external;

    /// @notice Batch variant of `withdrawExpired`. Entries that have already
    ///         been redeemed via device signature, and entries on which the
    ///         caller has no outstanding share, are silently skipped. Entries
    ///         whose lock has not yet expired still cause the batch to revert.
    function batchWithdrawExpired(address[] calldata unlockAddresses) external;
}
