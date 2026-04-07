/**
 * ForgePool 签名脚本 — 用私钥对 withdraw digest 进行 EIP-712 签名
 *
 * 环境变量:
 *   RPC_URL          — RPC 节点地址
 *   FORGEPOOL_ADDRESS — ForgePool 合约地址
 *   CARD_PRIVATE_KEY — 卡片（unlockAddress）的私钥
 *   TO               — 提款接收地址
 *   FEE_BPS          — 手续费比例（基点，如 200 = 2%）
 *
 * 用法:
 *   RPC_URL=http://127.0.0.1:8545 \
 *   FORGEPOOL_ADDRESS=0x... \
 *   CARD_PRIVATE_KEY=0x... \
 *   TO=0x... \
 *   FEE_BPS=200 \
 *     npx tsx src/sign.ts
 */

import {
  createPublicClient,
  http,
  parseAbi,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const ForgePoolABI = parseAbi([
  'function getWithdrawDigest(address unlockAddress, address to, uint256 feeBps) view returns (bytes32)',
]);

function requireEnv(name: string): string {
  const val = process.env[name];
  if (!val) throw new Error(`Missing env: ${name}`);
  return val;
}

async function main() {
  const rpcUrl = requireEnv('RPC_URL');
  const poolAddress = requireEnv('FORGEPOOL_ADDRESS') as Address;
  const cardPrivateKey = requireEnv('CARD_PRIVATE_KEY') as Hex;
  const to = requireEnv('TO') as Address;
  const feeBps = BigInt(requireEnv('FEE_BPS'));

  const account = privateKeyToAccount(cardPrivateKey);
  const unlockAddress = account.address;

  const client = createPublicClient({
    transport: http(rpcUrl),
  });

  const digest = await client.readContract({
    address: poolAddress,
    abi: ForgePoolABI,
    functionName: 'getWithdrawDigest',
    args: [unlockAddress, to, feeBps],
  });

  const signature = await account.signMessage({ message: { raw: digest } });

  // 拆分 signature 为 v, r, s
  const r = `0x${signature.slice(2, 66)}` as Hex;
  const s = `0x${signature.slice(66, 130)}` as Hex;
  const v = parseInt(signature.slice(130, 132), 16);

  console.log('unlockAddress:', unlockAddress);
  console.log('to:           ', to);
  console.log('feeBps:       ', feeBps.toString());
  console.log('digest:       ', digest);
  console.log('v:            ', v);
  console.log('r:            ', r);
  console.log('s:            ', s);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
