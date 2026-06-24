import { createPublicClient, encodeAbiParameters, http, keccak256, parseAbi, type Address, type Hex } from 'viem';
import { mainnet } from 'viem/chains';

const HongBaoNFTPoolABI = parseAbi([
  // basics — apply to all cards
  'function lockedCollection() view returns (address)',
  'function initiator() view returns (address)',
  'function cardTokenId(address unlockAddress) view returns (uint256)',
  'function cardExpire(address unlockAddress) view returns (uint256)',
  'function cardUnlockedAt(address unlockAddress) view returns (uint256)',
  'function isLocked(address unlockAddress) view returns (bool)',
  'function isExpired(address unlockAddress) view returns (bool)',
  'function remainingLockTime(address unlockAddress) view returns (uint256)',
  'function getWithdrawDigest(address unlockAddress, address to) view returns (bytes32)',
  'function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s)',
  // task card surface (returns zero values on plain cards)
  'function cardTaskCount(address unlockAddress) view returns (uint8)',
  'function cardHasBasic(address unlockAddress) view returns (bool)',
  'function cardBoundTo(address unlockAddress) view returns (address)',
  'function cardClosed(address unlockAddress) view returns (bool)',
  'function task(address unlockAddress, uint8 taskIdx) view returns (bytes32 hash, uint256 tokenId, uint256 claimedAt)',
  'function computeTaskHash(address unlockAddress, uint8 taskIdx, bytes n) view returns (bytes32)',
  'function claimTask(address unlockAddress, uint8 taskIdx, bytes n)',
  // relayer-oriented batch entry points (skip-silently on per-entry failure)
  'function batchWithdraw(address[] unlockAddresses, address[] tos, uint8[] vs, bytes32[] rs, bytes32[] ss)',
  'function batchClaimTask(address[] unlockAddresses, uint8[] taskIdxs, bytes[] preimages)',
]);

// ERC721 metadata extension is OPTIONAL in the spec. Treat each call as fallible.
const erc721MetadataAbi = parseAbi([
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function tokenURI(uint256 tokenId) view returns (string)',
]);

// ============ Config ============

const POOL_ADDRESS = process.env.POOL_ADDRESS as Address;
const RPC_URL = process.env.RPC_URL;

// ============ Client ============

const publicClient = createPublicClient({
  chain: mainnet,
  transport: http(RPC_URL),
});

// ============ Read: hongbao status ============

// lockedCollection is immutable on the pool; cache it after the first read.
let cachedCollection: Address | undefined;

async function getLockedCollection(): Promise<Address> {
  if (!cachedCollection) {
    cachedCollection = await publicClient.readContract({
      address: POOL_ADDRESS,
      abi: HongBaoNFTPoolABI,
      functionName: 'lockedCollection',
    });
  }
  return cachedCollection;
}

