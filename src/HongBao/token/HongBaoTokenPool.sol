// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../shared/interfaces/IERC20.sol";
import {IHongBaoTokenPool} from "./interfaces/IHongBaoTokenPool.sol";
import {SafeERC20} from "../shared/libraries/SafeERC20.sol";
import {ReentrancyGuard} from "../shared/utils/ReentrancyGuard.sol";

/// @title HongBaoTokenPool
/// @notice One-shot signature redeemable lock pool for a single ERC20 token.
///
/// @dev    One pool instance binds exactly one ERC20 token. Each "card" is an
///         EVM address derived from a single-use private key held by a hardware
///         device. A deposit locks funds against the card's address. The device
///         may produce at most one EIP-712 `Withdraw(unlockAddress, to)`
///         signature over its lifetime; presenting that signature redeems the
///         card's entire balance to `to`.
///
///         Depositor semantics:
///         - If `initiator != address(0)`, only `initiator` may deposit.
///         - If `initiator == address(0)`, anyone may deposit. Multiple
///           depositors may top up the same card; on redemption the full
///           balance is paid out. If the card expires unredeemed, each
///           depositor reclaims their own contribution via `withdrawExpired`.
///
///         This contract holds no administrative privileges: no owner, no
///         pause, no upgradability, no fees.
contract HongBaoTokenPool is IHongBaoTokenPool, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    //                          CONSTANTS
    // ============================================================

    /// @inheritdoc IHongBaoTokenPool
    uint256 public constant MIN_LOCK_TIME = 30 days;

    /// @inheritdoc IHongBaoTokenPool
    bytes32 public constant WITHDRAW_TYPEHASH = keccak256("Withdraw(address unlockAddress,address to)");

    // ============================================================
    //                         IMMUTABLES
    // ============================================================

    /// @inheritdoc IHongBaoTokenPool
    address public immutable lockedToken;

    /// @inheritdoc IHongBaoTokenPool
    address public immutable initiator;

    /// @inheritdoc IHongBaoTokenPool
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ============================================================
    //                          STORAGE
    // ============================================================

    struct Card {
        uint256 totalAmount;
        uint256 expire;
        uint256 unlockedAt;
    }

    mapping(address => Card) internal _cards;
    mapping(address => mapping(address => uint256)) public depositRecord;

    // ============================================================
    //                        CONSTRUCTOR
    // ============================================================

    /// @param _token     The ERC20 token this pool locks. Must be non-zero.
    /// @param _initiator Sole depositor address; pass `address(0)` for open pools.
    constructor(address _token, address _initiator) {
        if (_token == address(0)) revert ZeroAddress();
        lockedToken = _token;
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
    //                          DEPOSIT
    // ============================================================

    /// @inheritdoc IHongBaoTokenPool
    function deposit(address unlockAddress, uint256 amount, uint256 lockTime) external nonReentrant {
        _deposit(unlockAddress, amount, lockTime);
    }

    /// @inheritdoc IHongBaoTokenPool
    function batchDeposit(address[] calldata unlockAddresses, uint256 amount, uint256 lockTime) external nonReentrant {
        uint256 len = unlockAddresses.length;
        if (len == 0) revert EmptyArray();
        for (uint256 i = 0; i < len; i++) {
            _deposit(unlockAddresses[i], amount, lockTime);
        }
    }

    function _deposit(address unlockAddress, uint256 amount, uint256 lockTime) internal {
        if (initiator != address(0) && msg.sender != initiator) revert NotInitiator(msg.sender);
        if (unlockAddress == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        Card storage card = _cards[unlockAddress];
        if (card.unlockedAt != 0) revert AlreadyUnlocked(unlockAddress);

        uint256 expire;
        if (card.totalAmount == 0) {
            if (lockTime < MIN_LOCK_TIME) revert LockTimeTooShort(lockTime, MIN_LOCK_TIME);
            expire = block.timestamp + lockTime;
            card.expire = expire;
        } else {
            expire = card.expire;
            if (block.timestamp >= expire) revert CardExpired(unlockAddress);
        }

        uint256 newTotal = card.totalAmount + amount;
        card.totalAmount = newTotal;
        depositRecord[unlockAddress][msg.sender] += amount;

        IERC20(lockedToken).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, unlockAddress, amount, newTotal, expire);
    }

    // ============================================================
    //                  WITHDRAW (DEVICE SIGNATURE)
    // ============================================================

    /// @inheritdoc IHongBaoTokenPool
    function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        Card storage card = _cards[unlockAddress];
        if (card.unlockedAt != 0) revert AlreadyUnlocked(unlockAddress);
        uint256 amount = card.totalAmount;
        if (amount == 0) revert NoDeposit(unlockAddress);

        _verifySignature(unlockAddress, to, v, r, s);

        card.unlockedAt = block.timestamp;
        card.totalAmount = 0;

        IERC20(lockedToken).safeTransfer(to, amount);

        emit Withdrawn(unlockAddress, to, amount);
    }

    // ============================================================
    //                      WITHDRAW EXPIRED
    // ============================================================

    /// @inheritdoc IHongBaoTokenPool
    function withdrawExpired(address unlockAddress) external nonReentrant {
        _withdrawExpired(unlockAddress);
    }

    /// @inheritdoc IHongBaoTokenPool
    function batchWithdrawExpired(address[] calldata unlockAddresses) external nonReentrant {
        uint256 len = unlockAddresses.length;
        if (len == 0) revert EmptyArray();
        for (uint256 i = 0; i < len; i++) {
            address addr = unlockAddresses[i];
            Card storage card = _cards[addr];

            // Skip entries that have already been redeemed via signature, and
            // entries on which the caller has nothing to claim.
            if (card.unlockedAt != 0) continue;
            uint256 share = depositRecord[addr][msg.sender];
            if (share == 0) continue;

            if (block.timestamp < card.expire) revert NotExpired(addr, card.expire);

            depositRecord[addr][msg.sender] = 0;
            card.totalAmount -= share;

            IERC20(lockedToken).safeTransfer(msg.sender, share);

            emit WithdrawnExpired(msg.sender, addr, share);
        }
    }

    function _withdrawExpired(address unlockAddress) internal {
        Card storage card = _cards[unlockAddress];
        if (card.unlockedAt != 0) revert AlreadyUnlocked(unlockAddress);
        if (card.expire == 0) revert NoDeposit(unlockAddress);
        if (block.timestamp < card.expire) revert NotExpired(unlockAddress, card.expire);

        uint256 share = depositRecord[unlockAddress][msg.sender];
        if (share == 0) revert NoShare(unlockAddress, msg.sender);

        depositRecord[unlockAddress][msg.sender] = 0;
        card.totalAmount -= share;

        IERC20(lockedToken).safeTransfer(msg.sender, share);

        emit WithdrawnExpired(msg.sender, unlockAddress, share);
    }

    // ============================================================
    //                            VIEWS
    // ============================================================

    /// @inheritdoc IHongBaoTokenPool
    function cardTotal(address unlockAddress) external view returns (uint256) {
        return _cards[unlockAddress].totalAmount;
    }

    /// @inheritdoc IHongBaoTokenPool
    function cardExpire(address unlockAddress) external view returns (uint256) {
        return _cards[unlockAddress].expire;
    }

    /// @inheritdoc IHongBaoTokenPool
    function cardUnlockedAt(address unlockAddress) external view returns (uint256) {
        return _cards[unlockAddress].unlockedAt;
    }

    /// @inheritdoc IHongBaoTokenPool
    function isLocked(address unlockAddress) external view returns (bool) {
        Card storage card = _cards[unlockAddress];
        return card.totalAmount > 0 && card.unlockedAt == 0;
    }

    /// @inheritdoc IHongBaoTokenPool
    function isExpired(address unlockAddress) external view returns (bool) {
        Card storage card = _cards[unlockAddress];
        return card.totalAmount > 0 && card.unlockedAt == 0 && block.timestamp >= card.expire;
    }

    /// @inheritdoc IHongBaoTokenPool
    function remainingLockTime(address unlockAddress) external view returns (uint256) {
        Card storage card = _cards[unlockAddress];
        if (card.totalAmount == 0 || card.unlockedAt != 0 || block.timestamp >= card.expire) return 0;
        return card.expire - block.timestamp;
    }

    /// @inheritdoc IHongBaoTokenPool
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
