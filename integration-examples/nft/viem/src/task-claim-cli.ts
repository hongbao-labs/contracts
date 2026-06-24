/**
 * HongBao NFT Task Claim CLI
 *
 * Scenario: an NFT task card has already gone through the basic withdraw (`boundTo` is bound); now a task
 *           has been completed, the project has sent the preimage to the user, and `claimTask` needs to be
 *           submitted to transfer the task-slot NFT to boundTo.
 *
 * Differences from withdraw-cli.ts:
 *   - no hardware signature needed (claim verifies via preimage, not ECDSA)
 *   - **anyone** can submit it — the relevant user, a relayer, or a third party all work
 *   - the NFT is forcibly safeTransferFrom'd to `boundTo`; the submitter does not receive the NFT
 *   - ⚠️ if `boundTo` is not ERC721-receiver-safe, the slot's safeTransferFrom WILL revert — that one
 *     task NFT is bricked (still in the pool, still listed in the card, just unredeemable). Other slots
 *     and the basic NFT (already released at bind time) are unaffected. The initiator's `withdrawExpired`
 *     also reverts on the bricked slot, so the entire card stays "open" forever in the worst case.
 *
 * Flow:
 *   1. List all claimable slots (unclaimed && already-bound), show tokenURI per slot
 *   2. The user selects a slot
 *   3. Enter the preimage issued by the project (hex / any bytes string)
 *   4. Compute the hash locally and compare it with the on-chain commit → submit claimTask
 *
 * Environment variables:
 *   RPC_URL                — RPC node
 *   POOL_ADDRESS           — HongBaoNFTPool address
 *   UNLOCK_ADDRESS         — card address
 *   SUBMITTER_PRIVATE_KEY  — private key of the EOA used to send the transaction (anyone works)
 *
 * Usage:
 *   RPC_URL=... POOL_ADDRESS=0x... UNLOCK_ADDRESS=0x... SUBMITTER_PRIVATE_KEY=0x... \
 *     npx tsx src/task-claim-cli.ts
 */

import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import {
  createPublicClient,
  createWalletClient,
  encodeAbiParameters,
  http,
  keccak256,
  parseAbi,
  toHex,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const HongBaoNFTPoolABI = parseAbi([
  'function lockedCollection() view returns (address)',
  'function cardTaskCount(address unlockAddress) view returns (uint8)',
  'function cardBoundTo(address unlockAddress) view returns (address)',
  'function cardClosed(address unlockAddress) view returns (bool)',
  'function cardUnlockedAt(address unlockAddress) view returns (uint256)',
  'function task(address unlockAddress, uint8 taskIdx) view returns (bytes32 hash, uint256 tokenId, uint256 claimedAt)',
  'function claimTask(address unlockAddress, uint8 taskIdx, bytes n)',
]);

// ERC721 metadata is optional in the spec — read with allowFailure.
const erc721MetadataAbi = parseAbi(['function tokenURI(uint256 tokenId) view returns (string)']);

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}

function parsePreimage(input: string): Hex {
  const trimmed = input.trim();
  if (trimmed.startsWith('0x') || trimmed.startsWith('0X')) {
    if (trimmed.length % 2 !== 0) throw new Error('hex preimage has odd length');
    return trimmed as Hex;
  }
  // treat as utf-8 bytes
  return toHex(new TextEncoder().encode(trimmed));
}

function computeTaskHash(
  chainId: bigint | number,
  pool: Address,
  unlockAddress: Address,
  taskIdx: number,
  preimage: Hex,
): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'uint256' }, { type: 'address' }, { type: 'address' }, { type: 'uint8' }, { type: 'bytes' }],
      [BigInt(chainId), pool, unlockAddress, taskIdx, preimage],
    ),
  );
}

