/**
 * HongBao CreatePool — 通过 HongBaoTokenFactory 部署一个新 pool
 *
 * 对应合约调用：
 *   HongBaoTokenFactory.createPool(token, initiator) -> address pool
 *
 * 每一对 (token, initiator) 在一个 factory 下只能创建一次；重复调用会 revert。
 * pool 地址由 CREATE2 确定，可用 computePoolAddress 提前算出。
 *
 * 环境变量:
 *   RPC_URL           — RPC 节点地址
 *   PRIVATE_KEY       — 部署者私钥（付 gas）
 *   FACTORY_ADDRESS   — HongBaoTokenFactory 合约地址
 *   TOKEN             — 池锁定的 ERC20 代币地址
 *   INITIATOR         — 可选；传地址表示"仅该地址可存入"，
 *                       省略或传 0x000...0 表示开放池（任何人可存入）
 *
 * 用法:
 *   RPC_URL=... PRIVATE_KEY=0x... FACTORY_ADDRESS=0x... TOKEN=0x... \
 *     npx tsx src/create-pool.ts
 */

import { createPublicClient, createWalletClient, http, parseAbi, zeroAddress, type Address, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const HongBaoTokenFactoryABI = parseAbi([
  'function pools(address token, address initiator) view returns (address)',
  'function createPool(address token, address initiator) returns (address pool)',
  'function computePoolAddress(address token, address initiator) view returns (address)',
  'event PoolCreated(address indexed token, address indexed initiator, address pool)',
]);

function requireEnv(name: string): string {
  const val = process.env[name];
  if (!val) throw new Error(`Missing env: ${name}`);
  return val;
}

async function main() {
  const rpcUrl = requireEnv('RPC_URL');
  const privateKey = requireEnv('PRIVATE_KEY') as Hex;
  const factory = requireEnv('FACTORY_ADDRESS') as Address;
  const token = requireEnv('TOKEN') as Address;
  const initiator = (process.env.INITIATOR ?? zeroAddress) as Address;

  const account = privateKeyToAccount(privateKey);

  const publicClient = createPublicClient({ transport: http(rpcUrl) });
  const walletClient = createWalletClient({
    account,
    transport: http(rpcUrl),
  });

  // 1. 先查 registry，避免白白发一个会 revert 的 tx
  const existing = await publicClient.readContract({
    address: factory,
    abi: HongBaoTokenFactoryABI,
    functionName: 'pools',
    args: [token, initiator],
  });
  if (existing !== zeroAddress) {
    console.log('Pool already exists:', existing);
    return;
  }

  // 2. 预计算 CREATE2 地址（可用于前端展示 / 监听事件前的预提交）
  const predicted = await publicClient.readContract({
    address: factory,
    abi: HongBaoTokenFactoryABI,
    functionName: 'computePoolAddress',
    args: [token, initiator],
  });

  console.log('=== HongBao CreatePool ===');
  console.log('Factory:   ', factory);
  console.log('Token:     ', token);
  console.log('Initiator: ', initiator, initiator === zeroAddress ? '(open pool)' : '');
  console.log('Predicted: ', predicted);
  console.log();

  // 3. 发送创建交易
  const { request } = await publicClient.simulateContract({
    account,
    address: factory,
    abi: HongBaoTokenFactoryABI,
    functionName: 'createPool',
    args: [token, initiator],
  });

  const txHash = await walletClient.writeContract(request);
  console.log('Tx sent:   ', txHash);

  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log('Tx status: ', receipt.status);
  console.log('Gas used:  ', receipt.gasUsed.toString());

  // 4. 从 registry 读出最终地址并核对
  const deployed = await publicClient.readContract({
    address: factory,
    abi: HongBaoTokenFactoryABI,
    functionName: 'pools',
    args: [token, initiator],
  });
  console.log('Deployed:  ', deployed);

  if (deployed.toLowerCase() !== predicted.toLowerCase()) {
    throw new Error('Deployed address does not match predicted CREATE2 address');
  }
  console.log('Matches predicted address ✓');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
