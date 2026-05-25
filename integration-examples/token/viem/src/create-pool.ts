/**
 * HongBao CreatePool — deploy a new pool via HongBaoTokenFactory
 *
 * Corresponding contract call:
 *   HongBaoTokenFactory.createPool(token, initiator) -> address pool
 *
 * Each (token, initiator) pair can be created only once under a given factory; a repeat call reverts.
 * The pool address is determined by CREATE2 and can be computed ahead of time with computePoolAddress.
 *
 * Environment variables:
 *   RPC_URL           — RPC node address
 *   PRIVATE_KEY       — deployer private key (pays gas)
 *   FACTORY_ADDRESS   — HongBaoTokenFactory contract address
 *   TOKEN             — address of the ERC20 token locked by the pool
 *   INITIATOR         — optional; passing an address means "only this address can deposit",
 *                       omitting it or passing 0x000...0 means an open pool (anyone can deposit)
 *
 * Usage:
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

  // 1. Check the registry first, to avoid wastefully sending a tx that would revert
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

  // 2. Pre-compute the CREATE2 address (usable for frontend display / pre-commit before listening for events)
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

  // 3. Send the creation transaction
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

  // 4. Read the final address from the registry and verify it
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
