# HongBao — Time-Locked Red Packet Contracts

*[中文版 / Chinese version →](./README_CN.md)*

Time-locked red-packet contracts built around hardware signing devices. A project deposits assets and binds them to a card's public-key address; the card holder unlocks the assets with a device signature. Both contract families share one interaction model, supporting **ERC20** and **ERC721** respectively:

| Variant | Asset | Pool | Factory | Integration docs |
|------|------|------|---------|----------|
| Token | ERC20 | `HongBaoTokenPool` | `HongBaoTokenFactory` | [integration-examples/token](./integration-examples/token/README.md) |
| NFT   | ERC721 | `HongBaoNFTPool` | `HongBaoNFTFactory` | [integration-examples/nft](./integration-examples/nft/README.md) |

Both pools support two card flavors:

- **Plain card** — one signature redeems the full asset (full balance for Token, the bound NFT for NFT); a traditional red packet.
- **Task card** — one signature only binds the recipient address and releases the optional "basic" reward; afterwards, for each completed task the project issues a preimage and **anyone** submits `claimTask` to force the task reward (Token: amount; NFT: a specific tokenId) to the already-bound address. A CTF-flag-style progressive unlock that turns the signature from a "claim voucher" into a "binding voucher".

The contracts are fully decentralized: no owner, no pause, no fees, no privileged relayer.

## Core Flow

```
Plain card:
  1. Project calls deposit() to lock assets
  2. Card holder signs Withdraw(unlockAddress, to) with the device
  3. Anyone submits withdraw() → full asset to `to`, card consumed
  4. Unredeemed past expiry → initiator/depositor reclaims via withdrawExpired()

Token task card (restricted mode):
  1. Project calls depositWithTasks() to lock the card + publish taskHashes[]/taskAmounts[] on-chain
  2. Card holder signs Withdraw(unlockAddress, to) → withdraw() sends basicAmount to `to` and permanently binds boundTo
  3. User completes a task → project issues the preimage → anyone calls claimTask() to force the task amount to boundTo
  4. Unredeemed past expiry → initiator reclaims the remainder in one shot via withdrawExpired() and closes the card

NFT task card (restricted mode, 1 NFT per slot, atomic-pull batch):
  1. Project calls depositWithTasks() to atomically pull basic NFT (if hasBasic) + every task tokenId; taskHashes[]/taskTokenIds[] published on-chain
  2. Card holder signs Withdraw(unlockAddress, to) → withdraw() safeTransferFrom's the basic NFT (if any) to `to` and permanently binds boundTo
  3. User completes a task → project issues the preimage → anyone calls claimTask() to safeTransferFrom that task's tokenId to boundTo
  4. Unredeemed past expiry → initiator reclaims unclaimed NFTs in one shot via withdrawExpired() and closes the card (per-slot try/catch on batch path)
```

ERC20 and ERC721 are identical at the signing layer (same EIP-712 schema); only the asset type and a few management details differ — see the comparison table in the [integration examples index](./integration-examples/README.md).

## Contract Architecture

```
src/HongBao/
├── shared/                              # shared across variants
│   ├── interfaces/
│   │   ├── IERC20.sol
│   │   ├── IERC721.sol
│   │   └── IERC721Receiver.sol
│   ├── libraries/
│   │   └── SafeERC20.sol
│   └── utils/
│       └── ReentrancyGuard.sol
├── token/                               # ERC20 variant
│   ├── HongBaoTokenFactory.sol          # CREATE2 factory + registry
│   ├── HongBaoTokenPool.sol             # single (token, initiator) red-packet pool
│   └── interfaces/
│       ├── IHongBaoTokenFactory.sol
│       └── IHongBaoTokenPool.sol
└── nft/                                 # ERC721 variant
    ├── HongBaoNFTFactory.sol            # CREATE2 factory + registry
    ├── HongBaoNFTPool.sol               # single (collection, initiator) red-packet pool
    └── interfaces/
        ├── IHongBaoNFTFactory.sol
        └── IHongBaoNFTPool.sol
```

Each project deploys an independent pool instance per asset, standardized through the corresponding factory.

## Pool Modes

The constructor parameter `initiator` determines the pool's permission mode. Both pools share the same decision rule, but the NFT variant supports restricted mode only:

