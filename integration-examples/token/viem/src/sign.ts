/**
 * HongBao signing script — sign the withdraw digest with a private key using EIP-712
 *
 * For testing only: in a real scenario the private key for unlockAddress lives inside the hardware device.
 *
 * Environment variables:
 *   RPC_URL          — RPC node address
 *   POOL_ADDRESS     — HongBaoTokenPool contract address
 *   CARD_PRIVATE_KEY — private key of the card (unlockAddress)
 *   TO               — withdraw recipient address
 *
 * Usage:
 *   RPC_URL=http://127.0.0.1:8545 \
 *   POOL_ADDRESS=0x... \
 *   CARD_PRIVATE_KEY=0x... \
 *   TO=0x... \
 *     npx tsx src/sign.ts
 */

import { createPublicClient, http, parseAbi, type Address, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const HongBaoTokenPoolABI = parseAbi([
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
    abi: HongBaoTokenPoolABI,
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
