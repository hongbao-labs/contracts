/**
 * HongBao NFT Withdraw CLI
 *
 * 场景：用户手里有硬件卡，已在 App 内查过链上状态；现在想把 NFT 取到某个 `to` 地址。
 *
 * 硬件设备只接受 32 字节 digest。为避免"取款时再调一次 getWithdrawDigest"，
 * 我们让服务器在第一次查询卡信息时就把 EIP-712 所需的常量一并下发：
 *
 *   - DOMAIN_SEPARATOR   （每个 pool 一个，pool 部署时 immutable 固化）
 *   - WITHDRAW_TYPEHASH  （合约常量，与 ERC20 版本相同）
 *
 * 客户端本地打包 digest；再把 digest 发回服务器做交叉校验（服务器调 pool.getWithdrawDigest
 * 比对），防止本地打包被污染。校验通过后再送进硬件设备签名。
 *
 * ⚠️ NFT 特别注意事项：
 *   合约 withdraw 内部用 safeTransferFrom，`to` 必须能接收 ERC721。硬件设备每张卡
 *   只能签一次：如果 `to` 是合约且未实现 IERC721Receiver，签名用掉了，但 NFT 转不
 *   出去，这张卡事实上就报废了。本 CLI 在签名前应当做 `to` 白名单/合约接口校验。
 *
 * 运行：
 *   npx tsx src/withdraw-cli.ts
 */

import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import {
  createPublicClient,
  http,
  keccak256,
  encodeAbiParameters,
  concatHex,
  isAddress,
  parseAbi,
  type Address,
  type Hex,
} from 'viem';

// ============ Types ============

interface CardInfo {
  poolAddress: Address;
  unlockAddress: Address;
  domainSeparator: Hex;
  withdrawTypehash: Hex;
  collection: Address;
  tokenId: bigint;
  collectionName?: string;
  collectionSymbol?: string;
  tokenURI?: string;
  isExpired: boolean;
}

interface Signature {
  v: number;
  r: Hex;
  s: Hex;
}

// ============ Backend / device stubs (TODO) ============

/**
 * TODO: 调后端 `GET /api/card`。
 *
 * 请求时带上能唯一识别当前卡的凭据（设备 session / deviceId 之类，具体协议待定）。
 * 后端返回 CardInfo，其中 domainSeparator 与 withdrawTypehash 用于本地打包，
 * collection / tokenId / tokenURI 等用于 UI 展示。
 */
async function fetchCardInfo(): Promise<CardInfo> {
  throw new Error('TODO: implement backend GET /api/card');
}

/**
 * TODO: 调后端 `POST /api/verify-digest`。
 *
 * 请求体：{ poolAddress, unlockAddress, to, digest }
 * 后端调用 `pool.getWithdrawDigest(unlockAddress, to)` 并与客户端提交的 digest 比对，
 * 返回 { ok: boolean }。
 */
async function verifyDigestOnServer(_params: {
  poolAddress: Address;
  unlockAddress: Address;
  to: Address;
  digest: Hex;
}): Promise<boolean> {
  throw new Error('TODO: implement backend POST /api/verify-digest');
}

/**
 * TODO: 对接硬件设备传输层（USB / BLE / 其他），把 32 字节 digest 推给设备，
 * 设备本地用户确认后返回 (v, r, s)。
 */
async function hardwareSign(_digest: Hex): Promise<Signature> {
  throw new Error('TODO: implement hardware device signing');
}

/**
 * TODO: 提交 withdraw 交易。
 *
 * 两条路径任选：
 *   - 本地 walletClient 直接 writeContract(withdraw, ...)（见 src/index.ts）
 *   - POST 到代付服务（见 src/index.ts::submitWithdrawSponsored）
 */
async function submitWithdraw(_params: {
  poolAddress: Address;
  unlockAddress: Address;
  to: Address;
  signature: Signature;
}): Promise<Hex> {
  throw new Error('TODO: implement withdraw submission');
}

// ============ Local EIP-712 packing ============

// digest = keccak256(0x1901 || domainSeparator || keccak256(abi.encode(typehash, unlockAddress, to)))
export function computeWithdrawDigest(params: {
  withdrawTypehash: Hex;
  domainSeparator: Hex;
  unlockAddress: Address;
  to: Address;
}): { structHash: Hex; digest: Hex } {
  const structHash = keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'address' }, { type: 'address' }],
      [params.withdrawTypehash, params.unlockAddress, params.to],
    ),
  );

  const digest = keccak256(
    concatHex(['0x1901', params.domainSeparator, structHash]),
  );

  return { structHash, digest };
}

