/**
 * HongBao NFT 签名脚本 — 用私钥对 withdraw digest 进行 EIP-712 签名
 *
 * 仅用于测试：真实场景下 unlockAddress 对应的私钥存在硬件设备里。
 *
 * EIP-712 schema 与 ERC20 版本完全相同：
 *   Withdraw(address unlockAddress, address to)
 * 因此该脚本与 token 版仅有 ABI 名称不同，签名流程一致。
 *
 * 环境变量:
 *   RPC_URL          — RPC 节点地址
 *   POOL_ADDRESS     — HongBaoNFTPool 合约地址
 *   CARD_PRIVATE_KEY — 卡片（unlockAddress）的私钥
 *   TO               — 提款接收地址（必须能接收 ERC721）
 *
 * 用法:
 *   RPC_URL=http://127.0.0.1:8545 \
 *   POOL_ADDRESS=0x... \
 *   CARD_PRIVATE_KEY=0x... \
 *   TO=0x... \
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

const HongBaoNFTPoolABI = parseAbi([
  'function getWithdrawDigest(address unlockAddress, address to) view returns (bytes32)',
]);

function requireEnv(name: string): string {
  const val = process.env[name];
  if (!val) throw new Error(`Missing env: ${name}`);
  return val;
}

async function main() {
  const rpcUrl = requireEnv('RPC_URL');
  const poolAddress = requireEnv('POOL_ADDRESS') as Address;
  const cardPrivateKey = requireEnv('CARD_PRIVATE_KEY') as Hex;
  const to = requireEnv('TO') as Address;

  const account = privateKeyToAccount(cardPrivateKey);
  const unlockAddress = account.address;

  const client = createPublicClient({
    transport: http(rpcUrl),
  });

  const digest = await client.readContract({
    address: poolAddress,
    abi: HongBaoNFTPoolABI,
    functionName: 'getWithdrawDigest',
    args: [unlockAddress, to],
  });

  const signature = await account.sign({ hash: digest });

  const r = `0x${signature.slice(2, 66)}` as Hex;
  const s = `0x${signature.slice(66, 130)}` as Hex;
  const v = parseInt(signature.slice(130, 132), 16);

  console.log('unlockAddress:', unlockAddress);
  console.log('to:           ', to);
  console.log('digest:       ', digest);
  console.log('v:            ', v);
  console.log('r:            ', r);
  console.log('s:            ', s);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