export async function getHongbaoStatus(unlockAddress: Address) {
  const [collection, [tokenId, expire, unlockedAt, taskCount, hasBasic, boundTo, closed]] = await Promise.all([
    getLockedCollection(),
    publicClient.multicall({
      contracts: [
        { address: POOL_ADDRESS, abi: HongBaoNFTPoolABI, functionName: 'cardTokenId', args: [unlockAddress] },
        { address: POOL_ADDRESS, abi: HongBaoNFTPoolABI, functionName: 'cardExpire', args: [unlockAddress] },
        { address: POOL_ADDRESS, abi: HongBaoNFTPoolABI, functionName: 'cardUnlockedAt', args: [unlockAddress] },
        { address: POOL_ADDRESS, abi: HongBaoNFTPoolABI, functionName: 'cardTaskCount', args: [unlockAddress] },
        { address: POOL_ADDRESS, abi: HongBaoNFTPoolABI, functionName: 'cardHasBasic', args: [unlockAddress] },
        { address: POOL_ADDRESS, abi: HongBaoNFTPoolABI, functionName: 'cardBoundTo', args: [unlockAddress] },
        { address: POOL_ADDRESS, abi: HongBaoNFTPoolABI, functionName: 'cardClosed', args: [unlockAddress] },
      ],
      allowFailure: false,
    }),
  ]);

  // ERC721 tokenId === 0 is a legal value, so existence must be probed via expire.
  const exists = expire !== 0n;
  const isTaskCard = taskCount > 0;
  // Plain card: locked until withdraw. Task card: locked until closed (binding
  // still leaves slots claimable).
  const isLocked = exists && !closed && (isTaskCard || unlockedAt === 0n);

  if (!isLocked) {
    return {
      tokenId,
      expire,
      unlockedAt,
      collection,
      taskCount,
      closed,
      exists,
      isLocked: false,
      isExpired: false,
    } as const;
  }

  const now = BigInt(Math.floor(Date.now() / 1000));
  const isExpired = now >= expire;

  // ERC721 metadata is optional; tolerate per-call failure. For plain cards
  // and task cards with hasBasic, fetch tokenURI(tokenId); otherwise skip.
  const wantBasicURI = !isTaskCard || hasBasic;
  const [nameResult, symbolResult] = await publicClient.multicall({
    contracts: [
      { address: collection, abi: erc721MetadataAbi, functionName: 'name' },
      { address: collection, abi: erc721MetadataAbi, functionName: 'symbol' },
    ],
  });
  const [basicURIResult] = wantBasicURI
    ? await publicClient.multicall({
        contracts: [{ address: collection, abi: erc721MetadataAbi, functionName: 'tokenURI', args: [tokenId] }],
      })
    : [undefined];

  const base = {
    tokenId,
    expire,
    unlockedAt,
    collection,
    isLocked: true as const,
    isExpired,
    collectionName: nameResult.status === 'success' ? nameResult.result : undefined,
    collectionSymbol: symbolResult.status === 'success' ? symbolResult.result : undefined,
    tokenURI: basicURIResult && basicURIResult.status === 'success' ? basicURIResult.result : undefined,
  };

  if (!isTaskCard) {
    return { ...base, kind: 'plain' as const, exists: true as const };
  }

  // Task card: pull every slot in one multicall + per-slot tokenURI in another.
  const taskTuples = await publicClient.multicall({
    contracts: Array.from({ length: taskCount }, (_, i) => ({
      address: POOL_ADDRESS,
      abi: HongBaoNFTPoolABI,
      functionName: 'task' as const,
      args: [unlockAddress, i] as const,
    })),
    allowFailure: false,
  });

  const taskTokenURIs = await publicClient.multicall({
    contracts: taskTuples.map(([, slotTokenId]) => ({
      address: collection,
      abi: erc721MetadataAbi,
      functionName: 'tokenURI' as const,
      args: [slotTokenId] as const,
    })),
  });

  return {
    ...base,
    kind: 'task' as const,
    exists: true as const,
    taskCount,
    hasBasic,
    boundTo,
    closed,
    tasks: taskTuples.map(([hash, slotTokenId, claimedAt], i) => ({
      idx: i,
      hash,
      tokenId: slotTokenId,
      claimedAt,
      // Slot is claimable iff card is bound AND this slot is not yet claimed.
      // (Anyone can submit; the recipient is fixed by boundTo.)
      claimable: unlockedAt !== 0n && claimedAt === 0n,
      tokenURI: taskTokenURIs[i].status === 'success' ? taskTokenURIs[i].result : undefined,
    })),
  };
}

// ============ Read: withdraw digest ============

export async function getWithdrawDigest(unlockAddress: Address, to: Address) {
  return publicClient.readContract({
    address: POOL_ADDRESS,
    abi: HongBaoNFTPoolABI,
    functionName: 'getWithdrawDigest',
    args: [unlockAddress, to],
  });
}

// ============ Task card: commit hash + verify preimage ============

/**
 * Commit-hash formula used by HongBaoNFTPool: bound to (chainid, pool,
 * unlockAddress, taskIdx) so a preimage cannot be reused across chains /
 * pools / cards / slots. Mirrors `computeTaskHash` on the contract.
 */
export function computeTaskHashLocal(
  chainId: bigint | number,
  pool: Address,
  unlockAddress: Address,
  taskIdx: number,
  preimage: Hex,
): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'uint256' }, { type: 'address' }, { type: 'address' }, { type: 'uint8' }, { type: 'bytes' }],
      [BigInt(chainId), pool, unlockAddress, taskIdx, preimage],
    ),
  );
}

/**
 * Sanity-check a preimage against the on-chain committed hash before
 * spending gas on `claimTask`. Returns false if the slot is already claimed.
 */
export async function verifyPreimage(unlockAddress: Address, taskIdx: number, preimage: Hex): Promise<boolean> {
  const [hash, , claimedAt] = await publicClient.readContract({
    address: POOL_ADDRESS,
    abi: HongBaoNFTPoolABI,
    functionName: 'task',
    args: [unlockAddress, taskIdx],
  });
  if (claimedAt !== 0n) return false;
  const chainId = await publicClient.getChainId();
  const computed = computeTaskHashLocal(chainId, POOL_ADDRESS, unlockAddress, taskIdx, preimage);
  return computed === hash;
}

// ============ Write: submit withdraw ============
//
// `withdraw` has no caller restriction; any EOA can submit it. Two common paths are shown below.
//
// ⚠️ The NFT version requires checking up front that `to` can receive ERC721 (safeTransferFrom compatible).
//    For PLAIN cards the hardware device can sign each card only once; if you sign the wrong `to`, the card is bricked.
//    For TASK cards `to` becomes `boundTo` immutably — and EVERY task NFT will be sent there. A single non-receiver
//    `to` bricks both the basic AND every task slot on this card.

