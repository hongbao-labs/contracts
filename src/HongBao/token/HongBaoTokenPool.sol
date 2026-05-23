// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../shared/interfaces/IERC20.sol";
import {IHongBaoTokenPool} from "./interfaces/IHongBaoTokenPool.sol";
import {SafeERC20} from "../shared/libraries/SafeERC20.sol";
import {ReentrancyGuard} from "../shared/utils/ReentrancyGuard.sol";

/// @title HongBaoTokenPool
/// @notice Single-ERC20 redeemable lock pool supporting two card flavors:
///
///         **Plain card** — `taskCount == 0`. Created by `deposit` /
///         `batchDeposit`. A one-shot EIP-712 `Withdraw(unlockAddress, to)`
///         device signature releases the full balance to `to`. Existing
///         integrations are unaffected.
///
///         **Task card** — `taskCount > 0`. Created by `depositWithTasks`,
///         restricted-mode pools only. The signature is repurposed as a
///         *binding of the recipient*: it releases the card's `basicAmount`
///         (which may be zero) and immutably records `boundTo = to`. Each
///         bonus task is then claimed by anyone presenting its preimage; the
///         contract forces the payout to the previously bound `to`, so
///         leaking a preimage to a third party is non-fatal as long as the
///         binding has already happened to a trusted recipient. Task hashes
///         are bound to `(chainid, pool, unlockAddress, taskIdx)` so a
///         preimage cannot be reused across chains, pools, cards, or slots.
///
///         TRUST ASSUMPTION — `lockedToken` MUST be a standard fixed-supply
///         ERC20 with no transfer-side surprises. Specifically:
///
///           * No fee-on-transfer: the pool credits the full deposit amount
///             on `safeTransferFrom`. A token that takes a fee on transfer
///             leaves the pool undercollateralized and later withdraws /
///             claims will revert.
///           * No rebasing or elastic supply: the pool's accounting assumes
///             `balanceOf(this)` only changes via its own transfers. Tokens
///             that mutate balances out-of-band break this.
///           * No transfer callbacks on the recipient (ERC777-style
///             `tokensReceived`, ERC1363-style `onTransferReceived`, etc.):
///             a malicious `to` could grief `batchWithdraw` /
///             `batchClaimTask` by reverting in the callback, since those
///             paths do not try/catch the individual transfers. Standard
///             ERC20 (USDC, DAI, plain ERC20s) have no such callbacks and
///             are safe.
///           * Admin blacklist behavior is opt-in: stablecoins like USDC /
///             USDT may freeze a `boundTo` after binding, in which case the
///             card's `claimTask` calls will revert until expiry; the
///             initiator can then reclaim via `withdrawExpired`. Funds are
///             not lost, but the user may need a recovery path off-chain.
///
///         Deployers MUST vet `lockedToken` against this list. The factory
///         does not.
///
///         No owner, no pause, no upgradability, no fees.
contract HongBaoTokenPool is IHongBaoTokenPool, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    //                          CONSTANTS
    // ============================================================

    /// @inheritdoc IHongBaoTokenPool
    uint256 public constant MIN_LOCK_TIME = 30 days;

    /// @inheritdoc IHongBaoTokenPool
    uint8 public constant MAX_TASKS_PER_CARD = 255;

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
        uint256 totalAmount;  // remaining balance (basic unclaimed + sum of unclaimed task amounts)
        uint256 expire;       // immutable expiration timestamp
        uint256 unlockedAt;   // plain: redeem time / reclaim time. task: device-signature time.
        uint256 basicAmount;  // amount released on the next device-signature withdraw
        address boundTo;      // task only: recipient bound by withdraw
        uint8 taskCount;      // 0 = plain card; 1..255 = task card
        bool closed;          // task only: true after initiator reclaim
    }

    struct Task {
        bytes32 hash;
        uint256 amount;
        uint256 claimedAt; // 0 = unclaimed
    }

    mapping(address => Card) internal _cards;
    mapping(address => mapping(address => uint256)) public depositRecord;

    // Flat task store, keyed by keccak256(abi.encode(unlockAddress, taskIdx)).
    mapping(bytes32 => Task) internal _tasks;

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
    //                          DEPOSIT (plain / topup)
    // ============================================================

    /// @inheritdoc IHongBaoTokenPool
    function deposit(address unlockAddress, uint256 amount, uint256 lockTime) external nonReentrant {
        _deposit(unlockAddress, amount, lockTime);
    }

    /// @inheritdoc IHongBaoTokenPool
    function batchDeposit(address[] calldata unlockAddresses, uint256 amount, uint256 lockTime) external nonReentrant {
        uint256 len = unlockAddresses.length;
        if (len == 0) revert EmptyArray();
        for (uint256 i = 0; i < len;) {
            _deposit(unlockAddresses[i], amount, lockTime);
            unchecked {
                ++i;
            }
        }
    }

    function _deposit(address unlockAddress, uint256 amount, uint256 lockTime) internal {
        if (initiator != address(0) && msg.sender != initiator) revert NotInitiator(msg.sender);
        if (unlockAddress == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        Card storage card = _cards[unlockAddress];
        if (card.unlockedAt != 0) revert AlreadyUnlocked(unlockAddress);
        if (card.closed) revert CardClosed(unlockAddress);

        uint256 expire;
        if (card.totalAmount == 0 && card.expire == 0) {
            // Fresh plain card.
            if (lockTime < MIN_LOCK_TIME) revert LockTimeTooShort(lockTime, MIN_LOCK_TIME);
            expire = block.timestamp + lockTime;
            card.expire = expire;
            // taskCount defaults to 0; basicAmount tracked implicitly via totalAmount for plain cards.
        } else {
            expire = card.expire;
            if (block.timestamp >= expire) revert CardExpired(unlockAddress);
        }

        uint256 newTotal = card.totalAmount + amount;
        card.totalAmount = newTotal;
        // Task card: top-ups extend the basic portion only (task slot amounts are immutable).
        // Plain card: keep basicAmount in sync with totalAmount for symmetry with the task path.
        card.basicAmount += amount;
        depositRecord[unlockAddress][msg.sender] += amount;

        IERC20(lockedToken).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, unlockAddress, amount, newTotal, expire);
    }

    // ============================================================
    //                      DEPOSIT (task card creation)
    // ============================================================

    /// @inheritdoc IHongBaoTokenPool
    function depositWithTasks(
        address unlockAddress,
        uint256 basicAmount,
        bytes32[] calldata taskHashes,
        uint256[] calldata taskAmounts,
        uint256 lockTime
    ) external nonReentrant {
        if (initiator == address(0)) revert OpenModeNotSupported();
        if (msg.sender != initiator) revert NotInitiator(msg.sender);
        if (lockTime < MIN_LOCK_TIME) revert LockTimeTooShort(lockTime, MIN_LOCK_TIME);

        uint256 expire = block.timestamp + lockTime;
        uint256 total = _depositWithTasks(unlockAddress, basicAmount, taskHashes, taskAmounts, expire);

        IERC20(lockedToken).safeTransferFrom(msg.sender, address(this), total);
    }

    /// @inheritdoc IHongBaoTokenPool
    function batchDepositWithTasks(
        address[] calldata unlockAddresses,
        uint256[] calldata basicAmounts,
        bytes32[][] calldata taskHashes,
        uint256[][] calldata taskAmounts,
        uint256 lockTime
    ) external nonReentrant {
        if (initiator == address(0)) revert OpenModeNotSupported();
        if (msg.sender != initiator) revert NotInitiator(msg.sender);
        if (lockTime < MIN_LOCK_TIME) revert LockTimeTooShort(lockTime, MIN_LOCK_TIME);

        uint256 len = unlockAddresses.length;
        if (len == 0) revert EmptyArray();
        if (basicAmounts.length != len || taskHashes.length != len || taskAmounts.length != len) {
            revert ArrayLengthMismatch();
        }

        uint256 expire = block.timestamp + lockTime;
        uint256 grandTotal = 0;
        for (uint256 i = 0; i < len;) {
            grandTotal += _depositWithTasks(unlockAddresses[i], basicAmounts[i], taskHashes[i], taskAmounts[i], expire);
            unchecked {
                ++i;
            }
        }

        IERC20(lockedToken).safeTransferFrom(msg.sender, address(this), grandTotal);
    }

    /// @dev State-mutation core of `depositWithTasks`. Caller must enforce
    ///      initiator / lockTime / reentrancy and execute the resulting
    ///      ERC20 transfer in a single call covering the returned total
    ///      (so batch mode can transfer once for the whole grand total).
    function _depositWithTasks(
        address unlockAddress,
        uint256 basicAmount,
        bytes32[] calldata taskHashes,
        uint256[] calldata taskAmounts,
        uint256 expire
    ) internal returns (uint256 total) {
        if (unlockAddress == address(0)) revert ZeroAddress();

        uint256 n = taskHashes.length;
        if (n != taskAmounts.length) revert TaskArrayMismatch();
        if (n == 0) revert EmptyTaskArray();
        if (n > MAX_TASKS_PER_CARD) revert TooManyTasks(n);

        Card storage card = _cards[unlockAddress];
        if (card.expire != 0 || card.unlockedAt != 0 || card.closed) revert CardExists(unlockAddress);

        uint256 totalTaskAmount = 0;
        for (uint256 i = 0; i < n;) {
            uint256 amt = taskAmounts[i];
            if (amt == 0) revert ZeroAmount();
            totalTaskAmount += amt;
            Task storage t = _tasks[_taskKey(unlockAddress, uint8(i))];
            t.hash = taskHashes[i];
            t.amount = amt;
            emit TaskDeposited(unlockAddress, uint8(i), amt, taskHashes[i]);
            unchecked {
                ++i;
            }
        }

        total = basicAmount + totalTaskAmount;
        if (total == 0) revert ZeroAmount();

        card.totalAmount = total;
        card.expire = expire;
        card.basicAmount = basicAmount;
        card.taskCount = uint8(n);
        // unlockedAt = 0, boundTo = 0, closed = false (defaults).

        depositRecord[unlockAddress][msg.sender] = total;

        emit Deposited(msg.sender, unlockAddress, total, total, expire);
    }

    // ============================================================
    //                  WITHDRAW (DEVICE SIGNATURE)
    // ============================================================

    /// @inheritdoc IHongBaoTokenPool
    function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        Card storage card = _cards[unlockAddress];
        if (card.unlockedAt != 0) revert AlreadyUnlocked(unlockAddress);
        if (card.closed) revert CardClosed(unlockAddress);
        if (card.totalAmount == 0) revert NoDeposit(unlockAddress);

        _verifySignature(unlockAddress, to, v, r, s);

        _doWithdraw(card, unlockAddress, to);
    }

    /// @inheritdoc IHongBaoTokenPool
    function batchWithdraw(
        address[] calldata unlockAddresses,
        address[] calldata tos,
        uint8[] calldata vs,
        bytes32[] calldata rs,
        bytes32[] calldata ss
    ) external nonReentrant {
        uint256 len = unlockAddresses.length;
        if (len == 0) revert EmptyArray();
        if (tos.length != len || vs.length != len || rs.length != len || ss.length != len) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < len;) {
            _tryWithdraw(unlockAddresses[i], tos[i], vs[i], rs[i], ss[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Soft-fail variant of `withdraw`. Returns without state changes if
    ///      any precondition would have caused the single-entry path to revert.
    function _tryWithdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s) internal {
        if (to == address(0)) return;
        // High-S signatures (non-canonical form) are rejected here as in
        // `_verifySignature`, to keep batch and single-entry paths consistent.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return;
        Card storage card = _cards[unlockAddress];
        if (card.unlockedAt != 0 || card.closed || card.totalAmount == 0) return;
        if (ecrecover(_getDigest(unlockAddress, to), v, r, s) != unlockAddress) return;

        _doWithdraw(card, unlockAddress, to);
    }

    /// @dev State-mutation core of `withdraw`. Caller has already validated
    ///      `to`, card state, and signature.
    function _doWithdraw(Card storage card, address unlockAddress, address to) internal {
        card.unlockedAt = block.timestamp;

        uint256 release = card.basicAmount;
        card.basicAmount = 0;
        card.totalAmount -= release;

        if (card.taskCount != 0) {
            card.boundTo = to;
        }

        emit Withdrawn(unlockAddress, to, release);

        if (release != 0) {
            IERC20(lockedToken).safeTransfer(to, release);
        }
    }

    // ============================================================
    //                          CLAIM TASK
    // ============================================================

    /// @inheritdoc IHongBaoTokenPool
    function claimTask(address unlockAddress, uint8 taskIdx, bytes calldata n) external nonReentrant {
        Card storage card = _cards[unlockAddress];
        if (card.taskCount == 0) revert NotTaskCard(unlockAddress);
        if (taskIdx >= card.taskCount) revert InvalidTaskIndex(taskIdx, card.taskCount);
        if (card.closed) revert CardClosed(unlockAddress);
        if (card.unlockedAt == 0) revert BasicNotCompleted(unlockAddress);

        Task storage t = _tasks[_taskKey(unlockAddress, taskIdx)];
        if (t.claimedAt != 0) revert TaskAlreadyClaimed(unlockAddress, taskIdx);

        bytes32 expected = keccak256(abi.encode(block.chainid, address(this), unlockAddress, taskIdx, n));
        if (expected != t.hash) revert InvalidPreimage();

        _doClaimTask(card, t, unlockAddress, taskIdx);
    }

    /// @inheritdoc IHongBaoTokenPool
    function batchClaimTask(
        address[] calldata unlockAddresses,
        uint8[] calldata taskIdxs,
        bytes[] calldata preimages
    ) external nonReentrant {
        uint256 len = unlockAddresses.length;
        if (len == 0) revert EmptyArray();
        if (taskIdxs.length != len || preimages.length != len) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < len;) {
            _tryClaimTask(unlockAddresses[i], taskIdxs[i], preimages[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Soft-fail variant of `claimTask`. Returns without state changes if
    ///      any precondition would have caused the single-entry path to revert.
    function _tryClaimTask(address unlockAddress, uint8 taskIdx, bytes calldata n) internal {
        Card storage card = _cards[unlockAddress];
        if (card.taskCount == 0) return;
        if (taskIdx >= card.taskCount) return;
        if (card.closed) return;
        if (card.unlockedAt == 0) return;

        Task storage t = _tasks[_taskKey(unlockAddress, taskIdx)];
        if (t.claimedAt != 0) return;

        bytes32 expected = keccak256(abi.encode(block.chainid, address(this), unlockAddress, taskIdx, n));
        if (expected != t.hash) return;

        _doClaimTask(card, t, unlockAddress, taskIdx);
    }

    /// @dev State-mutation core of `claimTask`. Caller has already validated
    ///      card state, slot freshness, and preimage.
    function _doClaimTask(Card storage card, Task storage t, address unlockAddress, uint8 taskIdx) internal {
        uint256 amount = t.amount;
        address to = card.boundTo;

        t.claimedAt = block.timestamp;
        card.totalAmount -= amount;
        // Track initiator's outstanding share so accounting stays consistent
        // even though task-card expiry reclaim doesn't actually read this.
        uint256 outstanding = depositRecord[unlockAddress][initiator];
        depositRecord[unlockAddress][initiator] = outstanding > amount ? outstanding - amount : 0;

        emit TaskClaimed(unlockAddress, taskIdx, to, amount);

        IERC20(lockedToken).safeTransfer(to, amount);
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

        address _token = lockedToken;

        for (uint256 i = 0; i < len;) {
            address addr = unlockAddresses[i];
            Card storage card = _cards[addr];

            if (card.expire == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }
            if (block.timestamp < card.expire) revert NotExpired(addr, card.expire);

            if (card.taskCount == 0) {
                // Plain card path.
                if (card.unlockedAt != 0) {
                    unchecked {
                        ++i;
                    }
                    continue;
                }
                uint256 share = depositRecord[addr][msg.sender];
                if (share == 0) {
                    unchecked {
                        ++i;
                    }
                    continue;
                }

                depositRecord[addr][msg.sender] = 0;
                card.totalAmount -= share;
                card.basicAmount -= share;

                IERC20(_token).safeTransfer(msg.sender, share);
                emit WithdrawnExpired(msg.sender, addr, share);
            } else {
                // Task card path: only initiator may reclaim; skip if already closed.
                if (card.closed) {
                    unchecked {
                        ++i;
                    }
                    continue;
                }
                if (msg.sender != initiator) revert NotInitiator(msg.sender);

                uint256 remaining = card.totalAmount;
                if (remaining == 0) {
                    card.closed = true;
                    unchecked {
                        ++i;
                    }
                    continue;
                }

                _closeTaskCard(card, addr, remaining, _token);
            }

            unchecked {
                ++i;
            }
        }
    }

    function _withdrawExpired(address unlockAddress) internal {
        Card storage card = _cards[unlockAddress];
        if (card.expire == 0) revert NoDeposit(unlockAddress);
        if (block.timestamp < card.expire) revert NotExpired(unlockAddress, card.expire);

        if (card.taskCount == 0) {
            // Plain card: per-depositor share reclaim.
            if (card.unlockedAt != 0) revert AlreadyUnlocked(unlockAddress);
            uint256 share = depositRecord[unlockAddress][msg.sender];
            if (share == 0) revert NoShare(unlockAddress, msg.sender);

            depositRecord[unlockAddress][msg.sender] = 0;
            card.totalAmount -= share;
            card.basicAmount -= share;

            IERC20(lockedToken).safeTransfer(msg.sender, share);
            emit WithdrawnExpired(msg.sender, unlockAddress, share);
        } else {
            // Task card: initiator reclaims everything remaining and closes the card.
            if (card.closed) revert CardClosed(unlockAddress);
            if (msg.sender != initiator) revert NotInitiator(msg.sender);

            uint256 remaining = card.totalAmount;
            _closeTaskCard(card, unlockAddress, remaining, lockedToken);
        }
    }

    function _closeTaskCard(Card storage card, address unlockAddress, uint256 remaining, address token) internal {
        card.closed = true;
        card.totalAmount = 0;
        card.basicAmount = 0;
        depositRecord[unlockAddress][initiator] = 0;

        if (remaining != 0) {
            IERC20(token).safeTransfer(initiator, remaining);
        }
        emit WithdrawnExpired(initiator, unlockAddress, remaining);
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
    function cardBasicAmount(address unlockAddress) external view returns (uint256) {
        return _cards[unlockAddress].basicAmount;
    }

    /// @inheritdoc IHongBaoTokenPool
    function cardTaskCount(address unlockAddress) external view returns (uint8) {
        return _cards[unlockAddress].taskCount;
    }

    /// @inheritdoc IHongBaoTokenPool
    function cardBoundTo(address unlockAddress) external view returns (address) {
        return _cards[unlockAddress].boundTo;
    }

    /// @inheritdoc IHongBaoTokenPool
    function cardClosed(address unlockAddress) external view returns (bool) {
        return _cards[unlockAddress].closed;
    }

    /// @inheritdoc IHongBaoTokenPool
    function isLocked(address unlockAddress) external view returns (bool) {
        Card storage card = _cards[unlockAddress];
        if (card.totalAmount == 0 || card.closed) return false;
        if (card.taskCount == 0) return card.unlockedAt == 0;
        return true; // task card with remaining balance and not closed
    }

    /// @inheritdoc IHongBaoTokenPool
    function isExpired(address unlockAddress) external view returns (bool) {
        Card storage card = _cards[unlockAddress];
        if (card.totalAmount == 0 || card.closed) return false;
        if (card.taskCount == 0 && card.unlockedAt != 0) return false;
        return block.timestamp >= card.expire;
    }

    /// @inheritdoc IHongBaoTokenPool
    function remainingLockTime(address unlockAddress) external view returns (uint256) {
        Card storage card = _cards[unlockAddress];
        if (card.totalAmount == 0 || card.closed) return 0;
        if (card.taskCount == 0 && card.unlockedAt != 0) return 0;
        if (block.timestamp >= card.expire) return 0;
        return card.expire - block.timestamp;
    }

    /// @inheritdoc IHongBaoTokenPool
    function getWithdrawDigest(address unlockAddress, address to) external view returns (bytes32) {
        return _getDigest(unlockAddress, to);
    }

    /// @inheritdoc IHongBaoTokenPool
    function task(address unlockAddress, uint8 taskIdx)
        external
        view
        returns (bytes32 hash, uint256 amount, uint256 claimedAt)
    {
        Task storage t = _tasks[_taskKey(unlockAddress, taskIdx)];
        return (t.hash, t.amount, t.claimedAt);
    }

    /// @inheritdoc IHongBaoTokenPool
    function taskKey(address unlockAddress, uint8 taskIdx) external pure returns (bytes32) {
        return _taskKey(unlockAddress, taskIdx);
    }

    /// @inheritdoc IHongBaoTokenPool
    function computeTaskHash(address unlockAddress, uint8 taskIdx, bytes calldata n)
        external
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), unlockAddress, taskIdx, n));
    }

    // ============================================================
    //                          INTERNAL
    // ============================================================

    function _taskKey(address unlockAddress, uint8 taskIdx) internal pure returns (bytes32) {
        return keccak256(abi.encode(unlockAddress, taskIdx));
    }

    function _getDigest(address unlockAddress, address to) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(WITHDRAW_TYPEHASH, unlockAddress, to));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _verifySignature(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s) internal view {
        // Reject high-S signatures (EIP-2 / OZ ECDSA canonical form). `ecrecover`
        // accepts both `s` and `n - s`, which yields two distinct (v, r, s)
        // triples for the same signer/message; rejecting the upper half makes
        // the on-chain signature canonical.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignature();
        }
        bytes32 digest = _getDigest(unlockAddress, to);
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != unlockAddress) revert InvalidSignature();
    }
}
