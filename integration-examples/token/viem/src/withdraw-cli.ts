/**
 * HongBao Withdraw CLI
 *
 * Scenario: the user holds a hardware card and has already checked its on-chain status in the App;
 *           now they want to withdraw the funds to some `to` address.
 *
 * The hardware device only accepts a 32-byte digest. To avoid "calling getWithdrawDigest again at
 * withdraw time", we have the server deliver the constants needed for EIP-712 together with the first
 * card-info query:
 *
 *   - DOMAIN_SEPARATOR   (one per pool, fixed as immutable when the pool is deployed)
 *   - WITHDRAW_TYPEHASH  (a contract constant)
 *
 * The client packs the digest locally; it then sends the digest back to the server for a cross-check
 * (the server calls pool.getWithdrawDigest and compares), to prevent the local packing from being
 * tampered with. Only after the check passes is it sent into the hardware device for signing.
 *
 * Run:
 *   npx tsx src/withdraw-cli.ts
 */

import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import { keccak256, encodeAbiParameters, concatHex, isAddress, type Address, type Hex } from 'viem';

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
 * TODO: call the backend `GET /api/card`.
 *
 * Include credentials that uniquely identify the current card in the request (device session / deviceId
 * or similar; the exact protocol is TBD).
 * The backend returns CardInfo, where domainSeparator and withdrawTypehash are used for local packing,
 * and displayAmount etc. are used for UI display.
 */
async function fetchCardInfo(): Promise<CardInfo> {
  throw new Error('TODO: implement backend GET /api/card');
}

/**
 * TODO: call the backend `POST /api/verify-digest`.
 *
 * Request body: { poolAddress, unlockAddress, to, digest }
 * The backend calls `pool.getWithdrawDigest(unlockAddress, to)` and compares it against the digest
 * submitted by the client, returning { ok: boolean }.
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
 * TODO: integrate with the hardware device transport layer (USB / BLE / other), push the 32-byte digest
 * to the device, and return (v, r, s) after the user confirms locally on the device.
 */
async function hardwareSign(_digest: Hex): Promise<Signature> {
  throw new Error('TODO: implement hardware device signing');
}

/**
 * TODO: submit the withdraw transaction.
 *
 * Choose either of two paths:
 *   - local walletClient calling writeContract(withdraw, ...) directly (see src/index.ts)
 *   - POST to the sponsor service (see src/index.ts::submitWithdrawSponsored)
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

  const digest = keccak256(concatHex(['0x1901', params.domainSeparator, structHash]));

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