/**
 * Path A — submit on-chain directly with the App-side wallet.
 * The caller must pass in a viem walletClient.
 */
// export async function submitWithdrawOnchain(
//   walletClient: WalletClient,
//   unlockAddress: Address,
//   to: Address,
//   v: number,
//   r: Hex,
//   s: Hex,
// ): Promise<Hex> {
//   return walletClient.writeContract({
//     address: POOL_ADDRESS,
//     abi: HongBaoNFTPoolABI,
//     functionName: 'withdraw',
//     args: [unlockAddress, to, v, r, s],
//   });
// }

/**
 * Path B — hand off to the App backend's sponsor service.
 * The contract makes no distinction here; this layer is pure business logic.
 */
const SPONSOR_API = process.env.SPONSOR_API;

export async function submitWithdrawSponsored(unlockAddress: Address, to: Address, v: number, r: Hex, s: Hex) {
  if (!SPONSOR_API) throw new Error('SPONSOR_API not configured');
  const res = await fetch(`${SPONSOR_API}/api/withdrawal`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unlockAddress, to, v, r, s }),
  });
  if (!res.ok) {
    const err = await res.json();
    throw new Error(err.message);
  }
  return res.json();
}

// ============ Usage example ============

async function main() {
  if (!POOL_ADDRESS) {
    throw new Error('Set POOL_ADDRESS env var');
  }

  const unlockAddress: Address = '0x0000000000000000000000000000000000000001'; // TODO: replace
  const recipient: Address = '0x0000000000000000000000000000000000000002'; // TODO: replace

  // 1. Query the red packet status
  const status = await getHongbaoStatus(unlockAddress);

  if (!status.exists) {
    console.log('Hongbao does not exist');
    return;
  }
  if (!status.isLocked) {
    console.log('Hongbao not claimable (already withdrawn / closed / never existed)');
    return;
  }

  console.log(`Collection:   ${status.collection}`);
  console.log(`Name/Symbol:  ${status.collectionName ?? '-'} / ${status.collectionSymbol ?? '-'}`);
  console.log(`Expired:      ${status.isExpired}`);

  if (status.kind === 'plain') {
    console.log(`Plain card: tokenId=${status.tokenId}, tokenURI=${status.tokenURI ?? '-'}`);

    // 2. ⚠️ Before asking the device to sign, you must verify that `recipient` can receive ERC721.
    //    If it is a contract address, verify off-chain with IERC165.supportsInterface(0x150b7a02).

    // 3. Get the digest for the hardware to sign
    const digest = await getWithdrawDigest(unlockAddress, recipient);
    console.log(`Digest to sign: ${digest}`);

    // 4. Send the digest to the hardware device and get back v, r, s
    // const { v, r, s } = await hardwareSign(digest);

    // 5. Submit withdraw (Path A self-paid / Path B sponsored)
    // const txHash = await submitWithdrawOnchain(walletClient, unlockAddress, recipient, v, r, s);
    // or:
    // await submitWithdrawSponsored(unlockAddress, recipient, v, r, s);
    return;
  }

  // Task card branch
  console.log(`Task card: hasBasic=${status.hasBasic}, ${status.taskCount} task(s)`);
  console.log(
    `Bound to: ${status.boundTo === '0x0000000000000000000000000000000000000000' ? '(not yet)' : status.boundTo}`,
  );

  if (status.unlockedAt === 0n) {
    // Phase 1: bind. Same signature flow as plain card, but:
    //   - only the basic NFT (if hasBasic) comes out
    //   - `recipient` is permanently latched as `boundTo` and will receive ALL task NFTs
    // ⚠️ Verify `recipient` is ERC721-receiver-safe BEFORE signing — a non-receiver bricks the entire card.
    const digest = await getWithdrawDigest(unlockAddress, recipient);
    console.log(`Digest to sign (binds to=${recipient}): ${digest}`);
    // → hardware sign → submit withdraw → boundTo permanently locked
    return;
  }

  // Phase 2: claim tasks. boundTo already set; any caller can submit a valid preimage.
  for (const t of status.tasks) {
    if (!t.claimable) continue;
    // const preimage = await fetchPreimageFromProject(unlockAddress, t.idx);
    // if (!(await verifyPreimage(unlockAddress, t.idx, preimage))) throw new Error('bad preimage');
    // await walletClient.writeContract({
    //   address: POOL_ADDRESS,
    //   abi: HongBaoNFTPoolABI,
    //   functionName: 'claimTask',
    //   args: [unlockAddress, t.idx, preimage],
    // });
    console.log(`task[${t.idx}] claimable: tokenId=${t.tokenId}, tokenURI=${t.tokenURI ?? '-'}`);
  }
}

main().catch(console.error);
