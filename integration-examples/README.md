# HongBao Wallet App Integration Examples

This directory provides wallet app integration examples and documentation for the HongBao red packet contracts. Both variants share the same interaction model (**read card info → generate EIP-712 digest → sign with hardware device → submit withdraw**) and differ only in the underlying asset type.

## Contents

| Variant | Asset | Contract | Integration Doc | Example Code |
|------|------|------|----------|----------|
| Token | ERC20 | `HongBaoTokenPool` | [token/README.md](./token/README.md) | [token/viem](./token/viem/) |
| NFT   | ERC721 | `HongBaoNFTPool` | [nft/README.md](./nft/README.md) | [nft/viem](./nft/viem/) |

## Which One Should You Use?

- The project distributes fungible tokens (USDT, your own ERC20, etc.) → **Token**
- The project distributes individual NFTs (collectibles, tickets, whitelist credentials, etc.) → **NFT**

The two contract types are deployed independently by their respective factories (`HongBaoTokenFactory` / `HongBaoNFTFactory`) and have no dependency on each other.

## Shared Design

Whether using the Token or NFT version, the wallet app integrates following the same steps:

1. Read the `unlockAddress` (card address) from the hardware device
2. Call the pool's view functions to read card info (amount or tokenId, expiry, whether already claimed)
3. The user fills in the recipient address `to`, then call `getWithdrawDigest(unlockAddress, to)` to obtain a 32-byte digest
4. Send the digest to the hardware device to sign and obtain `(v, r, s)`
5. Any EOA submits `withdraw(unlockAddress, to, v, r, s)` — the contract does not restrict the caller

The EIP-712 schema is identical across both contracts:

```
Withdraw(address unlockAddress, address to)
Domain: name="HongBao", version="1", chainId, verifyingContract
```

The signing script and the local digest-packing logic can be reused across both variants.

## Key Differences

| Aspect | Token | NFT |
|------|-------|-----|
| Pool mode | Open / restricted (whether initiator is 0) | Restricted mode only |
| Multiple top-ups per card (topup) | Supported (plain card `basicAmount`) | Not supported |
| Task card support | Supported | Supported (basic + tasks fixed at creation; no topup) |
| Key card field | `cardTotal` (uint256) | `cardTokenId` (uint256) |
| Determining whether a card exists | `cardTotal != 0 \|\| cardUnlockedAt != 0` | `cardExpire != 0` (tokenId=0 is a valid value) |
| Asset contract entry point | `lockedToken()` | `lockedCollection()` |
| Withdraw transfer | `IERC20.transfer` | `IERC721.safeTransferFrom` |
| Task slot field | `task(addr, i) → (hash, amount, claimedAt)` | `task(addr, i) → (hash, tokenId, claimedAt)` |
| Recipient address `to` validation | No special requirements | **Must** be able to receive ERC721; validate before signing |
| Display metadata | `symbol()` / `decimals()` | `name()` / `symbol()` / `tokenURI()` (all optional) |

The most critical difference in the NFT version: the hardware device can sign each card only once. **Once you let the device sign for the wrong `to` (for example, a contract that cannot receive ERC721), the card is bricked** — the signature is already used up, but the on-chain asset cannot be transferred out. Integrators must validate `to` before letting the device sign. See Step 5 in [nft/README.md](./nft/README.md).

The NFT task card raises the stakes further: `boundTo` is permanently latched at bind time and **every** task NFT does its own `safeTransferFrom` to that address later — a non-receiver `boundTo` bricks not just one transfer but every future task slot on the card (per-slot, so other slots can still succeed if the issue is per-tokenId). See the Task Card section of [nft/README.md](./nft/README.md).

## Running the Example

```bash
cd integration-examples
npm install

npm run example:token             # Token variant (plain + task read demo)
npm run example:nft               # NFT variant (plain + task read demo)
npm run example:token-task-claim  # Token task-claim CLI (submit a preimage)
npm run example:nft-task-claim    # NFT task-claim CLI (submit a preimage)
```

Or run a specific script directly:

```bash
npx tsx nft/viem/src/withdraw-cli.ts
npx tsx nft/viem/src/task-claim-cli.ts
npx tsx token/viem/src/create-pool.ts
```

See each README for the required environment variables.