| `initiator` | Token Pool | NFT Pool |
|---|---|---|
| `address(0)` | **Open mode** — anyone can deposit; shares are accounted per depositor | Not supported (constructor reverts `ZeroInitiator`) |
| Non-zero address | **Restricted mode** — only that address may deposit | The only supported mode |

In Token open mode, multiple depositors can top up the same card; on redemption the full balance goes to `to` in one shot, and after expiry each depositor reclaims their own share. The NFT pool is restricted-only: a card holds exactly one tokenId, has no top-up semantics, and is reclaimed by the initiator after expiry.

## Signing Mechanism

EIP-712 schema (identical for both contracts):

```
Withdraw(address unlockAddress, address to)
```

- Domain: `name="HongBao"`, `version="1"`, `chainId`, `verifyingContract` (unique per pool)
- Single-use signature: once `unlockedAt != 0` it can no longer be withdrawn; no nonce needed
- Cross-chain / cross-contract replay protection: the domain binds `chainId` + pool address

> ⚠️ **NFT note**: the contract's withdraw uses `safeTransferFrom` internally, so `to` must be able to receive ERC721. The hardware device signs each card only once; signing the wrong `to` (e.g. a contract that does not implement `IERC721Receiver`) bricks a plain card. For task cards, `boundTo` is set permanently at bind time and every subsequent task slot will `safeTransferFrom` its own NFT to `boundTo` later — a non-receiver `boundTo` is **per-slot bricking** for every claim that follows. Integrators must validate `to` before letting the device sign. See [integration-examples/nft/README.md](./integration-examples/nft/README.md).

## Core Functions

### Token Pool (`HongBaoTokenPool`)

The Token pool supports two card flavors:

- **Plain card (`cardTaskCount == 0`)** — one signature redeems the full balance, matching the original ERC20 design.
- **Task card (`cardTaskCount > 0`)** — a "gift card + complete-tasks-to-earn" model. One signature only binds `to` and releases `basicAmount`; afterwards the project issues a preimage for each task and **anyone** submits `claimTask` to force that task's amount to `boundTo`. Restricted mode only.

#### Deposits

| Function | Card type | Notes |
|---|---|---|
| `deposit(unlockAddress, amount, lockTime)` | Plain / task-card top-up | Creates a plain card on first deposit / tops up `basicAmount` on any card; first deposit needs `lockTime >= MIN_LOCK_TIME`, top-ups ignore it |
| `batchDeposit(unlockAddresses[], amount, lockTime)` | Plain | Batch plain cards, same amount/lockTime each |
| `depositWithTasks(unlockAddress, basicAmount, taskHashes[], taskAmounts[], lockTime)` | Task | Creates a task card in one shot; hashes/amounts are immutable once on-chain |
| `batchDepositWithTasks(unlockAddresses[], basicAmounts[], taskHashes[][], taskAmounts[][], lockTime)` | Task | Atomic batch of arbitrarily-shaped task cards, one `safeTransferFrom` for the grand total |

#### Withdrawals

| Function | Caller | Notes |
|---|---|---|
| `withdraw(unlockAddress, to, v, r, s)` | Anyone | Plain card: full amount to `to`, card consumed. Task card: sends `basicAmount` + permanently binds `boundTo = to`, card stays active |
| `batchWithdraw(unlockAddresses[], tos[], vs[], rs[], ss[])` | Anyone (relayer) | Batch withdraw; bad-signature / already-redeemed / closed / zero-`to` entries are silently skipped without poisoning the batch |
| `claimTask(unlockAddress, taskIdx, n)` | Anyone | Verifies `keccak256(abi.encode(chainid, pool, unlockAddress, taskIdx, n)) == taskHashes[taskIdx]`, sends `taskAmounts[taskIdx]` to `boundTo`. Requires a prior `withdraw` binding |
| `batchClaimTask(unlockAddresses[], taskIdxs[], preimages[])` | Anyone (relayer) | Batch claim; not-a-task-card / out-of-range / closed / not-bound / already-claimed / wrong-preimage entries are silently skipped |
| `withdrawExpired(unlockAddress)` | Plain: depositor; task: initiator | Plain card reclaims per share; task card initiator reclaims the remainder in one shot and sets `closed = true` |
| `batchWithdrawExpired(unlockAddresses[])` | Same as above | Batch; closed / already-redeemed / no-share entries are silently skipped; plain + task cards may be mixed in one batch |

