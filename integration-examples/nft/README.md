# HongBao NFT (ERC721) Wallet App Integration (Receiving a Red Packet)

## Overview

This document describes how a wallet app integrates the `HongBaoNFTPool` contract to implement the NFT "receiving a red packet" feature.

Core flow: **read red packet info → generate signing data → sign with hardware device → submit withdraw transaction**. It is structurally identical to the ERC20 version, with the main differences being:

- Each card is bound to a single tokenId (no topup, no open mode)
- `withdraw` / `withdrawExpired` use `safeTransferFrom` — the recipient address must be able to receive ERC721
- The display layer needs to read the ERC721 `tokenURI` / collection metadata rather than `symbol/decimals`

The contract has no fees and no privileged relayer; `withdraw` can be submitted by **anyone**. Gas sponsorship is an optional application-layer service (out of scope for the contract).

## Prerequisites

- The `HongBaoNFTPool` contract address (deployed by the project via `HongBaoNFTFactory`)
- An RPC node

## Contract ABI

```typescript
import { parseAbi } from "viem";

const HongBaoNFTPoolABI = parseAbi([
  "function lockedCollection() view returns (address)",
  "function cardTokenId(address unlockAddress) view returns (uint256)",
  "function cardExpire(address unlockAddress) view returns (uint256)",
  "function cardUnlockedAt(address unlockAddress) view returns (uint256)",
  "function isLocked(address unlockAddress) view returns (bool)",
  "function isExpired(address unlockAddress) view returns (bool)",
  "function remainingLockTime(address unlockAddress) view returns (uint256)",
  "function getWithdrawDigest(address unlockAddress, address to) view returns (bytes32)",
  "function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s)",
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

Status determination:

| Condition | Meaning |
|------|------|
| `expire === 0` | The red packet does not exist |
| `unlockedAt !== 0` | Already claimed (or already reclaimed by the initiator) |
| `expire > 0 && unlockedAt === 0 && now < expire` | Claimable |
| `expire > 0 && unlockedAt === 0 && now >= expire` | Expired (the card holder can still claim with a signature until the initiator reclaims it) |

> ⚠️ In ERC721, `tokenId === 0` is a valid value and cannot be used to determine whether the red packet exists. You must use `cardExpire !== 0`.

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

> ⚠️ **Project (initiator) approval hygiene**: The NFT pool's push path (`onERC721Received`) only checks `from == initiator`. This `from` is filled in by the collection at call time — per the ERC721 standard, **any address that holds the initiator's `setApprovalForAll` approval on that collection** can push NFTs into the pool on the initiator's behalf and freely choose the `unlockAddress` and `lockTime`. If an attacker controls the device private key corresponding to that `unlockAddress`, this amounts to indirectly stealing the initiator's NFTs.
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

## Full Flow Diagram

```
app connects wallet
     │
     ▼
get unlockAddress (hardware device)
     │
     ▼
read cardTokenId / cardExpire / cardUnlockedAt ──→ display red packet NFT info
     │
     ▼
  claimable?
   ├── no → show "already claimed" or "does not exist"
   │
   └── yes
       │
       ▼
   validate that to can receive ERC721 (safeTransferFrom compatible)
       │
       ▼
   getWithdrawDigest(unlockAddress, to) ──→ digest
       │
       ▼
   send digest to hardware device to sign ──→ v, r, s
       │
       ▼
   submit withdraw(unlockAddress, to, v, r, s)
   ├── send transaction from own wallet
   └── hand off to a sponsor service (optional, purely business layer)
```

## Running the Example

| Variable | Required | Description |
|------|------|------|
| `POOL_ADDRESS` | Yes | HongBaoNFTPool contract address |
| `RPC_URL` | Yes | RPC node URL |

```bash
cd integration-examples
npm install
npm run example:nft
```
