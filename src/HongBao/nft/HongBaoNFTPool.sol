// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721} from "../shared/interfaces/IERC721.sol";
import {IERC721Receiver} from "../shared/interfaces/IERC721Receiver.sol";
import {IHongBaoNFTPool} from "./interfaces/IHongBaoNFTPool.sol";
import {ReentrancyGuard} from "../shared/utils/ReentrancyGuard.sol";

/// @title HongBaoNFTPool
/// @notice Single-collection redeemable lock pool for ERC721 with two card flavors:
///
///         **Plain card** — `taskCount == 0`. Created by `deposit` (pull) or
///         `onERC721Received` (push). Holds exactly one tokenId. A one-shot
///         EIP-712 `Withdraw(unlockAddress, to)` device signature transfers
///         the NFT to `to`. Backwards-compatible with the original NFT pool.
///
///         **Task card** — `taskCount > 0`. Created by `depositWithTasks`
///         (pull-only, atomic). Holds an optional "basic" NFT released on the
///         binding signature, plus 1..255 immutable preimage-gated task slots
///         each holding one NFT. The signature is repurposed as a *binding of
///         the recipient*: it releases the basic NFT (if any) and immutably
///         records `boundTo = to`. Each bonus task is then claimed by anyone
///         presenting its preimage; the contract forces the NFT to the
///         previously bound `to`. Task hashes are bound to
///         `(chainid, pool, unlockAddress, taskIdx)` so a preimage cannot be
///         reused across chains, pools, cards, or slots.
///
///         Two deposit paths for plain cards (semantically identical):
///           - Pull: initiator approves the pool and calls `deposit(...)`.
///           - Push: initiator calls `lockedCollection.safeTransferFrom(
///                   initiator, pool, tokenId, abi.encode(unlockAddress, lockTime))`.
///         Task cards are pull-only — push (`onERC721Received`) creates plain
///         cards only.
///
///         IMPORTANT: `withdraw` / `claimTask` / `withdrawExpired` use
///         `safeTransferFrom`. If the destination is a contract that does not
///         implement `IERC721Receiver`, the transfer reverts. Single-shot
///         entry points propagate the revert (caller must address). Batch
///         entry points wrap each individual transfer in try/catch and emit
///         `BatchTransferFailed`, leaving card state for retry. Because the
///         hardware device's signature for a task card is one-shot, binding
///         `boundTo` to a non-receiver contract permanently bricks each task
///         slot's NFT (basic NFT is bricked too on the binding tx — clients
///         MUST validate `to` before asking the device to sign).
///
///         TRUST ASSUMPTION: `lockedCollection` MUST follow the ERC721
///         standard faithfully. A malicious or upgradeable collection can
///         register phantom cards (no NFT held) and permanently brick
///         `unlockAddress` slots, since cards are one-shot. Deployers MUST
///         vet the collection — preferably non-upgradeable. Not enforced
///         by the factory.
///
///         APPROVAL HYGIENE: the push-path entry (`onERC721Received`) only
///         checks `from == initiator`. Per ERC721 semantics, that `from` is
///         supplied by the collection, and any account holding an active
///         operator approval from the initiator (e.g. via
///         `setApprovalForAll(operator, true)` on the collection) can move
///         the initiator's NFT into this pool with arbitrary
///         `(unlockAddress, lockTime)` data — effectively letting that
///         operator mint cards on the initiator's behalf, and potentially
///         to an `unlockAddress` whose device key the operator controls.
///         The initiator MUST keep collection-level approvals tight:
///         approve only this pool (or a dedicated relayer with equivalent
///         trust), never blanket-approve unfamiliar contracts. With task
///         cards, the blast radius multiplies — a single rogue
///         `batchDepositWithTasks`-equivalent transfer chain can lock up
///         several NFTs at once.
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
    uint8 public constant MAX_TASKS_PER_CARD = 255;

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
        uint256 tokenId;     // plain card: THE NFT; task card with hasBasic: basic NFT
        uint256 expire;      // existence sentinel (set on any deposit; tokenId 0 is valid)
        uint256 unlockedAt;  // plain: redeem/reclaim time. task: binding-signature time.
        address boundTo;     // task only: recipient bound by withdraw
        uint8 taskCount;     // 0 = plain card; 1..255 = task card
        bool hasBasic;       // task only: whether tokenId holds a basic NFT
        bool closed;         // task only: true after initiator reclaim
    }

    struct Task {
        bytes32 hash;
        uint256 tokenId;
        uint256 claimedAt; // 0 = unclaimed (also serves as the reclaim sentinel on close)
    }

    mapping(address => Card) internal _cards;

    // Flat task store, keyed by keccak256(abi.encode(unlockAddress, taskIdx)).
    mapping(bytes32 => Task) internal _tasks;

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
    //                  DEPOSIT — PLAIN CARD (PULL / PUSH)
    // ============================================================

    /// @inheritdoc IHongBaoNFTPool
    function deposit(address unlockAddress, uint256 tokenId, uint256 lockTime) external nonReentrant {
        if (msg.sender != initiator) revert NotInitiator(msg.sender);

        _registerPlainDeposit(msg.sender, unlockAddress, tokenId, lockTime);

        // Plain `transferFrom` rather than `safeTransferFrom`: we are already
        // executing inside `deposit` and must not re-enter `onERC721Received`.
        IERC721(lockedCollection).transferFrom(msg.sender, address(this), tokenId);
    }

    /// @notice ERC721 receiver hook used as the push-style deposit entry point
    ///         for **plain cards only**. Task cards are pull-only.
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
    )
        external
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != lockedCollection) revert WrongCollection(msg.sender);
        if (from != initiator) revert NotInitiator(from);
        // abi.encode(address, uint256) is exactly 64 bytes.
        if (data.length != 64) revert MalformedData();

        (address unlockAddress, uint256 lockTime) = abi.decode(data, (address, uint256));
        _registerPlainDeposit(from, unlockAddress, tokenId, lockTime);

        return IERC721Receiver.onERC721Received.selector;
    }

    function _registerPlainDeposit(address depositor, address unlockAddress, uint256 tokenId, uint256 lockTime)
        internal
    {
        if (unlockAddress == address(0)) revert ZeroAddress();
        if (lockTime < MIN_LOCK_TIME) revert LockTimeTooShort(lockTime, MIN_LOCK_TIME);

        Card storage card = _cards[unlockAddress];
        // A card is one-shot: any prior deposit (active, expired, or already
        // released) locks the `unlockAddress` forever on this pool.
        if (card.expire != 0) revert CardExists(unlockAddress);

        uint256 expire = block.timestamp + lockTime;
        card.tokenId = tokenId;
        card.expire = expire;
        // taskCount = 0, hasBasic = false, closed = false (defaults).

        emit Deposited(depositor, unlockAddress, tokenId, expire);
    }

    // ============================================================
    //                  DEPOSIT — TASK CARD (PULL-ONLY)
    // ============================================================

    /// @inheritdoc IHongBaoNFTPool
    function depositWithTasks(
        address unlockAddress,
        bool hasBasic,
        uint256 basicTokenId,
        bytes32[] calldata taskHashes,
        uint256[] calldata taskTokenIds,
        uint256 lockTime
    ) external nonReentrant {
        if (msg.sender != initiator) revert NotInitiator(msg.sender);
        if (lockTime < MIN_LOCK_TIME) revert LockTimeTooShort(lockTime, MIN_LOCK_TIME);

        uint256 expire = block.timestamp + lockTime;
        _depositWithTasks(unlockAddress, hasBasic, basicTokenId, taskHashes, taskTokenIds, expire);
    }

    /// @inheritdoc IHongBaoNFTPool
    function batchDepositWithTasks(
        address[] calldata unlockAddresses,
        bool[] calldata hasBasics,
        uint256[] calldata basicTokenIds,
        bytes32[][] calldata taskHashes,
        uint256[][] calldata taskTokenIds,
        uint256 lockTime
    ) external nonReentrant {
        if (msg.sender != initiator) revert NotInitiator(msg.sender);
        if (lockTime < MIN_LOCK_TIME) revert LockTimeTooShort(lockTime, MIN_LOCK_TIME);

        uint256 len = unlockAddresses.length;
        if (len == 0) revert EmptyArray();
        if (
            hasBasics.length != len || basicTokenIds.length != len || taskHashes.length != len
                || taskTokenIds.length != len
        ) {
            revert ArrayLengthMismatch();
        }

        uint256 expire = block.timestamp + lockTime;
        for (uint256 i = 0; i < len;) {
            _depositWithTasks(
                unlockAddresses[i], hasBasics[i], basicTokenIds[i], taskHashes[i], taskTokenIds[i], expire
            );
            unchecked {
                ++i;
            }
        }
    }

    /// @dev State-mutation + atomic-pull core. Caller enforces initiator /
    ///      lockTime / reentrancy. Pulls (basic if hasBasic) + N task NFTs;
    ///      any single transfer revert reverts the whole tx (all state rolls back).
    function _depositWithTasks(
        address unlockAddress,
        bool hasBasic,
        uint256 basicTokenId,
        bytes32[] calldata taskHashes,
        uint256[] calldata taskTokenIds,
        uint256 expire
    ) internal {
        if (unlockAddress == address(0)) revert ZeroAddress();

        uint256 n = taskHashes.length;
        if (n != taskTokenIds.length) revert TaskArrayMismatch();
        if (n == 0) revert EmptyTaskArray();
        if (n > MAX_TASKS_PER_CARD) revert TooManyTasks(n);

        Card storage card = _cards[unlockAddress];
        if (card.expire != 0 || card.unlockedAt != 0 || card.closed) revert CardExists(unlockAddress);

        // Register task slots (state writes first; transfers at end).
        for (uint256 i = 0; i < n;) {
            Task storage t = _tasks[_taskKey(unlockAddress, uint8(i))];
            t.hash = taskHashes[i];
            t.tokenId = taskTokenIds[i];
            emit TaskDeposited(unlockAddress, uint8(i), taskTokenIds[i], taskHashes[i]);
            unchecked {
                ++i;
            }
        }

        card.expire = expire;
        card.taskCount = uint8(n);
        card.hasBasic = hasBasic;
        if (hasBasic) {
            card.tokenId = basicTokenId;
        }
        // unlockedAt = 0, boundTo = 0, closed = false (defaults).

        emit Deposited(msg.sender, unlockAddress, hasBasic ? basicTokenId : 0, expire);

        // Transfers last — any revert rolls back all state above (atomic).
        address _collection = lockedCollection;
        if (hasBasic) {
            IERC721(_collection).transferFrom(msg.sender, address(this), basicTokenId);
        }
        for (uint256 i = 0; i < n;) {
            IERC721(_collection).transferFrom(msg.sender, address(this), taskTokenIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    // ============================================================
    //                  WITHDRAW (DEVICE SIGNATURE)
    // ============================================================

    /// @inheritdoc IHongBaoNFTPool
    function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        Card storage card = _cards[unlockAddress];
        if (card.unlockedAt != 0) revert AlreadyUnlocked(unlockAddress);
        if (card.closed) revert CardClosed(unlockAddress);
        if (card.expire == 0) revert NoDeposit(unlockAddress);

        _verifySignature(unlockAddress, to, v, r, s);

        _doWithdraw(card, unlockAddress, to);
    }

    /// @inheritdoc IHongBaoNFTPool
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

    /// @dev State-mutation core of `withdraw`. Caller already validated
    ///      `to`, card state, and signature. Transfer revert (e.g. non-receiver
    ///      `to`) propagates and rolls back all state in this call.
    function _doWithdraw(Card storage card, address unlockAddress, address to) internal {
        card.unlockedAt = block.timestamp;

        uint256 tokenId = 0;
        bool needsTransfer;

        if (card.taskCount == 0) {
            // Plain card: transfer the only NFT, no binding.
            tokenId = card.tokenId;
            needsTransfer = true;
        } else {
            // Task card: bind boundTo, optionally release basic NFT.
            card.boundTo = to;
            if (card.hasBasic) {
                tokenId = card.tokenId;
                card.tokenId = 0;
                card.hasBasic = false;
                needsTransfer = true;
            }
            // !hasBasic: pure binding, no NFT to transfer.
        }

        emit Withdrawn(unlockAddress, to, tokenId);

        if (needsTransfer) {
            IERC721(lockedCollection).safeTransferFrom(address(this), to, tokenId);
        }
    }

    /// @dev Soft-fail variant of `withdraw`. Returns without state changes if
    ///      any precondition would have caused the single-entry path to revert.
    ///      Wraps the NFT transfer in try/catch so a non-receiver `to` does
    ///      not poison the batch — emits `BatchTransferFailed` on per-entry
    ///      transfer revert and leaves card state untouched for retry.
    function _tryWithdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s) internal {
        if (to == address(0)) return;
        // High-S signatures (non-canonical) are rejected as in `_verifySignature`.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return;
        Card storage card = _cards[unlockAddress];
        if (card.unlockedAt != 0 || card.closed || card.expire == 0) return;
        if (ecrecover(_getDigest(unlockAddress, to), v, r, s) != unlockAddress) return;

        address _collection = lockedCollection;

        if (card.taskCount == 0) {
            // Plain card path
            uint256 tokenId = card.tokenId;
            try IERC721(_collection).safeTransferFrom(address(this), to, tokenId) {
                card.unlockedAt = block.timestamp;
                emit Withdrawn(unlockAddress, to, tokenId);
            } catch {
                emit BatchTransferFailed(unlockAddress, tokenId);
            }
        } else {
            // Task card path
            if (card.hasBasic) {
                uint256 tokenId = card.tokenId;
                try IERC721(_collection).safeTransferFrom(address(this), to, tokenId) {
                    card.unlockedAt = block.timestamp;
                    card.boundTo = to;
                    card.tokenId = 0;
                    card.hasBasic = false;
                    emit Withdrawn(unlockAddress, to, tokenId);
                } catch {
                    emit BatchTransferFailed(unlockAddress, tokenId);
                }
            } else {
                // Pure binding, no transfer — can't fail.
                card.unlockedAt = block.timestamp;
                card.boundTo = to;
                emit Withdrawn(unlockAddress, to, 0);
            }
        }
    }

    // ============================================================
    //                          CLAIM TASK
    // ============================================================

    /// @inheritdoc IHongBaoNFTPool
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

    /// @inheritdoc IHongBaoNFTPool
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
    ///      Wraps the NFT transfer in try/catch — non-receiver `boundTo`
    ///      emits `BatchTransferFailed` and leaves the slot unclaimed.
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

        uint256 tokenId = t.tokenId;
        address to = card.boundTo;
        try IERC721(lockedCollection).safeTransferFrom(address(this), to, tokenId) {
            t.claimedAt = block.timestamp;
            emit TaskClaimed(unlockAddress, taskIdx, to, tokenId);
        } catch {
            emit BatchTransferFailed(unlockAddress, tokenId);
        }
    }

    /// @dev State-mutation core of `claimTask`. Caller already validated
    ///      card state, slot freshness, and preimage. Transfer revert
    ///      propagates (atomic for single-shot call).
    function _doClaimTask(Card storage card, Task storage t, address unlockAddress, uint8 taskIdx) internal {
        uint256 tokenId = t.tokenId;
        address to = card.boundTo;

        t.claimedAt = block.timestamp;

        emit TaskClaimed(unlockAddress, taskIdx, to, tokenId);

        IERC721(lockedCollection).safeTransferFrom(address(this), to, tokenId);
    }

    // ============================================================
    //                      WITHDRAW EXPIRED
    // ============================================================

    /// @inheritdoc IHongBaoNFTPool
    function withdrawExpired(address unlockAddress) external nonReentrant {
        if (msg.sender != initiator) revert NotInitiator(msg.sender);

        Card storage card = _cards[unlockAddress];
        if (card.expire == 0) revert NoDeposit(unlockAddress);
        if (block.timestamp < card.expire) revert NotExpired(unlockAddress, card.expire);

        if (card.taskCount == 0) {
            // Plain card path: original behavior.
            if (card.unlockedAt != 0) revert AlreadyUnlocked(unlockAddress);

            uint256 tokenId = card.tokenId;
            card.unlockedAt = block.timestamp;

            IERC721(lockedCollection).safeTransferFrom(address(this), initiator, tokenId);

            emit WithdrawnExpired(initiator, unlockAddress, tokenId);
        } else {
            // Task card path: reclaim basic (if not withdrawn) + all unclaimed
            // tasks in one atomic call. Reverts on first transfer failure;
            // caller must address (e.g. via batchWithdrawExpired's try/catch).
            if (card.closed) revert CardClosed(unlockAddress);

            address _collection = lockedCollection;
            uint8 n = card.taskCount;

            if (card.hasBasic && card.unlockedAt == 0) {
                uint256 basicTokenId = card.tokenId;
                card.tokenId = 0;
                card.hasBasic = false;
                IERC721(_collection).safeTransferFrom(address(this), initiator, basicTokenId);
                emit WithdrawnExpired(initiator, unlockAddress, basicTokenId);
            }

            for (uint8 i = 0; i < n;) {
                Task storage t = _tasks[_taskKey(unlockAddress, i)];
                if (t.claimedAt == 0) {
                    uint256 taskTokenId = t.tokenId;
                    t.claimedAt = block.timestamp;
                    IERC721(_collection).safeTransferFrom(address(this), initiator, taskTokenId);
                    emit WithdrawnExpired(initiator, unlockAddress, taskTokenId);
                }
                unchecked {
                    ++i;
                }
            }

            // `closed` is the authoritative termination signal for task cards.
            // We do NOT set `unlockedAt` here — for task cards `unlockedAt`
            // means "basic binding time" (set by `_doWithdraw`); leaving it
            // at 0 when the basic was never bound preserves that semantic.
            card.closed = true;
        }
    }

    /// @inheritdoc IHongBaoNFTPool
    function batchWithdrawExpired(address[] calldata unlockAddresses) external nonReentrant {
        address _initiator = initiator;
        if (msg.sender != _initiator) revert NotInitiator(msg.sender);
        uint256 len = unlockAddresses.length;
        if (len == 0) revert EmptyArray();

        address _collection = lockedCollection;
        address _self = address(this);

        for (uint256 i = 0; i < len;) {
            address addr = unlockAddresses[i];
            Card storage card = _cards[addr];

            if (card.expire == 0) {
                emit BatchSkipped(addr);
                unchecked {
                    ++i;
                }
                continue;
            }

            // Not-yet-expired entries hard-revert so the caller notices the
            // programming error instead of silently doing nothing.
            if (block.timestamp < card.expire) revert NotExpired(addr, card.expire);

            if (card.taskCount == 0) {
                // Plain card path.
                if (card.unlockedAt != 0) {
                    emit BatchSkipped(addr);
                    unchecked {
                        ++i;
                    }
                    continue;
                }

                uint256 tokenId = card.tokenId;
                try IERC721(_collection).safeTransferFrom(_self, _initiator, tokenId) {
                    card.unlockedAt = block.timestamp;
                    emit WithdrawnExpired(_initiator, addr, tokenId);
                } catch {
                    emit BatchTransferFailed(addr, tokenId);
                }
            } else {
                // Task card path.
                if (card.closed) {
                    emit BatchSkipped(addr);
                    unchecked {
                        ++i;
                    }
                    continue;
                }

                bool allOk = _reclaimTaskCardSlots(card, addr, _collection, _self, _initiator);
                if (allOk) {
                    card.closed = true;
                }
                // If any slot failed, card stays open for retry; the per-slot
                // `BatchTransferFailed` events identify what to address.
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Reclaim a task card's unclaimed NFTs (basic if applicable + each
    ///      unclaimed task slot) under try/catch so per-slot failures don't
    ///      poison the batch. Returns true iff every needed transfer
    ///      succeeded — caller uses this to decide whether to close the card.
    function _reclaimTaskCardSlots(
        Card storage card,
        address unlockAddress,
        address _collection,
        address _self,
        address _initiator
    ) internal returns (bool allOk) {
        allOk = true;

        if (card.hasBasic && card.unlockedAt == 0) {
            uint256 basicTokenId = card.tokenId;
            try IERC721(_collection).safeTransferFrom(_self, _initiator, basicTokenId) {
                card.tokenId = 0;
                card.hasBasic = false;
                emit WithdrawnExpired(_initiator, unlockAddress, basicTokenId);
            } catch {
                emit BatchTransferFailed(unlockAddress, basicTokenId);
                allOk = false;
            }
        }

        uint8 n = card.taskCount;
        for (uint8 i = 0; i < n;) {
            Task storage t = _tasks[_taskKey(unlockAddress, i)];
            if (t.claimedAt == 0) {
                uint256 taskTokenId = t.tokenId;
                try IERC721(_collection).safeTransferFrom(_self, _initiator, taskTokenId) {
                    t.claimedAt = block.timestamp;
                    emit WithdrawnExpired(_initiator, unlockAddress, taskTokenId);
                } catch {
                    emit BatchTransferFailed(unlockAddress, taskTokenId);
                    allOk = false;
                }
            }
            unchecked {
                ++i;
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
    function cardTaskCount(address unlockAddress) external view returns (uint8) {
        return _cards[unlockAddress].taskCount;
    }

    /// @inheritdoc IHongBaoNFTPool
    function cardHasBasic(address unlockAddress) external view returns (bool) {
        return _cards[unlockAddress].hasBasic;
    }

    /// @inheritdoc IHongBaoNFTPool
    function cardBoundTo(address unlockAddress) external view returns (address) {
        return _cards[unlockAddress].boundTo;
    }

    /// @inheritdoc IHongBaoNFTPool
    function cardClosed(address unlockAddress) external view returns (bool) {
        return _cards[unlockAddress].closed;
    }

    /// @inheritdoc IHongBaoNFTPool
    function isLocked(address unlockAddress) external view returns (bool) {
        Card storage card = _cards[unlockAddress];
        if (card.expire == 0 || card.closed) return false;
        if (card.taskCount == 0) return card.unlockedAt == 0;
        // Task card: still locked iff not closed and at least one NFT remains
        // (basic not withdrawn OR any unclaimed task slot).
        if (card.hasBasic && card.unlockedAt == 0) return true;
        uint8 n = card.taskCount;
        for (uint8 i = 0; i < n;) {
            if (_tasks[_taskKey(unlockAddress, i)].claimedAt == 0) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @inheritdoc IHongBaoNFTPool
    function isExpired(address unlockAddress) external view returns (bool) {
        Card storage card = _cards[unlockAddress];
        if (card.expire == 0 || card.closed) return false;
        if (card.taskCount == 0 && card.unlockedAt != 0) return false;
        return block.timestamp >= card.expire;
    }

    /// @inheritdoc IHongBaoNFTPool
    function remainingLockTime(address unlockAddress) external view returns (uint256) {
        Card storage card = _cards[unlockAddress];
        if (card.expire == 0 || card.closed) return 0;
        if (card.taskCount == 0 && card.unlockedAt != 0) return 0;
        if (block.timestamp >= card.expire) return 0;
        return card.expire - block.timestamp;
    }

    /// @inheritdoc IHongBaoNFTPool
    function getWithdrawDigest(address unlockAddress, address to) external view returns (bytes32) {
        return _getDigest(unlockAddress, to);
    }

    /// @inheritdoc IHongBaoNFTPool
    function task(address unlockAddress, uint8 taskIdx)
        external
        view
        returns (bytes32 hash, uint256 tokenId, uint256 claimedAt)
    {
        Task storage t = _tasks[_taskKey(unlockAddress, taskIdx)];
        return (t.hash, t.tokenId, t.claimedAt);
    }

    /// @inheritdoc IHongBaoNFTPool
    function taskKey(address unlockAddress, uint8 taskIdx) external pure returns (bytes32) {
        return _taskKey(unlockAddress, taskIdx);
    }

    /// @inheritdoc IHongBaoNFTPool
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
        // Reject high-S signatures (EIP-2 / OZ ECDSA canonical form).
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert InvalidSignature();
        }
        bytes32 digest = _getDigest(unlockAddress, to);
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != unlockAddress) revert InvalidSignature();
    }
}