> `batchWithdraw` / `batchClaimTask` are skip-silently by design, for relayers: if one of N requests in a batch has stale state or a bad signature, it should not drag down the other N-1. Off-chain consumers determine which succeeded via the `Withdrawn` / `TaskClaimed` events.

#### Views

| Function | Returns |
|---|---|
| `cardTotal(unlockAddress)` | Current remaining claimable total (unredeemed basic + unclaimed task amounts) |
| `cardBasicAmount(unlockAddress)` | Amount the next `withdraw` will release; for plain cards this mirrors `cardTotal` |
| `cardTaskCount(unlockAddress)` | 0 = plain card, >0 = task card |
| `cardBoundTo(unlockAddress)` | The `to` bound after a task card's `withdraw` (returns 0 for plain or unbound cards) |
| `cardClosed(unlockAddress)` | Whether a task card has been closed by the initiator via `withdrawExpired` |
| `cardExpire(unlockAddress)` | Expiration timestamp |
| `cardUnlockedAt(unlockAddress)` | Redemption timestamp (plain = claim time; task = basic-withdraw time) |
| `task(unlockAddress, taskIdx)` | `(hash, amount, claimedAt)` |
| `computeTaskHash(unlockAddress, taskIdx, n)` | Off-chain verification helper, equivalent to `keccak256(abi.encode(chainid, pool, unlockAddress, taskIdx, n))` |
| `depositRecord(unlockAddress, depositor)` | A depositor's share (used by open-mode plain cards) |
| `lockedToken()` | The bound ERC20 address |
| `initiator()` | The sole depositor in restricted mode (0 in open mode; always non-zero for task cards) |
| `MAX_TASKS_PER_CARD()` | 255 |

### NFT Pool (`HongBaoNFTPool`)

The NFT pool supports the same two card flavors as the Token pool, adapted for ERC721 semantics:

- **Plain card (`cardTaskCount == 0`)** — one signature redeems a single bound tokenId.
- **Task card (`cardTaskCount > 0`)** — one signature binds `to` (and releases the optional basic NFT if `hasBasic`); afterwards the project issues a preimage for each task and **anyone** submits `claimTask` to force that task's tokenId to `boundTo`. Basic + all task tokenIds are fixed at creation (no topup).

#### Deposits

| Function | Card type | Notes |
|---|---|---|
| `deposit(unlockAddress, tokenId, lockTime)` | Plain | Pull path. Called after the initiator approves the pool |
| `onERC721Received(...)` | Plain | Push path. The initiator directly calls `safeTransferFrom(initiator, pool, tokenId, abi.encode(unlockAddress, lockTime))`. **Plain cards only** — task cards must use `depositWithTasks` |
| `depositWithTasks(unlockAddress, hasBasic, basicTokenId, taskHashes[], taskTokenIds[], lockTime)` | Task | Atomic N+1 pull: basic NFT (if `hasBasic`) plus every task tokenId. Reverts if any single `transferFrom` fails |
| `batchDepositWithTasks(unlockAddresses[], hasBasics[], basicTokenIds[], taskHashes[][], taskTokenIds[][], lockTime)` | Task | Atomic batch of arbitrarily-shaped task cards in one tx |

The NFT pool has no plain `batchDeposit` — a plain card holds exactly one tokenId, so plain-card batching is done at the script layer with a loop (see `script/BatchDepositNFT.s.sol`). Task cards have an on-chain `batchDepositWithTasks` because they already loop internally over each card's slot set.

#### Withdrawals

