// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHongBaoNFTPool
/// @notice Standard interface for a single-collection, one-shot-signature
///         redeemable lock pool for ERC721 NFTs ("NFT red packet").
///
/// @dev    Each pool is bound to exactly one ERC721 collection and exactly one
///         `initiator` (sole depositor). There is no open-deposit mode.
///
///         Each "card" is identified by an EVM address derived from a
///         single-use private key held by a hardware device, and holds exactly
///         one `tokenId` for the pool's bound collection. The device may sign
///         exactly one `Withdraw(address unlockAddress, address to)` EIP-712
///         message over its lifetime; presenting that signature transfers the
///         card's tokenId to `to`. If the card is never redeemed and its lock
///         expires, the `initiator` may reclaim the NFT via `withdrawExpired`.
interface IHongBaoNFTPool {
    // ============================================================
    //                           EVENTS
    // ============================================================

    /// @notice Emitted on a successful deposit (pull or push path).
    event Deposited(
        address indexed depositor,
        address indexed unlockAddress,
        uint256 indexed tokenId,
        uint256 expire
    );

    /// @notice Emitted when a card is redeemed with a valid device signature.
    event Withdrawn(address indexed unlockAddress, address indexed to, uint256 indexed tokenId);

    /// @notice Emitted when `initiator` reclaims an expired card's NFT.
    event WithdrawnExpired(address indexed initiator, address indexed unlockAddress, uint256 indexed tokenId);

    // ============================================================
    //                           ERRORS
    // ============================================================

    error ZeroAddress();
    error ZeroInitiator();
    error EmptyArray();

    error WrongCollection(address sender);
    error MalformedData();

    error NotInitiator(address caller);

    error LockTimeTooShort(uint256 provided, uint256 minimum);
    error CardExists(address unlockAddress);

    error NoDeposit(address unlockAddress);
    error AlreadyUnlocked(address unlockAddress);
    error NotExpired(address unlockAddress, uint256 expire);

    error InvalidSignature();

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

    /// @notice EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice EIP-712 type hash for the withdraw signature.
    function WITHDRAW_TYPEHASH() external view returns (bytes32);

    /// @notice Locked tokenId for a card. Note: a return value of zero is
    ///         ambiguous (could be a real tokenId or "no card"); use
    ///         `cardExpire() != 0` to disambiguate.
    function cardTokenId(address unlockAddress) external view returns (uint256);

    /// @notice Expiration timestamp of a card (0 iff the card has never
    ///         received a deposit).
    function cardExpire(address unlockAddress) external view returns (uint256);

    /// @notice Timestamp at which a card's NFT left the pool (0 if still held).
    ///         Set on both device-signature redemption and `withdrawExpired`.
    function cardUnlockedAt(address unlockAddress) external view returns (uint256);

    /// @notice True if the card currently holds an NFT.
    function isLocked(address unlockAddress) external view returns (bool);

    /// @notice True if the card is locked and past its expiration time.
    function isExpired(address unlockAddress) external view returns (bool);

    /// @notice Seconds remaining until `cardExpire`; 0 if already expired,
    ///         already released, or the card does not exist.
    function remainingLockTime(address unlockAddress) external view returns (uint256);

    /// @notice Compute the EIP-712 digest a device must sign.
    function getWithdrawDigest(address unlockAddress, address to) external view returns (bytes32);

    // ============================================================
    //                          MUTATIONS
    // ============================================================

    /// @notice Pull-path deposit. Initiator must have previously approved this
    ///         pool for `tokenId` (or set approval for all). `lockTime` must be
    ///         `>= MIN_LOCK_TIME`. Cards are one-shot: a given `unlockAddress`
    ///         can only ever be deposited to once.
    function deposit(address unlockAddress, uint256 tokenId, uint256 lockTime) external;

    /// @notice Redeem a card with a valid device signature; transfers the card's
    ///         tokenId to `to`. Callable by anyone; `msg.sender` pays gas.
    function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s) external;

    /// @notice After expiration and before redemption, `initiator` reclaims the
    ///         card's NFT.
    function withdrawExpired(address unlockAddress) external;

    /// @notice Batch variant of `withdrawExpired`. Entries already released
    ///         (signature-redeemed or previously reclaimed) and entries with no
    ///         deposit are silently skipped. Entries whose lock has not yet
    ///         expired cause the batch to revert. Individual `safeTransferFrom`
    ///         failures are also skipped so one bad entry does not poison the
    ///         whole batch.
    function batchWithdrawExpired(address[] calldata unlockAddresses) external;
}
