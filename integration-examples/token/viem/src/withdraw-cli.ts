/**
 * HongBao Withdraw CLI
 *
 * 场景：用户手里有硬件卡，已在 App 内查过链上状态；现在想把钱取到某个 `to` 地址。
 *
 * 硬件设备只接受 32 字节 digest。为避免"取款时再调一次 getWithdrawDigest"，
 * 我们让服务器在第一次查询卡信息时就把 EIP-712 所需的常量一并下发：
 *
 *   - DOMAIN_SEPARATOR   （每个 pool 一个，pool 部署时 immutable 固化）
 *   - WITHDRAW_TYPEHASH  （合约常量）
 *
 * 客户端本地打包 digest；再把 digest 发回服务器做交叉校验（服务器调 pool.getWithdrawDigest
 * 比对），防止本地打包被污染。校验通过后再送进硬件设备签名。
 *
 * 运行：
 *   npx tsx src/withdraw-cli.ts
 */

import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import {
  keccak256,
  encodeAbiParameters,
  concatHex,
  isAddress,
  type Address,
  type Hex,
} from 'viem';

// ============ Types ============

interface CardInfo {
  poolAddress: Address;
  unlockAddress: Address;
  domainSeparator: Hex;
  withdrawTypehash: Hex;
  tokenSymbol: string;
  tokenDecimals: number;
  displayAmount: string;
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
 * displayAmount 等用于 UI 展示。
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

// ============ CLI ============

async function main() {
  const rl = createInterface({ input: stdin, output: stdout });

  try {
    console.log('=== HongBao Withdraw ===\n');

    console.log('Fetching card info from backend...');
    const card = await fetchCardInfo();

    console.log(`Pool:         ${card.poolAddress}`);
    console.log(`Unlock addr:  ${card.unlockAddress}`);
    console.log(`Balance:      ${card.displayAmount} ${card.tokenSymbol}`);
    if (card.isExpired) {
      console.log('(expired — still redeemable until project calls withdrawExpired)');
    }
    console.log();

    const to = (await rl.question('Recipient address (to): ')).trim();
    if (!isAddress(to)) throw new Error(`Invalid address: ${to}`);

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