// ============ Recipient pre-check ============

const ERC165_ABI = parseAbi([
  'function supportsInterface(bytes4 interfaceId) view returns (bool)',
]);

const IERC721_RECEIVER_INTERFACE_ID = '0x150b7a02' as Hex;

/**
 * 在让设备签名之前，先粗略判断 `to` 是否能接收 ERC721。
 *
 *   - EOA（无 code）：safe，肯定能收
 *   - 合约：尝试 IERC165.supportsInterface(IERC721Receiver)；reverts 视为不安全
 *
 * 注意：这只是减少误用，不能 100% 替代真实交易模拟。如果对安全性要求高，
 * 应当再用 RPC 的 eth_call 模拟整个 withdraw。
 */
async function isRecipientSafe(rpcUrl: string, to: Address): Promise<{ ok: boolean; reason: string }> {
  const client = createPublicClient({ transport: http(rpcUrl) });

  const code = await client.getBytecode({ address: to });
  if (!code || code === '0x') {
    return { ok: true, reason: 'EOA' };
  }

  try {
    const supported = await client.readContract({
      address: to,
      abi: ERC165_ABI,
      functionName: 'supportsInterface',
      args: [IERC721_RECEIVER_INTERFACE_ID],
    });
    return supported
      ? { ok: true, reason: 'contract implements IERC721Receiver (per ERC165)' }
      : { ok: false, reason: 'contract does not advertise IERC721Receiver' };
  } catch {
    return { ok: false, reason: 'contract does not implement ERC165 — cannot prove receiver' };
  }
}

// ============ CLI ============

async function main() {
  const rpcUrl = process.env.RPC_URL;
  if (!rpcUrl) throw new Error('Set RPC_URL');

  const rl = createInterface({ input: stdin, output: stdout });

  try {
    console.log('=== HongBao NFT Withdraw ===\n');

    console.log('Fetching card info from backend...');
    const card = await fetchCardInfo();

    console.log(`Pool:         ${card.poolAddress}`);
    console.log(`Unlock addr:  ${card.unlockAddress}`);
    console.log(`Collection:   ${card.collection} (${card.collectionName ?? '-'} / ${card.collectionSymbol ?? '-'})`);
    console.log(`Token id:     ${card.tokenId}`);
    if (card.tokenURI) console.log(`Token URI:    ${card.tokenURI}`);
    if (card.isExpired) {
      console.log('(expired — still redeemable until project calls withdrawExpired)');
    }
    console.log();

    const to = (await rl.question('Recipient address (to): ')).trim();
    if (!isAddress(to)) throw new Error(`Invalid address: ${to}`);

    // ⚠️ 设备每张卡只能签一次。先校验 to。
    console.log('\nChecking recipient compatibility with ERC721 safeTransferFrom...');
    const safety = await isRecipientSafe(rpcUrl, to as Address);
    console.log(`  ${safety.ok ? 'OK' : 'WARN'}: ${safety.reason}`);
    if (!safety.ok) {
      const proceed = (await rl.question('Recipient may reject the NFT. Proceed anyway? [y/N] ')).trim().toLowerCase();
      if (proceed !== 'y') {
        console.log('Aborted. (No signature consumed.)');
        return;
      }
    }

    const { digest } = computeWithdrawDigest({
      withdrawTypehash: card.withdrawTypehash,
      domainSeparator: card.domainSeparator,
      unlockAddress: card.unlockAddress,
      to: to as Address,
    });
    console.log(`\nLocal digest: ${digest}`);

    console.log('Verifying digest with backend...');
    const ok = await verifyDigestOnServer({
      poolAddress: card.poolAddress,
      unlockAddress: card.unlockAddress,
      to: to as Address,
      digest,
    });
    if (!ok) throw new Error('digest mismatch — aborting');
    console.log('Verified.\n');

    console.log('Sending digest to hardware device — confirm on device...');
    console.log('(After this step the card cannot be re-signed for a different recipient.)');
    const signature = await hardwareSign(digest);
    console.log(`v: ${signature.v}`);
    console.log(`r: ${signature.r}`);
    console.log(`s: ${signature.s}\n`);

    console.log('Submitting withdraw...');
    const txHash = await submitWithdraw({
      poolAddress: card.poolAddress,
      unlockAddress: card.unlockAddress,
      to: to as Address,
      signature,
    });
    console.log(`Tx: ${txHash}`);
  } finally {
    rl.close();
  }
}

main().catch((err) => {
  console.error('[error]', err?.message ?? err);
  process.exit(1);
});