| Function | Caller | Notes |
|---|---|---|
| `withdraw(unlockAddress, to, v, r, s)` | Anyone | Plain card: transfers the NFT to `to`, card consumed. Task card: if `hasBasic`, `safeTransferFrom`s the basic NFT to `to`; in both cases binds `boundTo = to` and sets `unlockedAt`. Card stays active for task claims |
| `batchWithdraw(unlockAddresses[], tos[], vs[], rs[], ss[])` | Anyone (relayer) | Batch withdraw; bad-signature / already-redeemed / closed / zero-`to` / non-receiver-`to` entries are silently skipped, emitting `BatchTransferFailed(unlockAddress, tokenId)` per failure |
| `claimTask(unlockAddress, taskIdx, n)` | Anyone | Verifies `keccak256(abi.encode(chainid, pool, unlockAddress, taskIdx, n)) == taskHashes[taskIdx]`, `safeTransferFrom`s `taskTokenIds[taskIdx]` to `boundTo`. Requires a prior `withdraw` binding |
| `batchClaimTask(unlockAddresses[], taskIdxs[], preimages[])` | Anyone (relayer) | Batch claim; not-a-task-card / out-of-range / closed / not-bound / already-claimed / wrong-preimage / non-receiver-boundTo entries are silently skipped |
| `withdrawExpired(unlockAddress)` | initiator | Plain card: reclaims the NFT. Task card: atomically reclaims basic (if `hasBasic`) + every unclaimed task NFT and sets `closed = true`. Single-shot — reverts on any per-slot transfer failure |
| `batchWithdrawExpired(unlockAddresses[])` | initiator | Batch; per-entry `safeTransferFrom` failure is skipped, leaving state intact for retry. Task cards only set `closed = true` when every slot has been successfully reclaimed; plain + task cards may be mixed in one batch |

> `batchWithdraw` / `batchClaimTask` / `batchWithdrawExpired` are skip-silently by design: if one of N requests in a batch has stale state or its `safeTransferFrom` reverts (non-receiver `to`/`boundTo`, etc.), it should not drag down the other N-1. Off-chain consumers determine which succeeded via the `Withdrawn` / `TaskClaimed` events.

#### Views

| Function | Returns |
|---|---|
| `cardTokenId(unlockAddress)` | Plain card: the bound tokenId. Task card with `hasBasic`: the basic NFT id (zeroed after `withdraw`). Otherwise 0. **Note**: 0 is a valid tokenId value; use `cardExpire != 0` to test existence |
| `cardTaskCount(unlockAddress)` | 0 = plain card, >0 = task card |
| `cardHasBasic(unlockAddress)` | Task card only: whether the basic NFT is still in the pool (cleared after `withdraw` releases it) |
| `cardBoundTo(unlockAddress)` | The `to` bound after a task card's `withdraw` (0 for plain or unbound cards) |
| `cardClosed(unlockAddress)` | Whether a task card has been closed by the initiator via `withdrawExpired` |
| `cardExpire(unlockAddress)` | Expiration timestamp (0 means the card does not exist) |
| `cardUnlockedAt(unlockAddress)` | Redemption timestamp (plain = claim time; task = basic-withdraw/bind time) |
| `task(unlockAddress, taskIdx)` | `(hash, tokenId, claimedAt)` |
| `computeTaskHash(unlockAddress, taskIdx, n)` | Off-chain verification helper, equivalent to `keccak256(abi.encode(chainid, pool, unlockAddress, taskIdx, n))` |
| `lockedCollection()` | The bound ERC721 collection address |
| `initiator()` | The sole depositor (guaranteed non-zero) |
| `MAX_TASKS_PER_CARD()` | 255 |

### Shared Views (identical for both pools)

| Function | Returns |
|---|---|
| `isLocked(unlockAddress)` | Whether the asset is still held |
| `isExpired(unlockAddress)` | Whether it is expired and unredeemed |
| `remainingLockTime(unlockAddress)` | Remaining lock seconds |
| `getWithdrawDigest(unlockAddress, to)` | EIP-712 signing digest |
| `DOMAIN_SEPARATOR()` | EIP-712 domain separator |
| `WITHDRAW_TYPEHASH()` | EIP-712 type hash |
| `MIN_LOCK_TIME()` | Minimum lock duration (30 days) |

### Factory

`HongBaoTokenFactory` and `HongBaoNFTFactory` have fully symmetric interfaces, differing only in the asset parameter name:

| Token Factory | NFT Factory | Notes |
|---|---|---|
| `createPool(token, initiator)` | `createPool(collection, initiator)` | CREATE2-deploys a new pool; `(asset, initiator)` is unique |
| `pools(token, initiator)` | `pools(collection, initiator)` | Look up a registered pool address (returns 0 if not deployed) |
| `computePoolAddress(token, initiator)` | `computePoolAddress(collection, initiator)` | Deterministic address, computable before deployment |

> The NFT factory's `createPool` rejects `initiator == 0`, consistent with the NFT pool's restricted-only design.

## Constants

| Constant | Value |
|---|---|
| `MIN_LOCK_TIME` | 30 days (hardcoded in both pools) |
| `WITHDRAW_TYPEHASH` | `keccak256("Withdraw(address unlockAddress,address to)")` |