async function main() {
  const rpcUrl = requireEnv('RPC_URL');
  const pool = requireEnv('POOL_ADDRESS') as Address;
  const unlockAddress = requireEnv('UNLOCK_ADDRESS') as Address;
  const submitterKey = requireEnv('SUBMITTER_PRIVATE_KEY') as Hex;

  const account = privateKeyToAccount(submitterKey);
  const publicClient = createPublicClient({ transport: http(rpcUrl) });
  const walletClient = createWalletClient({ account, transport: http(rpcUrl) });

  const rl = createInterface({ input: stdin, output: stdout });

  try {
    console.log('=== HongBao NFT Task Claim ===\n');

    const [collection, taskCount, boundTo, closed, unlockedAt] = await Promise.all([
      publicClient.readContract({
        address: pool,
        abi: HongBaoNFTPoolABI,
        functionName: 'lockedCollection',
      }),
      publicClient.readContract({
        address: pool,
        abi: HongBaoNFTPoolABI,
        functionName: 'cardTaskCount',
        args: [unlockAddress],
      }),
      publicClient.readContract({
        address: pool,
        abi: HongBaoNFTPoolABI,
        functionName: 'cardBoundTo',
        args: [unlockAddress],
      }),
      publicClient.readContract({
        address: pool,
        abi: HongBaoNFTPoolABI,
        functionName: 'cardClosed',
        args: [unlockAddress],
      }),
      publicClient.readContract({
        address: pool,
        abi: HongBaoNFTPoolABI,
        functionName: 'cardUnlockedAt',
        args: [unlockAddress],
      }),
    ]);

    if (taskCount === 0) throw new Error('Not a task card (taskCount == 0)');
    if (closed) throw new Error('Card already closed by initiator — claims rejected');
    if (unlockedAt === 0n) throw new Error('Basic withdraw not done yet — boundTo not set');
    console.log(`Collection: ${collection}`);
    console.log(`boundTo:    ${boundTo} (recipient of all task NFTs)`);
    console.log();

    const tasks = await publicClient.multicall({
      contracts: Array.from({ length: taskCount }, (_, i) => ({
        address: pool,
        abi: HongBaoNFTPoolABI,
        functionName: 'task' as const,
        args: [unlockAddress, i] as const,
      })),
      allowFailure: false,
    });

    // Per-slot tokenURI — metadata is optional, allow failure.
    const uriResults = await publicClient.multicall({
      contracts: tasks.map(([, tokenId]) => ({
        address: collection,
        abi: erc721MetadataAbi,
        functionName: 'tokenURI' as const,
        args: [tokenId] as const,
      })),
    });

    let anyClaimable = false;
    tasks.forEach(([hash, tokenId, claimedAt], i) => {
      const status = claimedAt === 0n ? 'claimable' : 'claimed';
      const uri = uriResults[i].status === 'success' ? uriResults[i].result : '-';
      console.log(`  [${i}] tokenId=${tokenId}  hash=${hash}  ${status}`);
      console.log(`       tokenURI=${uri}`);
      if (claimedAt === 0n) anyClaimable = true;
    });
    if (!anyClaimable) {
      console.log('\nAll tasks already claimed.');
      return;
    }

    const idxStr = (await rl.question('\nTask index to claim: ')).trim();
    const idx = Number.parseInt(idxStr, 10);
    if (!Number.isInteger(idx) || idx < 0 || idx >= taskCount) throw new Error(`Invalid index: ${idxStr}`);
    const [hash, tokenId, claimedAt] = tasks[idx];
    if (claimedAt !== 0n) throw new Error('Slot already claimed');

    const raw = await rl.question('Preimage (hex 0x... or raw string): ');
    const preimage = parsePreimage(raw);

    const chainId = await publicClient.getChainId();
    const computed = computeTaskHash(chainId, pool, unlockAddress, idx, preimage);
    if (computed !== hash) {
      throw new Error(`Hash mismatch — local ${computed} vs on-chain ${hash}. Preimage is wrong.`);
    }
    console.log('\nHash matches. Submitting claim...');

    const txHash = await walletClient.writeContract({
      address: pool,
      abi: HongBaoNFTPoolABI,
      functionName: 'claimTask',
      args: [unlockAddress, idx, preimage],
    });

    console.log(`Tx: ${txHash}`);
    console.log(`(tokenId ${tokenId} will land at boundTo=${boundTo})`);
  } finally {
    rl.close();
  }
}

main().catch((err) => {
  console.error('[error]', err?.message ?? err);
  process.exit(1);
});
