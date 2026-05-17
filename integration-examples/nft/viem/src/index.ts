import { createPublicClient, http, parseAbi, type Address, type Hex } from 'viem';
import { mainnet } from 'viem/chains';

const HongBaoNFTPoolABI = parseAbi([
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
  const [collection, [tokenId, expire, unlockedAt]] = await Promise.all([
    getLockedCollection(),
    publicClient.multicall({
      contracts: [
        { address: POOL_ADDRESS, abi: HongBaoNFTPoolABI, functionName: 'cardTokenId', args: [unlockAddress] },
        { address: POOL_ADDRESS, abi: HongBaoNFTPoolABI, functionName: 'cardExpire', args: [unlockAddress] },
        { address: POOL_ADDRESS, abi: HongBaoNFTPoolABI, functionName: 'cardUnlockedAt', args: [unlockAddress] },
      ],
      allowFailure: false,
    }),
  ]);

  // ERC721 tokenId === 0 is a legal value, so existence must be probed via expire.
  const exists = expire !== 0n;
  const isLocked = exists && unlockedAt === 0n;

  if (!isLocked) {
    return { tokenId, expire, unlockedAt, collection, exists, isLocked: false, isExpired: false } as const;
  }

  const now = BigInt(Math.floor(Date.now() / 1000));
  const isExpired = now >= expire;

  // ERC721 metadata is optional; tolerate per-call failure.
  const [nameResult, symbolResult, tokenURIResult] = await publicClient.multicall({
    contracts: [
      { address: collection, abi: erc721MetadataAbi, functionName: 'name' },
      { address: collection, abi: erc721MetadataAbi, functionName: 'symbol' },
      { address: collection, abi: erc721MetadataAbi, functionName: 'tokenURI', args: [tokenId] },
    ],
  });

  return {
    tokenId,
    expire,
    unlockedAt,
    collection,
    exists: true,
    isLocked: true,
    isExpired,
    collectionName: nameResult.status === 'success' ? nameResult.result : undefined,
    collectionSymbol: symbolResult.status === 'success' ? symbolResult.result : undefined,
    tokenURI: tokenURIResult.status === 'success' ? tokenURIResult.result : undefined,
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

// ============ Write: submit withdraw ============
//
// `withdraw` 无调用者限制，任何 EOA 都能提交。以下展示两种常见路径。
//
// ⚠️ NFT 版本需要提前校验 `to` 能接收 ERC721 (safeTransferFrom 兼容)。
//    硬件设备每张卡只能签一次，签错了 to 这张卡就报废了。

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
//     abi: HongBaoNFTPoolABI,
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

  if (!status.exists) {
    console.log('Hongbao does not exist');
    return;
  }
  if (!status.isLocked) {
    console.log('Hongbao already claimed');
    return;
  }

  console.log(`Collection:   ${status.collection}`);
  console.log(`Name/Symbol:  ${status.collectionName ?? '-'} / ${status.collectionSymbol ?? '-'}`);
  console.log(`Token id:     ${status.tokenId}`);
  console.log(`Token URI:    ${status.tokenURI ?? '-'}`);
  console.log(`Expired:      ${status.isExpired}`);

  // 2. ⚠️ 让设备签名前必须先校验 `to` 能接收 ERC721。
  //    若是合约地址，建议 off-chain 用 IERC165.supportsInterface(0x150b7a02) 验证。

  // 3. 获取 digest 给硬件签名
  const digest = await getWithdrawDigest(unlockAddress, recipient);
  console.log(`Digest to sign: ${digest}`);

  // 4. 发送 digest 到硬件设备，拿到 v, r, s
  // const { v, r, s } = await hardwareSign(digest);

  // 5. 提交 withdraw（Path A 自付 / Path B 代付）
  // const txHash = await submitWithdrawOnchain(walletClient, unlockAddress, recipient, v, r, s);
  // or:
  // await submitWithdrawSponsored(unlockAddress, recipient, v, r, s);
}

main().catch(console.error);