## Development

```bash
# Build (optimizer + via_ir enabled, see foundry.toml)
forge build

# Run the full test suite (~200 tests, covering Token / NFT / plain + task cards)
forge test -vv

# Token tests only
forge test --match-path "test/HongBaoToken*.t.sol" -vv

# NFT tests only
forge test --match-path "test/HongBaoNFT*.t.sol" -vv
```

### Test Coverage

- **HongBaoTokenPool plain card, restricted mode (34 tests)**: deposit / batchDeposit / topup / withdraw / withdrawExpired / batchWithdrawExpired (including skip cases for already-redeemed and zero-share) / high-S signature rejection / views / constructor parameter checks
- **HongBaoTokenPool plain card, open mode (4 tests)**: multiple depositors on one card / a single withdraw sweeping all depositors / per-share reclaim after expiry / front-run grief scenario
- **HongBaoTokenPool task card (45 tests)**: depositWithTasks (happy / edge cases / all reverts) / topup into basic / withdraw releasing basic + binding boundTo / claimTask (happy / callable by anyone / hash binding defeats cross-chain + cross-card reuse / still claimable past expiry before close / reverts after close) / withdrawExpired task-card branch / batchWithdrawExpired mixing plain + task cards / batchDepositWithTasks atomic rollback on failure / views
- **HongBaoTokenPool batchWithdraw / batchClaimTask (17 tests)**: happy path for both batch functions (multiple tasks on one card, across cards) / skip-silently (bad signature, already redeemed, zero `to`, wrong preimage, basic not completed, closed, out-of-range idx, not a task card, already-claimed slot) / length checks
- **HongBaoTokenFactory (8 tests)**: `createPool` happy path / duplicate `PoolExists` / `computePoolAddress` matches the actual deployed address / open-mode pool / different (token, initiator) combinations
- **HongBaoNFTPool plain card (19 tests)**: pull / push deposit / withdraw / withdrawExpired / batchWithdrawExpired / recipient compatibility / views / constructor parameter checks
- **HongBaoNFTPool task card (43 tests)**: depositWithTasks (happy / with-and-without basic / all reverts / atomic rollback on missing approval) / withdraw releasing basic (or pure binding) + binding boundTo / claimTask (happy / callable by anyone / hash binding defeats cross-chain + cross-card + cross-slot reuse / still claimable past expiry before close / reverts after close) / withdrawExpired task-card branch (atomic reclaim + close) / batchWithdrawExpired mixing plain + task cards / batchDepositWithTasks atomic rollback / views (incl. hasBasic / boundTo / closed) / chainid-bound hash verification
- **HongBaoNFTPool batchWithdraw / batchClaimTask (17 tests)**: happy path (multiple tasks on one card, across cards) / skip-silently (bad signature, already redeemed, non-receiver `to`, zero `to`, wrong preimage, basic not completed, closed, out-of-range, plain card mistaken for task card, already-claimed slot) / `batchWithdrawExpired` task partial-failure leaves card open for retry
- **HongBaoNFTFactory (3 tests)**: `createPool` happy path / duplicate `PoolExists` / `computePoolAddress` matches the actual deployed address
- **HongBaoLens (6 tests)**: token + NFT view aggregation across plain and task cards (with all-slots populated)

## Deployment Scripts

### Token Variant

```bash
# 1. Deploy the factory (one-time)
forge script script/DeployFactory.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 2. Create a pool (once per token × initiator)
FACTORY=0x... TOKEN=0x... INITIATOR=0x... \
forge script script/CreatePool.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 3a. Plain card batch deposit (same amount each)
POOL=0x... AMOUNT_ETHER=100 LOCK_DAYS=30 ADDRESSES_JSON=./addresses.json \
forge script script/BatchDeposit.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 3b. Task card batch creation (per-card basicAmount + tasks)
POOL=0x... LOCK_DAYS=30 CARDS_JSON=./task-cards.json \
forge script script/BatchDepositWithTasks.s.sol --rpc-url $RPC --private-key $PK --broadcast
```

`addresses.json` (plain cards):
```json
{ "addresses": ["0xAbc...", "0xDef...", ...] }
```

