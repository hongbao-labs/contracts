# HongBao Token (ERC20) Wallet App Integration (Receiving a Red Packet)

## Overview

This document describes how a wallet app integrates the `HongBaoTokenPool` contract to implement the ERC20 "receiving a red packet" feature.

The contract supports two card types:

- **Plain card** — claim the full amount with a single signature. `cardTaskCount(unlockAddress) == 0`.
- **Task card** — a single signature only binds the recipient address and releases `basicAmount`; thereafter, each time a task is completed the project publishes a preimage, and anyone can submit `claimTask` to force-transfer the task reward to the already-bound `to`. `cardTaskCount(unlockAddress) > 0`.

Plain card core flow: **read card info → generate signing data → sign with hardware device → submit withdraw**.
The task card adds one more segment after the plain card flow: "collect all preimages → submit claimTask".

The contract has no fees and no privileged relayer; `withdraw` / `claimTask` can be submitted by **anyone**. Gas sponsorship is an optional application-layer service (out of scope for the contract).

## Prerequisites

- The `HongBaoTokenPool` contract address (deployed by the project via `HongBaoTokenFactory`)
- An RPC node

## Contract ABI

```typescript
import { parseAbi } from "viem";

const HongBaoTokenPoolABI = parseAbi([
  // basics — apply to all cards
  "function lockedToken() view returns (address)",
  "function cardTotal(address unlockAddress) view returns (uint256)",
  "function cardExpire(address unlockAddress) view returns (uint256)",
  "function cardUnlockedAt(address unlockAddress) view returns (uint256)",
  "function isLocked(address unlockAddress) view returns (bool)",
  "function isExpired(address unlockAddress) view returns (bool)",
  "function remainingLockTime(address unlockAddress) view returns (uint256)",
  "function getWithdrawDigest(address unlockAddress, address to) view returns (bytes32)",
  "function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s)",

  // task card surface (returns sensible defaults on plain cards)
  "function cardTaskCount(address unlockAddress) view returns (uint8)",
  "function cardBasicAmount(address unlockAddress) view returns (uint256)",
  "function cardBoundTo(address unlockAddress) view returns (address)",
  "function cardClosed(address unlockAddress) view returns (bool)",
  "function task(address unlockAddress, uint8 taskIdx) view returns (bytes32 hash, uint256 amount, uint256 claimedAt)",
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
const [total, expire, unlockedAt, token] = await Promise.all([
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardTotal", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardExpire", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardUnlockedAt", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "lockedToken" }),
]);

const now = BigInt(Math.floor(Date.now() / 1000));
const isLocked = total > 0n && unlockedAt === 0n;
const isExpired = isLocked && now >= expire;
```

Status determination:

| Condition | Meaning |
|------|------|
| `total === 0 && unlockedAt === 0` | The red packet does not exist |
| `unlockedAt !== 0` | Already claimed |
| `total > 0 && unlockedAt === 0 && now < expire` | Claimable |
| `total > 0 && unlockedAt === 0 && now >= expire` | Expired (the card holder can still claim with a signature until the depositor reclaims it) |

### Step 3: Get the Token Display Info

Get the ERC20 address from `lockedToken()`, then read `symbol()` / `decimals()`:

```typescript
import { erc20Abi } from "viem";

const [symbolResult, decimalsResult] = await publicClient.multicall({
  contracts: [
    { address: token, abi: erc20Abi, functionName: "symbol" },
    { address: token, abi: erc20Abi, functionName: "decimals" },
  ],
});
```

### Step 4: Generate the Signing Digest

After the user confirms the claim and enters the recipient address:

```typescript
const digest = await publicClient.readContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
  functionName: "getWithdrawDigest",
  args: [unlockAddress, recipientAddress],
});
```

### Step 5: Sign with the Hardware Device

Send the digest (32 bytes) to the hardware device; the device signs it with its built-in private key and returns `v`, `r`, `s`.

### Step 6: Submit the withdraw Transaction

The `withdraw` contract function has no caller restriction; any address can submit it.

#### Option A: The Application's Own Wallet Pays Gas

```typescript
const txHash = await walletClient.writeContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
  functionName: "withdraw",
  args: [unlockAddress, recipientAddress, v, r, s],
});
```

This fits cases where the app already manages a sending address, or the user brings their own EOA.

#### Option B: Submitted by a Sponsor Service (Optional)

If the product wants to offer a "zero-ETH user experience," the app backend or a third-party service receives `(unlockAddress, to, v, r, s)` and then sends the transaction from its own wallet.

Because the contract charges no fees and has no whitelist restriction, this layer is entirely business logic: the backend decides whether and how to charge the user. The contract layer does not care.

#### Option C: Relayer Batch Submission (Optional)

The backend sponsor service accumulates withdraw requests over a period of time and submits them on-chain in one `batchWithdraw` to amortize the tx fee:

```typescript
await walletClient.writeContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
  functionName: "batchWithdraw",
  args: [unlockAddresses, tos, vs, rs, ss],
});
```

The contract **silently skips failures** for each entry (bad signature / card already redeemed / card already closed / `to == 0`), so it won't ruin the entire batch just because one entry is expired. The relayer should determine which entries succeeded via the `Withdrawn` event and settle only with successful users. `batchClaimTask` works the same way (see the Task Card section).

