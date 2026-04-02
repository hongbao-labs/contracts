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

const ForgePoolABI = parseAbi([
  'function getDepositInfo(address unlockAddress) view returns ((address initiator, address unlockAddress, address token, uint256 amount, uint256 lockTime, uint256 mintTimeStamp, uint256 expire, uint256 unlockedAt))',
  'function getWithdrawDigest(address unlockAddress, address to, uint256 feeBps) view returns (bytes32)',
  'function getFeeRange() view returns (uint256 minFeeBps, uint256 maxFeeBps)',
  'function withdrawFromCard(address unlockAddress, address to, uint256 feeBps, uint8 v, bytes32 r, bytes32 s)',
]);

// ============ Config ============

const FORGEPOOL_ADDRESS = process.env.FORGEPOOL_ADDRESS as Address;
const RPC_URL = process.env.RPC_URL;

// ============ Client ============

const publicClient = createPublicClient({
  chain: mainnet,
  transport: http(RPC_URL),
});

// ============ Read: hongbao status ============

export async function getHongbaoStatus(unlockAddress: Address) {
  const info = await publicClient.readContract({
    address: FORGEPOOL_ADDRESS,
    abi: ForgePoolABI,
    functionName: 'getDepositInfo',
    args: [unlockAddress],
  });

  const isLocked = info.amount > 0n && info.unlockedAt === 0n;

  if (!isLocked) {
    return { info, isLocked: false, isExpired: false } as const;
  }

  const now = BigInt(Math.floor(Date.now() / 1000));
  const isExpired = now >= info.expire;

  const [symbolResult, decimalsResult] = await publicClient.multicall({
    contracts: [
      { address: info.token, abi: erc20Abi, functionName: 'symbol' },
      { address: info.token, abi: erc20Abi, functionName: 'decimals' },
    ],
  });

  const symbol = symbolResult.result!;
  const decimals = decimalsResult.result!;

  return {
    info,
    isLocked: true,
    isExpired,
    tokenSymbol: symbol,
    tokenDecimals: decimals,
    displayAmount: formatUnits(info.amount, decimals),
  };
}

// ============ Read: withdraw digest ============

export async function getWithdrawDigest(
  unlockAddress: Address,
  to: Address,
  feeBps: bigint,
) {
  return publicClient.readContract({
    address: FORGEPOOL_ADDRESS,
    abi: ForgePoolABI,
    functionName: 'getWithdrawDigest',
    args: [unlockAddress, to, feeBps],
  });
}

// ============ Read: fee range ============

export async function getFeeRange() {
  const [minFeeBps, maxFeeBps] = await publicClient.readContract({
    address: FORGEPOOL_ADDRESS,
    abi: ForgePoolABI,
    functionName: 'getFeeRange',
  });
  return { minFeeBps, maxFeeBps };
}

// ============ Write: submit to relayer ============

const RELAYER_API = process.env.RELAYER_API!;

export async function submitWithdrawal(
  unlockAddress: Address,
  to: Address,
  feeBps: number,
  v: number,
  r: Hex,
  s: Hex,
) {
  const res = await fetch(`${RELAYER_API}/api/withdrawal`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unlockAddress, to, feeBps, v, r, s }),
  });
  if (!res.ok) {
    const err = await res.json();
    throw new Error(err.message);
  }
  return res.json();
}

export async function getWithdrawalStatus(unlockAddress: Address) {
  const res = await fetch(`${RELAYER_API}/api/withdrawal/${unlockAddress}`);
  return res.json();
}

// ============ Usage example ============

async function main() {
  if (!FORGEPOOL_ADDRESS) {
    throw new Error('Set FORGEPOOL_ADDRESS env var');
  }

  const unlockAddress: Address = '0x0000000000000000000000000000000000000001'; // TODO: replace
  const recipient: Address = '0x0000000000000000000000000000000000000002'; // TODO: replace

  // 1. Query hongbao status
  const status = await getHongbaoStatus(unlockAddress);

  if (!status.isLocked) {
    console.log('Hongbao already claimed or does not exist');
    return;
  }

  console.log(`Hongbao: ${status.displayAmount} ${status.tokenSymbol}`);
  console.log(`Expired: ${status.isExpired}`);

  // 2. Get digest for hardware signing
  const { minFeeBps } = await getFeeRange();
  const digest = await getWithdrawDigest(unlockAddress, recipient, minFeeBps);
  console.log(`Digest to sign: ${digest}`);

  // 3. Send digest to hardware device, get back v, r, s
  // const { v, r, s } = await hardwareSign(digest);

  // 4. Submit to relayer
  // await submitWithdrawal(unlockAddress, recipient, Number(minFeeBps), v, r, s);

  // 5. Poll withdrawal status
  // const status = await getWithdrawalStatus(unlockAddress);
  // console.log(status);
}

main().catch(console.error);
