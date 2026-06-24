# HongBao NFT (ERC721) Wallet App Integration (Receiving a Red Packet)

## Overview

This document describes how a wallet app integrates the `HongBaoNFTPool` contract to implement the NFT "receiving a red packet" feature.

The contract supports two card types:

- **Plain card** — claim a single NFT with one signature. `cardTaskCount(unlockAddress) == 0`.
- **Task card** — one signature binds the recipient address (and releases the optional basic NFT); thereafter, each time a task is completed the project publishes a preimage and anyone can submit `claimTask` to force-transfer that slot's NFT to the already-bound recipient. `cardTaskCount(unlockAddress) > 0`.

Plain card core flow: **read card info → generate signing data → sign with hardware device → submit withdraw**.
The task card adds one more segment after the plain card flow: "collect all preimages → submit claimTask".

It is structurally identical to the ERC20 version, with the main NFT-specific differences being:

- Each slot (basic or task) is bound to a single tokenId (no topup, no open mode)
- `withdraw` / `claimTask` / `withdrawExpired` use `safeTransferFrom` — every recipient address must be able to receive ERC721
- The display layer reads `tokenURI` per slot rather than `symbol/decimals`

The contract has no fees and no privileged relayer; `withdraw` / `claimTask` can be submitted by **anyone**. Gas sponsorship is an optional application-layer service (out of scope for the contract).

## Prerequisites

- The `HongBaoNFTPool` contract address (deployed by the project via `HongBaoNFTFactory`)
- An RPC node

## Contract ABI

```typescript
import { parseAbi } from "viem";

const HongBaoNFTPoolABI = parseAbi([
  // basics — apply to all cards
  "function lockedCollection() view returns (address)",
  "function cardTokenId(address unlockAddress) view returns (uint256)",
  "function cardExpire(address unlockAddress) view returns (uint256)",
  "function cardUnlockedAt(address unlockAddress) view returns (uint256)",
  "function isLocked(address unlockAddress) view returns (bool)",
  "function isExpired(address unlockAddress) view returns (bool)",
  "function remainingLockTime(address unlockAddress) view returns (uint256)",
  "function getWithdrawDigest(address unlockAddress, address to) view returns (bytes32)",
  "function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s)",

  // task card surface (returns sensible defaults on plain cards)
  "function cardTaskCount(address unlockAddress) view returns (uint8)",
  "function cardHasBasic(address unlockAddress) view returns (bool)",
  "function cardBoundTo(address unlockAddress) view returns (address)",
  "function cardClosed(address unlockAddress) view returns (bool)",
  "function task(address unlockAddress, uint8 taskIdx) view returns (bytes32 hash, uint256 tokenId, uint256 claimedAt)",
  "function computeTaskHash(address unlockAddress, uint8 taskIdx, bytes n) view returns (bytes32)",
  "function claimTask(address unlockAddress, uint8 taskIdx, bytes n)",

  // relayer-oriented batch entry points (skip-silently on per-entry failure)
  "function batchWithdraw(address[] unlockAddresses, address[] tos, uint8[] vs, bytes32[] rs, bytes32[] ss)",
  "function batchClaimTask(address[] unlockAddresses, uint8[] taskIdxs, bytes[] preimages)",
]);
```

## Integration Flow

### Step 1: Get the Card Address