`task-cards.json` (task cards, amounts in the token's smallest unit):
```json
{
  "cards": [
    {
      "unlockAddress": "0xCard1...",
      "basicAmount": 10000000000000000000,
      "taskHashes":  ["0xabc...", "0xdef..."],
      "taskAmounts": [20000000000000000000, 30000000000000000000]
    }
  ]
}
```
`taskHashes[i] = keccak256(abi.encode(chainid, pool, unlockAddress, i, preimage_i))`; preimages are generated and kept off-chain, **and must be computed with the target chain's chainid** — different chains need different hashes. See [integration-examples/token/README.md](./integration-examples/token/README.md#task-card).

### NFT Variant

> ⚠️ **Collection due diligence (deployer's responsibility, not checked by the factory)**: the contract trusts `lockedCollection` to follow ERC721 faithfully. An upgradeable / malicious collection can register phantom cards and permanently brick an `unlockAddress`. Recommended:
> - Non-upgradeable contract (no EIP-1967 proxy slot)
> - Trusted source / audited
> - Standard `safeTransferFrom`, `transferFrom`, `ownerOf` behavior

```bash
# 1. Deploy the factory (one-time)
forge script script/DeployNFTFactory.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 2. Create a pool (once per collection × initiator; INITIATOR required)
FACTORY=0x... COLLECTION=0x... INITIATOR=0x... \
forge script script/CreateNFTPool.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 3a. Plain card batch deposit (script-level loop over deposit; whole batch reverts if any one fails)
POOL=0x... LOCK_DAYS=30 ENTRIES_JSON=./entries.json \
forge script script/BatchDepositNFT.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 3b. Task card batch creation (per-card hasBasic + basicTokenId + tasks; atomic on-chain batch)
POOL=0x... LOCK_DAYS=30 CARDS_JSON=./nft-task-cards.json \
forge script script/BatchDepositNFTWithTasks.s.sol --rpc-url $RPC --private-key $PK --broadcast
```

`entries.json` (plain cards):
```json
{
  "entries": [
    { "unlockAddress": "0xAbc...", "tokenId": "1" },
    { "unlockAddress": "0xDef...", "tokenId": "2" }
  ]
}
```

`nft-task-cards.json` (task cards; tokenIds are string-encoded for JSON precision):
```json
{
  "cards": [
    {
      "unlockAddress": "0xCard1...",
      "hasBasic": true,
      "basicTokenId": "1",
      "taskHashes": ["0xabc...", "0xdef..."],
      "taskTokenIds": ["10", "11"]
    },
    {
      "unlockAddress": "0xCard2...",
      "hasBasic": false,
      "basicTokenId": "0",
      "taskHashes": ["0x123..."],
      "taskTokenIds": ["20"]
    }
  ]
}
```
`hasBasic: false` makes the signed `withdraw` pure binding (no immediate NFT release; only `boundTo` is latched). `basicTokenId` is ignored on-chain when `hasBasic` is false, but the script still requires the field for shape uniformity — `"0"` is a safe placeholder. `taskHashes[i] = keccak256(abi.encode(chainid, pool, unlockAddress, i, preimage_i))`; preimages are generated and kept off-chain, **and must be computed with the target chain's chainid**. See [integration-examples/nft/README.md](./integration-examples/nft/README.md#task-card).

## End-to-End Testing (Device + Contract)

> ⚠️ **Unavailable to external users**: `e2e_test.py` depends on a private STM32 hardware-signing toolchain (`../mac_tool/stm32_crypto_wrapper`, outside this repo) and a physical device connection, neither of which is open-sourced here. External contributors should rely on `forge test` (~200 unit tests) — it simulates device signing with Foundry's `vm.sign` and covers all contract logic.

When you have an STM32 device + the private `mac_tool`:

```bash
../mac_tool/venv/bin/python3 e2e_test.py
```

Currently covers the Token variant: withdraw (submitted by anyone) / withdrawExpired (fast-forward 30 days) / batchDeposit / wrong-signature revert / factory address-prediction consistency. The NFT variant's e2e is still to come.

## Integration

Wallet-app integration examples and docs:

- [integration-examples/](./integration-examples/README.md) — overview and variant comparison
- [integration-examples/token/](./integration-examples/token/README.md) — ERC20 integration (with viem examples)
- [integration-examples/nft/](./integration-examples/nft/README.md) — ERC721 integration (with viem examples + `to` validation notes)

## License

MIT
