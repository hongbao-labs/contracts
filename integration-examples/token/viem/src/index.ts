import {
  createPublicClient,
  http,
  erc20Abi,
  parseAbi,
  formatUnits,
  type Address,
  type Hex,
} from 'viem';
import { mainnet } from 'viem/chains';

const HongBaoTokenPoolABI = parseAbi([
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
  const [total, expire, unlockedAt, token] = await publicClient.multicall({
    contracts: [
      { address: POOL_ADDRESS, abi: HongBaoTokenPoolABI, functionName: 'cardTotal', args: [unlockAddress] },
      { address: POOL_ADDRESS, abi: HongBaoTokenPoolABI, functionName: 'cardExpire', args: [unlockAddress] },
      { address: POOL_ADDRESS, abi: HongBaoTokenPoolABI, functionName: 'cardUnlockedAt', args: [unlockAddress] },
      { address: POOL_ADDRESS, abi: HongBaoTokenPoolABI, functionName: 'lockedToken' },
    ],
    allowFailure: false,
  });

  const isLocked = total > 0n && unlockedAt === 0n;

  if (!isLocked) {
    return { total, expire, unlockedAt, token, isLocked: false, isExpired: false } as const;
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

  return {
    total,
    expire,
    unlockedAt,
    token,
    isLocked: true,
    isExpired,
    tokenSymbol: symbol,
    tokenDecimals: decimals,
    displayAmount: formatUnits(total, decimals),
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

export async function submitWithdrawSponsored(
  unlockAddress: Address,
  to: Address,
  v: number,
  r: Hex,
  s: Hex,
) {
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
    console.log('Hongbao already claimed or does not exist');
    return;
  }

  console.log(`Hongbao: ${status.displayAmount} ${status.tokenSymbol}`);
  console.log(`Expired: ${status.isExpired}`);

  // 2. 获取 digest 给硬件签名
  const digest = await getWithdrawDigest(unlockAddress, recipient);
  console.log(`Digest to sign: ${digest}`);

  // 3. 发送 digest 到硬件设备，拿到 v, r, s
  // const { v, r, s } = await hardwareSign(digest);

  // 4. 提交 withdraw（Path A 自付 / Path B 代付）
  // const txHash = await submitWithdrawOnchain(walletClient, unlockAddress, recipient, v, r, s);
  // or:
  // await submitWithdrawSponsored(unlockAddress, recipient, v, r, s);
}

main().catch(console.error);