> ⚠️ **Token compatibility**: The ERC20 `transfer` inside `batch*` has no `try/catch`. If `lockedToken` has a recipient-side callback (ERC777 `tokensReceived`, ERC1363 `onTransferReceived`, etc.) and an entry's `to` (or a task card's `boundTo`) is a contract that reverts in the callback, **the entire batch is DoS'd by that one entry**. Standard ERC20s (USDC, DAI, plain ERC20) have no such callback and are unaffected. If you intend to support ERC777-class tokens, the relayer should filter off-chain whether `to` is a known problematic contract before submitting.

## Task Card

The task card is for "complete a task to claim an extra reward" scenarios. When locking each card, the project commits to 1..255 tasks, each corresponding to a `(hash, amount)`:

- `hash = keccak256(abi.encode(chainid, pool, unlockAddress, taskIdx, preimage))` — the preimage is generated and kept off-chain by the project
- `amount` — the amount released after completing that task
- `basicAmount` — the "card-opening reward" released immediately upon signed withdraw (can be 0, i.e. pure binding)

Design goal: **turn the signature from a "one-time proof to claim money" into a "proof that binds a recipient address."**
- After the user signs `Withdraw(unlockAddress, to)`: the contract transfers `basicAmount` to `to` and records `to` into `boundTo`. The card remains active.
- Thereafter, each time a task is completed, the project sends the preimage to the user. **Anyone** (the user themselves / a relayer / a third party) can submit `claimTask(unlockAddress, taskIdx, preimage)`; after verifying the hash, the contract **forces** the task amount to be transferred to `boundTo`. It does not matter if the preimage leaks to a third party — the funds can only go to `boundTo`.
- Preventing cross-chain / cross-card preimage reuse: the hash binds `(chainid, pool, unlockAddress, taskIdx)`, so the same preimage produces a different hash on another chain / pool / card / slot.

### Step 1: Identify the Card Type

```typescript
const taskCount = await publicClient.readContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
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
const [basicAmount, boundTo, closed, total, unlockedAt] = await Promise.all([
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardBasicAmount", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardBoundTo", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardClosed", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardTotal", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardUnlockedAt", args: [unlockAddress] }),
]);

const tasks = await Promise.all(
  Array.from({ length: taskCount }, (_, i) =>
    publicClient.readContract({
      address: POOL,
      abi: HongBaoTokenPoolABI,
      functionName: "task",
      args: [unlockAddress, i],
    })
  )
);
// each: [hash, amount, claimedAt]
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
- Transfers `basicAmount` to `to` (may be 0)
- Writes `to` into `boundTo` (immutable)
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
  abi: HongBaoTokenPoolABI,
  functionName: "computeTaskHash",
  args: [unlockAddress, taskIdx, preimage],
});
if (computed !== tasks[taskIdx].hash) {
  throw new Error("preimage does not match committed hash");
}

const txHash = await walletClient.writeContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
  functionName: "claimTask",
  args: [unlockAddress, taskIdx, preimage],
});
```

Contract guarantees:
- `boundTo` not yet bound → revert (must withdraw first)
- Card already closed → revert
- Hash mismatch → revert
- Slot already claimed → revert
- Otherwise → transfer `tasks[taskIdx].amount` to `boundTo` and mark `claimedAt = now`

#### Batch Claim (For Relayers)

```typescript
await walletClient.writeContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
  functionName: "batchClaimTask",
  args: [unlockAddresses, taskIdxs, preimages],
});
```

The contract silently skips failures for each entry (not a task card / out of bounds / already closed / basic not completed / already claimed / wrong preimage); a single failure does not ruin the entire batch. The relayer determines the successful entries via the `TaskClaimed` event.

### Project Side (Generating Preimages / Locking Cards)

Off-chain, the project:
1. Randomly generates N preimages for each card (32-byte random recommended)
2. Computes hash = `keccak256(abi.encode(pool, unlockAddress, taskIdx, preimage))`
3. Calls `depositWithTasks(unlockAddress, basicAmount, hashes[], amounts[], lockTime)`, or batches `batchDepositWithTasks(...)`
4. Keeps the preimages off-chain and releases them as tasks are completed

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

> Once the project calls `depositWithTasks`, the task count, hashes, and amounts are **permanently immutable**. `basicAmount` can continue to be topped up via `deposit(unlockAddress, amount, 0)` (until the user completes the withdraw binding).

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
     │   read cardTotal / cardExpire / cardUnlockedAt
     │     │
     │     ▼
     │   getWithdrawDigest → device signature → withdraw(unlockAddress, to, v, r, s)
     │   card consumed, full amount received
     │
     └── >0 (task card)
           │
           ▼
         read cardBasicAmount / cardBoundTo / cardClosed
         + task(idx) ×N
           │
           ▼
         not bound? (unlockedAt == 0)
           │   ├── yes → withdraw to bind to + receive basicAmount
           │   │       (the signing right is now used up, boundTo permanently locked)
           │   │
           │   └── no → skip to the claim stage
           │
           ▼
         project releases preimage_i (after the user completes the task)
           │
           ▼
         claimTask(unlockAddress, i, preimage_i)
         amount force-transferred to boundTo, can be submitted by anyone (user/relayer)
```

## Running the Example

| Variable | Required | Description |
|------|------|------|
| `POOL_ADDRESS` | Yes | HongBaoTokenPool contract address |
| `RPC_URL` | Yes | RPC node URL |

```bash
cd integration-examples
npm install
npm run example:token
```
