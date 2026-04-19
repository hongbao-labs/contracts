// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "../shared/interfaces/IERC721.sol";
import {IERC721Receiver} from "../shared/interfaces/IERC721Receiver.sol";
import {IHongBaoNFTPool} from "./interfaces/IHongBaoNFTPool.sol";
import {ReentrancyGuard} from "../shared/utils/ReentrancyGuard.sol";

/// @title HongBaoNFTPool
/// @notice One-shot signature redeemable lock pool for a single ERC721 collection.
///
/// @dev    One pool binds exactly one ERC721 collection and exactly one
///         `initiator` (the sole authorized depositor). There is no open mode.
///
///         Each "card" is an EVM address derived from a single-use private key
///         held by a hardware device and holds exactly one `tokenId`. The
///         device may produce at most one EIP-712 `Withdraw(unlockAddress, to)`
///         signature over its lifetime; presenting that signature transfers
///         the NFT to `to`.
///
///         Two deposit paths, semantically identical:
///           - Pull: initiator approves the pool and calls `deposit(...)`.
///           - Push: initiator calls `lockedCollection.safeTransferFrom(
///                   initiator, pool, tokenId, abi.encode(unlockAddress, lockTime))`.
///
///         IMPORTANT: `withdraw` and `withdrawExpired` use `safeTransferFrom`.
///         If `to` (or `initiator` on the expired path) is a contract that
///         does not implement `IERC721Receiver`, the transfer reverts and the
///         NFT stays in the pool. Because the hardware device can only sign
///         a given (unlockAddress, to) pair once, a bad `to` effectively
///         destroys the NFT for that card. Clients MUST validate `to` before
///         asking the device to sign — preferably an EOA.
///
///         This contract holds no administrative privileges: no owner, no
///         pause, no upgradability, no fees.
contract HongBaoNFTPool is IHongBaoNFTPool, IERC721Receiver, ReentrancyGuard {
    // ============================================================
    //                          CONSTANTS
    // ============================================================

    /// @inheritdoc IHongBaoNFTPool
    uint256 public constant MIN_LOCK_TIME = 30 days;

    /// @inheritdoc IHongBaoNFTPool
    bytes32 public constant WITHDRAW_TYPEHASH = keccak256("Withdraw(address unlockAddress,address to)");

    // ============================================================
    //                         IMMUTABLES
    // ============================================================

    /// @inheritdoc IHongBaoNFTPool
    address public immutable lockedCollection;

    /// @inheritdoc IHongBaoNFTPool
    address public immutable initiator;

    /// @inheritdoc IHongBaoNFTPool
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ============================================================
    //                          STORAGE
    // ============================================================

    struct Card {
        uint256 tokenId;
        uint256 expire;
        uint256 unlockedAt;
    }

    mapping(address => Card) internal _cards;

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    /// @param _collection ERC721 collection. Must be non-zero.
    /// @param _initiator  Sole depositor / expiry-reclaim address. Must be non-zero.
    constructor(address _collection, address _initiator) {
        if (_collection == address(0)) revert ZeroAddress();
        if (_initiator == address(0)) revert ZeroInitiator();
        lockedCollection = _collection;
        initiator = _initiator;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("HongBao"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ============================================================
    //                     DEPOSIT — PULL PATH
    // ============================================================

    /// @inheritdoc IHongBaoNFTPool
    function deposit(address unlockAddress, uint256 tokenId, uint256 lockTime) external nonReentrant {
        if (msg.sender != initiator) revert NotInitiator(msg.sender);

        _registerDeposit(msg.sender, unlockAddress, tokenId, lockTime);

        // Plain `transferFrom` rather than `safeTransferFrom`: we are already
        // executing inside `deposit` and must not re-enter `onERC721Received`.
        IERC721(lockedCollection).transferFrom(msg.sender, address(this), tokenId);
    }

    // ============================================================
    //                     DEPOSIT — PUSH PATH
    // ============================================================

    /// @notice ERC721 receiver hook used as the push-style deposit entry point.
    /// @dev    Accepts a transfer only if:
    ///           - `msg.sender == lockedCollection` (pool is bound to exactly
    ///             one collection; drops from any other contract revert), and
    ///           - `from == initiator` (only the initiator may deposit).
    ///         `data` must be `abi.encode(address unlockAddress, uint256 lockTime)`.
    ///         Returns the ERC721 magic value on success.
    function onERC721Received(
        address, /* operator */
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external nonReentrant returns (bytes4) {
        if (msg.sender != lockedCollection) revert WrongCollection(msg.sender);
        if (from != initiator) revert NotInitiator(from);
        // abi.encode(address, uint256) is exactly 64 bytes.
        if (data.length != 64) revert MalformedData();

        (address unlockAddress, uint256 lockTime) = abi.decode(data, (address, uint256));
        _registerDeposit(from, unlockAddress, tokenId, lockTime);

        return IERC721Receiver.onERC721Received.selector;
    }

    function _registerDeposit(
        address depositor,
        address unlockAddress,
        uint256 tokenId,
        uint256 lockTime
    ) internal {
        if (unlockAddress == address(0)) revert ZeroAddress();
        if (lockTime < MIN_LOCK_TIME) revert LockTimeTooShort(lockTime, MIN_LOCK_TIME);

        Card storage card = _cards[unlockAddress];
        // A card is one-shot: any prior deposit (active, expired, or already
        // released) locks the `unlockAddress` forever on this pool.
        if (card.expire != 0) revert CardExists(unlockAddress);

        uint256 expire = block.timestamp + lockTime;
        card.tokenId = tokenId;
        card.expire = expire;

        emit Deposited(depositor, unlockAddress, tokenId, expire);
    }

    // ============================================================
    //                  WITHDRAW (DEVICE SIGNATURE)
    // ============================================================

    /// @inheritdoc IHongBaoNFTPool
    function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        Card storage card = _cards[unlockAddress];
        if (card.unlockedAt != 0) revert AlreadyUnlocked(unlockAddress);
        if (card.expire == 0) revert NoDeposit(unlockAddress);

        _verifySignature(unlockAddress, to, v, r, s);

        uint256 tokenId = card.tokenId;
        card.unlockedAt = block.timestamp;

        // See the top-of-file note: if `to` is a non-IERC721Receiver contract,
        // this reverts — by design, the device's signature is one-shot and the
        // NFT is effectively lost. Clients must vet `to` before signing.
        IERC721(lockedCollection).safeTransferFrom(address(this), to, tokenId);

        emit Withdrawn(unlockAddress, to, tokenId);
    }

    // ============================================================
    //                      WITHDRAW EXPIRED
    // ============================================================

    /// @inheritdoc IHongBaoNFTPool
    function withdrawExpired(address unlockAddress) external nonReentrant {
        if (msg.sender != initiator) revert NotInitiator(msg.sender);
        Card storage card = _cards[unlockAddress];
        if (card.unlockedAt != 0) revert AlreadyUnlocked(unlockAddress);
        if (card.expire == 0) revert NoDeposit(unlockAddress);
        if (block.timestamp < card.expire) revert NotExpired(unlockAddress, card.expire);

        uint256 tokenId = card.tokenId;
        card.unlockedAt = block.timestamp;

        IERC721(lockedCollection).safeTransferFrom(address(this), initiator, tokenId);

        emit WithdrawnExpired(initiator, unlockAddress, tokenId);
    }

    /// @inheritdoc IHongBaoNFTPool
    function batchWithdrawExpired(address[] calldata unlockAddresses) external nonReentrant {
        if (msg.sender != initiator) revert NotInitiator(msg.sender);
        uint256 len = unlockAddresses.length;
        if (len == 0) revert EmptyArray();

        for (uint256 i = 0; i < len; i++) {
            address addr = unlockAddresses[i];
            Card storage card = _cards[addr];

            // Silently skip already-released entries and no-deposit slots.
            if (card.unlockedAt != 0) continue;
            if (card.expire == 0) continue;

            // Not-yet-expired entries hard-revert so the caller notices the
            // programming error instead of silently doing nothing.
            if (block.timestamp < card.expire) revert NotExpired(addr, card.expire);

            uint256 tokenId = card.tokenId;

            // Attempt the transfer; if the NFT contract rejects it for any
            // reason (malicious hook, paused collection, etc.), skip this
            // card and leave its state untouched so a later retry is possible.
            try IERC721(lockedCollection).safeTransferFrom(address(this), initiator, tokenId) {
                card.unlockedAt = block.timestamp;
                emit WithdrawnExpired(initiator, addr, tokenId);
            } catch {
                continue;
            }
        }
    }

    // ============================================================
    //                            VIEWS
    // ============================================================

    /// @inheritdoc IHongBaoNFTPool
    function cardTokenId(address unlockAddress) external view returns (uint256) {
        return _cards[unlockAddress].tokenId;
    }

    /// @inheritdoc IHongBaoNFTPool
    function cardExpire(address unlockAddress) external view returns (uint256) {
        return _cards[unlockAddress].expire;
    }

    /// @inheritdoc IHongBaoNFTPool
    function cardUnlockedAt(address unlockAddress) external view returns (uint256) {
        return _cards[unlockAddress].unlockedAt;
    }

    /// @inheritdoc IHongBaoNFTPool
    function isLocked(address unlockAddress) external view returns (bool) {
        Card storage card = _cards[unlockAddress];
        return card.expire != 0 && card.unlockedAt == 0;
    }

    /// @inheritdoc IHongBaoNFTPool
    function isExpired(address unlockAddress) external view returns (bool) {
        Card storage card = _cards[unlockAddress];
        return card.expire != 0 && card.unlockedAt == 0 && block.timestamp >= card.expire;
    }

    /// @inheritdoc IHongBaoNFTPool
    function remainingLockTime(address unlockAddress) external view returns (uint256) {
        Card storage card = _cards[unlockAddress];
        if (card.expire == 0 || card.unlockedAt != 0 || block.timestamp >= card.expire) return 0;
        return card.expire - block.timestamp;
    }

    /// @inheritdoc IHongBaoNFTPool
    function getWithdrawDigest(address unlockAddress, address to) external view returns (bytes32) {
        return _getDigest(unlockAddress, to);
    }

    // ============================================================
    //                          INTERNAL
    // ============================================================

    function _getDigest(address unlockAddress, address to) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(WITHDRAW_TYPEHASH, unlockAddress, to));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _verifySignature(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s) internal view {
        bytes32 digest = _getDigest(unlockAddress, to);
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != unlockAddress) revert InvalidSignature();
    }
}