Get the `unlockAddress` (the Ethereum address corresponding to the card's public key) from the hardware device. This address is the unique identifier of the red packet within the contract.

### Step 2: Query the Red Packet Status

Make a combined call to several view functions:

```typescript
const [tokenId, expire, unlockedAt, collection] = await Promise.all([
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "cardTokenId", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "cardExpire", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "cardUnlockedAt", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "lockedCollection" }),
]);

const now = BigInt(Math.floor(Date.now() / 1000));
const exists = expire !== 0n;             // tokenId=0 is a valid id; use expire to determine existence
const isLocked = exists && unlockedAt === 0n;
const isExpired = isLocked && now >= expire;
```

Status determination (plain card):

| Condition | Meaning |
|------|------|
| `expire === 0` | The red packet does not exist |
| `unlockedAt !== 0` | Already claimed (or already reclaimed by the initiator) |
| `expire > 0 && unlockedAt === 0 && now < expire` | Claimable |
| `expire > 0 && unlockedAt === 0 && now >= expire` | Expired (the card holder can still claim with a signature until the initiator reclaims it) |

> ⚠️ In ERC721, `tokenId === 0` is a valid value and cannot be used to determine whether the red packet exists. You must use `cardExpire !== 0`.

> For task cards `unlockedAt !== 0` only means "basic withdraw done, recipient bound" — the card is still active and task slots can still be claimed. See the Task Card section for the per-card-type state machine.

### Step 3: Get the NFT Display Info

Get the ERC721 address from `lockedCollection()`, then read the collection metadata and the specific tokenURI as needed:

```typescript
const erc721MetadataAbi = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function tokenURI(uint256 tokenId) view returns (string)",
]);

const [nameResult, symbolResult, uriResult] = await publicClient.multicall({
  contracts: [
    { address: collection, abi: erc721MetadataAbi, functionName: "name" },
    { address: collection, abi: erc721MetadataAbi, functionName: "symbol" },
    { address: collection, abi: erc721MetadataAbi, functionName: "tokenURI", args: [tokenId] },
  ],
});
```

> The ERC721 metadata extension is **optional**: some NFT contracts do not implement `name/symbol/tokenURI`. Integrators must tolerate individual failures within `multicall` and must not error out entirely just because they cannot fetch the symbol.

### Step 4: Generate the Signing Digest

After the user confirms the claim and enters the recipient address:

```typescript
const digest = await publicClient.readContract({
  address: POOL,
  abi: HongBaoNFTPoolABI,
  functionName: "getWithdrawDigest",
  args: [unlockAddress, recipientAddress],
});
```

The EIP-712 schema is identical to the ERC20 version:

```
Withdraw(address unlockAddress, address to)
Domain: name="HongBao", version="1", chainId, verifyingContract
```

### Step 5: Sign with the Hardware Device

Send the digest (32 bytes) to the hardware device; the device signs it with its built-in private key and returns `v`, `r`, `s`.

> ⚠️ **`to` must be able to receive ERC721**. The contract internally uses `safeTransferFrom`: if `to` is a contract that does not implement `IERC721Receiver`, the transfer will revert. Because the hardware device can sign each card **only once**, if you use the wrong `to` and only discover after signing that the recipient does not accept NFTs, the card is effectively bricked — the signature has been used up, but the on-chain asset has not been released.
>
> Integrators **must** validate `to` before letting the device sign:
> - Prefer an EOA (an ordinary user wallet address)
> - If a contract address is allowed, off-chain you should first call `IERC165.supportsInterface(0x150b7a02)` or dry-run `IERC721Receiver.onERC721Received` to verify
> - Prompt the user in the UI: "The recipient address cannot be changed after confirmation"
>
> For **task cards** the stakes are higher: `to` becomes `boundTo` immutably, and **every** task NFT for the rest of the card's life will be sent there. A non-receiver `to` bricks the basic NFT (release reverts so `withdraw` itself reverts and you can retry) — but once binding succeeds, each later `claimTask` does its own `safeTransferFrom` to `boundTo`. If `boundTo` happens to be receiver-safe at bind time but later turns hostile (or never could accept transfers from this particular collection due to per-collection logic), that slot's NFT will be permanently unclaimable. The initiator's `withdrawExpired` also reverts on that slot, so the entire card stays "open" forever in the worst case.

> ⚠️ **Project (initiator) approval hygiene**: The NFT pool's push path (`onERC721Received`) only checks `from == initiator`. This `from` is filled in by the collection at call time — per the ERC721 standard, **any address that holds the initiator's `setApprovalForAll` approval on that collection** can push NFTs into the pool on the initiator's behalf and freely choose the `unlockAddress` and `lockTime`. If an attacker controls the device private key corresponding to that `unlockAddress`, this amounts to indirectly stealing the initiator's NFTs.
>
> Task cards raise the blast radius: the initiator's pull path (`depositWithTasks`) pulls **basic + every task NFT** under the same approval in one transaction. An attacker with `setApprovalForAll` on the initiator's collection can lock up an arbitrary set of the initiator's NFTs (subject to gas, capped at 255 tasks per card) inside a single phantom card whose `unlockAddress` they control.
>
> After deploying, the project **must**:
> - Only call `setApprovalForAll(pool, true)` for **this pool**
> - Never approve unaudited third-party contracts or unknown operators
> - Periodically review the active approvals on its own account on the collection (`isApprovedForAll(initiator, *)`)

### Step 6: Submit the withdraw Transaction

The `withdraw` contract function has no caller restriction; any address can submit it.

#### Option A: The Application's Own Wallet Pays Gas

```typescript
const txHash = await walletClient.writeContract({
  address: POOL,
  abi: HongBaoNFTPoolABI,
  functionName: "withdraw",
  args: [unlockAddress, recipientAddress, v, r, s],
});
```

#### Option B: Submitted by a Sponsor Service (Optional)

If the product wants to offer a "zero-ETH user experience," the app backend or a third-party service receives `(unlockAddress, to, v, r, s)` and then sends the transaction from its own wallet. The contract layer does not care.

#### Option C: Relayer Batch Submission (Optional)

The backend sponsor service accumulates withdraw requests over a period of time and submits them on-chain in one `batchWithdraw` to amortize the tx fee:

```typescript
await walletClient.writeContract({
  address: POOL,
  abi: HongBaoNFTPoolABI,
  functionName: "batchWithdraw",
  args: [unlockAddresses, tos, vs, rs, ss],
});
```

The contract **silently skips failures** for each entry (bad signature / card already redeemed / card already closed / `to == 0` / `to` is a non-receiver / etc.), emitting `BatchTransferFailed(unlockAddress, tokenId)` per failure, so one bad entry won't ruin the whole batch. The relayer should determine which entries succeeded via the `Withdrawn` event and settle only with successful users. `batchClaimTask` works the same way (see the Task Card section).

## Task Card

The NFT task card is for "complete a task to claim an extra NFT" scenarios. When locking each card, the project commits to 1..255 tasks, each corresponding to a `(hash, tokenId)`:

- `hash = keccak256(abi.encode(chainid, pool, unlockAddress, taskIdx, preimage))` — the preimage is generated and kept off-chain by the project
- `tokenId` — the NFT released after completing that task
- `hasBasic` + basic `tokenId` — optional "card-opening" NFT released immediately upon signed withdraw (can be omitted, in which case the signed withdraw is pure binding)

Design goal: **turn the signature from a "one-time proof to claim an NFT" into a "proof that binds a recipient address."**
- After the user signs `Withdraw(unlockAddress, to)`: the contract `safeTransferFrom`s the basic NFT (if `hasBasic`) to `to` and records `to` into `boundTo`. The card remains active.
- Thereafter, each time a task is completed, the project sends the preimage to the user. **Anyone** (the user themselves / a relayer / a third party) can submit `claimTask(unlockAddress, taskIdx, preimage)`; after verifying the hash, the contract **forces** the task NFT to be `safeTransferFrom`d to `boundTo`. It does not matter if the preimage leaks to a third party — the NFT can only go to `boundTo`.
- Preventing cross-chain / cross-card preimage reuse: the hash binds `(chainid, pool, unlockAddress, taskIdx)`, so the same preimage produces a different hash on another chain / pool / card / slot.

### Step 1: Identify the Card Type

```typescript
const taskCount = await publicClient.readContract({
  address: POOL,
  abi: HongBaoNFTPoolABI,
  functionName: "cardTaskCount",
  args: [unlockAddress],
});

if (taskCount === 0) {
  // plain card — follow Step 1-6 above
} else {
  // task card — follow the extended flow below
}
```

### Step 2: Read the Task Card State

```typescript
const [hasBasic, basicTokenId, boundTo, closed, unlockedAt] = await Promise.all([
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "cardHasBasic", args: [unlockAddress] }),
  // After basic withdraw, the basic slot is zeroed; cardTokenId returns 0.
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "cardTokenId", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "cardBoundTo", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "cardClosed", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "cardUnlockedAt", args: [unlockAddress] }),
]);

const tasks = await publicClient.multicall({
  contracts: Array.from({ length: taskCount }, (_, i) => ({
    address: POOL,
    abi: HongBaoNFTPoolABI,
    functionName: "task",
    args: [unlockAddress, i],
  })),
  allowFailure: false,
});
// each: [hash, tokenId, claimedAt]
```

Status determination:

| Condition | Meaning |
|------|------|
| `closed === true` | The project has reclaimed it; the card is dead, and all claim/withdraw calls will revert |
| `unlockedAt === 0` | Not yet signed/bound to a recipient address. Run the withdraw flow first to bind it |
| `unlockedAt !== 0 && boundTo !== 0` | Already bound. Slots where `tasks[i].claimedAt === 0` are claimable |

### Step 3: Bind the Recipient Address (withdraw)

Fully reuse the plain card's Step 4-6:

```typescript
const digest = await pool.getWithdrawDigest(unlockAddress, recipientAddress);
const { v, r, s } = await hardwareSign(digest);   // device signature
await pool.withdraw(unlockAddress, recipientAddress, v, r, s);
```

The task card's `withdraw`:
- If `hasBasic`: `safeTransferFrom`s the basic NFT to `to`, then sets `hasBasic = false` and zeros the basic slot. If `to` is a non-receiver, the basic transfer reverts and the whole `withdraw` reverts — you can retry with a different `to` since `boundTo` is only written **after** the basic transfer succeeds.
- Writes `to` into `boundTo` (immutable from here)
- Sets `unlockedAt = now`
- **The card remains active** and can continue to claim tasks

> ⚠️ Once withdraw succeeds, `boundTo` is permanently locked. All subsequent claims can only go to this address.

### Step 4: Submit Task Claims

After the project verifies in its backend that the user has completed a task, it sends the corresponding slot's `preimage` (a byte string) to the user. **Anyone** can submit:

```typescript
// preimage is bytes; viem represents it as a Hex string
const preimage: Hex = "0x...";

// (optional) local pre-check: compute the hash and compare with on-chain to avoid submitting a tx that will surely fail
const computed = await publicClient.readContract({
  address: POOL,
  abi: HongBaoNFTPoolABI,
  functionName: "computeTaskHash",
  args: [unlockAddress, taskIdx, preimage],
});
if (computed !== tasks[taskIdx][0]) {
  throw new Error("preimage does not match committed hash");
}

const txHash = await walletClient.writeContract({
  address: POOL,
  abi: HongBaoNFTPoolABI,
  functionName: "claimTask",
  args: [unlockAddress, taskIdx, preimage],
});
```

Contract guarantees:
- `boundTo` not yet bound → revert (must withdraw first)
- Card already closed → revert
- Hash mismatch → revert
- Slot already claimed → revert
- Otherwise → `safeTransferFrom` `tasks[taskIdx].tokenId` to `boundTo` and mark `claimedAt = now`

> ⚠️ **Per-slot bricking risk**: each `claimTask` does its own `safeTransferFrom(this, boundTo, tokenId)`. If `boundTo` (chosen at bind time) cannot accept that specific NFT (e.g. a contract whose `onERC721Received` reverts conditionally), this slot's claim reverts. The slot stays "claimable" forever from the contract's view, but no submission will ever succeed. Other slots and the (already-released) basic are unaffected, but the initiator's `withdrawExpired` on this card will also revert on the bricked slot — so the card never reaches `closed = true`. This is why receiver-safety of `to` matters even more for task cards than for plain cards.

#### Batch Claim (For Relayers)

```typescript
await walletClient.writeContract({
  address: POOL,
  abi: HongBaoNFTPoolABI,
  functionName: "batchClaimTask",
  args: [unlockAddresses, taskIdxs, preimages],
});
```

The contract silently skips failures for each entry (not a task card / out of bounds / already closed / basic not completed / already claimed / wrong preimage / non-receiver boundTo); a single failure does not ruin the entire batch. The relayer determines the successful entries via the `TaskClaimed` event.

### Project Side (Generating Preimages / Locking Cards)

Off-chain, the project:
1. Randomly generates N preimages for each card (32-byte random recommended)
2. Computes hash = `keccak256(abi.encode(chainid, pool, unlockAddress, taskIdx, preimage))`
3. Calls `depositWithTasks(unlockAddress, hasBasic, basicTokenId, hashes[], taskTokenIds[], lockTime)`, or batches `batchDepositWithTasks(...)`
4. Keeps the preimages off-chain and releases them as tasks are completed

Important NFT-specific deposit semantics:
- `depositWithTasks` does an atomic `transferFrom` chain: the basic NFT (if `hasBasic`) plus every task `tokenId` are pulled from the initiator in one transaction. If the initiator does not own any one of them, or has not granted `setApprovalForAll(pool, true)` on the collection, the whole call reverts — there is no partial state.
- Set `hasBasic = false` with any value (recommended `0`) for `basicTokenId` to create a card whose signature is **pure binding** (no immediate reward, all rewards are behind task slots).
- Unlike the ERC20 task card, **there is no topup** for NFT task cards. Basic and all task tokenIds are fixed at creation; you cannot add another basic NFT later.

A viem implementation of the contract-layer hash algorithm:

```typescript
import { encodeAbiParameters, keccak256 } from "viem";

function commitHash(
  chainId: bigint | number,
  pool: Address,
  unlockAddress: Address,
  taskIdx: number,
  preimage: Hex,
): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "uint256" }, { type: "address" }, { type: "address" }, { type: "uint8" }, { type: "bytes" }],
      [BigInt(chainId), pool, unlockAddress, taskIdx, preimage],
    ),
  );
}
```

> Once the project calls `depositWithTasks`, the task count, hashes, and tokenIds are **permanently immutable**.

## Full Flow Diagram

```
app connects wallet
     │
     ▼
get unlockAddress (hardware device)
     │
     ▼
read cardTaskCount(unlockAddress)
     │
     ├── 0  (plain card)
     │     │
     │     ▼
     │   read cardTokenId / cardExpire / cardUnlockedAt
     │     │
     │     ▼
     │   validate that `to` can receive ERC721 (safeTransferFrom compatible)
     │     │
     │     ▼
     │   getWithdrawDigest → device signature → withdraw(unlockAddress, to, v, r, s)
     │   card consumed, NFT received
     │
     └── >0 (task card)
           │
           ▼
         read cardHasBasic / cardBoundTo / cardClosed / cardUnlockedAt
         + task(idx) ×N    (each → [hash, tokenId, claimedAt])
           │
           ▼
         not bound? (unlockedAt == 0)
           │   ├── yes → ⚠️ even more critical to validate `to` here
           │   │       (binds boundTo permanently; ALL future task NFTs go there)
           │   │       withdraw to bind + receive basic NFT (if hasBasic)
           │   │
           │   └── no → skip to the claim stage
           │
           ▼
         project releases preimage_i (after the user completes the task)
           │
           ▼
         claimTask(unlockAddress, i, preimage_i)
         task NFT force-transferred to boundTo, can be submitted by anyone (user/relayer)
```

## Running the Examples

| Variable | Required | Description |
|------|------|------|
| `POOL_ADDRESS` | Yes | HongBaoNFTPool contract address |
| `RPC_URL` | Yes | RPC node URL |

```bash
cd integration-examples
npm install
npm run example:nft                # full read-side demo (plain + task card)
```

For the task-claim CLI (project side has issued a preimage; anyone can submit):

| Variable | Required | Description |
|------|------|------|
| `POOL_ADDRESS` | Yes | HongBaoNFTPool address |
| `UNLOCK_ADDRESS` | Yes | The task card address |
| `RPC_URL` | Yes | RPC node URL |
| `SUBMITTER_PRIVATE_KEY` | Yes | EOA private key used to send the tx (any account works; the NFT goes to `boundTo`) |

```bash
npm run example:nft-task-claim
```
