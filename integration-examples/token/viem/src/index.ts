import {
  createPublicClient,
  encodeAbiParameters,
  http,
  erc20Abi,
  keccak256,
  parseAbi,
  formatUnits,
  type Address,
  type Hex,
} from 'viem';
import { mainnet } from 'viem/chains';

const HongBaoTokenPoolABI = parseAbi([
  // basics — apply to all cards
  'function lockedToken() view returns (address)',
  'function initiator() view returns (address)',
  'function cardTotal(address unlockAddress) view returns (uint256)',
  'function cardExpire(address unlockAddress) view returns (uint256)',
  'function cardUnlockedAt(address unlockAddress) view returns (uint256)',
  'function isLocked(address unlockAddress) view returns (bool)',
  'function isExpired(address unlockAddress) view returns (bool)',
  'function remainingLockTime(address unlockAddress) view returns (uint256)',
  'function getWithdrawDigest(address unlockAddress, address to) view returns (bytes32)',
  'function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s)',
  // task card surface (returns zero values on plain cards)
  'function cardTaskCount(address unlockAddress) view returns (uint8)',
  'function cardBasicAmount(address unlockAddress) view returns (uint256)',
  'function cardBoundTo(address unlockAddress) view returns (address)',
  'function cardClosed(address unlockAddress) view returns (bool)',
  'function task(address unlockAddress, uint8 taskIdx) view returns (bytes32 hash, uint256 amount, uint256 claimedAt)',
  'function computeTaskHash(address unlockAddress, uint8 taskIdx, bytes n) view returns (bytes32)',
  'function claimTask(address unlockAddress, uint8 taskIdx, bytes n)',
  // relayer-oriented batch entry points (skip-silently on per-entry failure)
  'function batchWithdraw(address[] unlockAddresses, address[] tos, uint8[] vs, bytes32[] rs, bytes32[] ss)',
  'function batchClaimTask(address[] unlockAddresses, uint8[] taskIdxs, bytes[] preimages)',
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

export async function getHongbaoStatus(unlockAddress: Address) {
  const [total, expire, unlockedAt, token, taskCount, basicAmount, boundTo, closed] = await publicClient.multicall({
    contracts: [
      { address: POOL_ADDRESS, abi: HongBaoTokenPoolABI, functionName: 'cardTotal', args: [unlockAddress] },
      { address: POOL_ADDRESS, abi: HongBaoTokenPoolABI, functionName: 'cardExpire', args: [unlockAddress] },
      { address: POOL_ADDRESS, abi: HongBaoTokenPoolABI, functionName: 'cardUnlockedAt', args: [unlockAddress] },
      { address: POOL_ADDRESS, abi: HongBaoTokenPoolABI, functionName: 'lockedToken' },
      { address: POOL_ADDRESS, abi: HongBaoTokenPoolABI, functionName: 'cardTaskCount', args: [unlockAddress] },
      { address: POOL_ADDRESS, abi: HongBaoTokenPoolABI, functionName: 'cardBasicAmount', args: [unlockAddress] },
      { address: POOL_ADDRESS, abi: HongBaoTokenPoolABI, functionName: 'cardBoundTo', args: [unlockAddress] },
      { address: POOL_ADDRESS, abi: HongBaoTokenPoolABI, functionName: 'cardClosed', args: [unlockAddress] },
    ],
    allowFailure: false,
  });

  const isTaskCard = taskCount > 0;
  const isLocked = total > 0n && !closed && (isTaskCard || unlockedAt === 0n);

  if (!isLocked) {
    return { total, expire, unlockedAt, token, taskCount, closed, isLocked: false, isExpired: false } as const;
  }

  const now = BigInt(Math.floor(Date.now() / 1000));
  const isExpired = now >= expire;

  const [symbolResult, decimalsResult] = await publicClient.multicall({
    contracts: [
      { address: token, abi: erc20Abi, functionName: 'symbol' },
      { address: token, abi: erc20Abi, functionName: 'decimals' },
    ],
  });

  const symbol = symbolResult.result!;
  const decimals = decimalsResult.result!;

  const base = {
    total,
    expire,
    unlockedAt,
    token,
    isLocked: true as const,
    isExpired,
    tokenSymbol: symbol,
    tokenDecimals: decimals,
    displayAmount: formatUnits(total, decimals),
  };

  if (!isTaskCard) {
    return { ...base, kind: 'plain' as const };
  }

  const tasks = await Promise.all(
    Array.from({ length: taskCount }, (_, i) =>
      publicClient.readContract({
        address: POOL_ADDRESS,
        abi: HongBaoTokenPoolABI,
        functionName: 'task',
        args: [unlockAddress, i],
      }),
    ),
  );

  return {
    ...base,
    kind: 'task' as const,
    taskCount,
    basicAmount,
    basicDisplay: formatUnits(basicAmount, decimals),
    boundTo,
    closed,
    tasks: tasks.map(([hash, amount, claimedAt], i) => ({
      idx: i,
      hash,
      amount,
      amountDisplay: formatUnits(amount, decimals),
      claimedAt,
      claimable: unlockedAt !== 0n && claimedAt === 0n,
    })),
  };
}

// ============ Read: withdraw digest ============

export async function getWithdrawDigest(unlockAddress: Address, to: Address) {
  return publicClient.readContract({
    address: POOL_ADDRESS,
    abi: HongBaoTokenPoolABI,
    functionName: 'getWithdrawDigest',
    args: [unlockAddress, to],
  });
}

// ============ Task card: commit hash + verify preimage ============

/**
 * Commit-hash formula used by HongBaoTokenPool: bound to (chainid, pool,
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
    abi: HongBaoTokenPoolABI,
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
// `withdraw` 无调用者限制，任何 EOA 都能提交。以下展示两种常见路径。

/**
 * Path A — 用 App 侧钱包直接上链。
 * 使用处需传入一个 viem walletClient。
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
//     abi: HongBaoTokenPoolABI,
//     functionName: 'withdraw',
//     args: [unlockAddress, to, v, r, s],
//   });
// }

/**
 * Path B — 交给 App 后端的代付服务。
 * 合约层面不区分，这一层纯业务。
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

  // 1. 查询红包状态
  const status = await getHongbaoStatus(unlockAddress);

  if (!status.isLocked) {
    console.log('Hongbao not claimable (already claimed, closed, or does not exist)');
    return;
  }

  if (status.kind === 'plain') {
    console.log(`Plain card: ${status.displayAmount} ${status.tokenSymbol}, expired=${status.isExpired}`);
    // 2. 获取 digest 给硬件签名 → 提交 withdraw
    const digest = await getWithdrawDigest(unlockAddress, recipient);
    console.log(`Digest to sign: ${digest}`);
    // const { v, r, s } = await hardwareSign(digest);
    // await submitWithdrawSponsored(unlockAddress, recipient, v, r, s);
    return;
  }

  // Task card branch
  console.log(`Task card: basic=${status.basicDisplay} ${status.tokenSymbol}, ${status.taskCount} task(s)`);
  console.log(`Bound to: ${status.boundTo === '0x0000000000000000000000000000000000000000' ? '(not yet)' : status.boundTo}`);

  if (status.unlockedAt === 0n) {
    // Phase 1: bind. Same flow as plain card, but only basicAmount comes out and the card stays active.
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
    //   abi: HongBaoTokenPoolABI,
    //   functionName: 'claimTask',
    //   args: [unlockAddress, t.idx, preimage],
    // });
    console.log(`task[${t.idx}] claimable for ${t.amountDisplay} ${status.tokenSymbol}`);
  }
}

main().catch(console.error);
