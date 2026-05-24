#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HongBao end-to-end integration test

Full flow:
  1. Start the anvil local chain
  2. Deploy MockERC20 + HongBaoTokenPool (direct deployment + via HongBaoTokenFactory)
  3. Connect the STM32 device and obtain the card's Ethereum address
  4. Initiator deposits tokens, locked to the card address
  5. Obtain the withdraw digest from the contract
  6. Device signs the digest
  7. Test withdraw (full amount, anyone can submit)
  8. Test withdrawExpired (expired reclaim)
  9. Test batchDeposit
 10. Test signature-mismatch revert
 11. Test HongBaoTokenFactory.createPool + computePoolAddress

Dependencies: forge, cast, anvil (foundry), stm32_crypto_wrapper
"""

import os
import sys
import time
import secrets
import subprocess
import atexit

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
MAC_TOOL_DIR = os.path.join(ROOT_DIR, "mac_tool")

sys.path.insert(0, MAC_TOOL_DIR)
from stm32_crypto_wrapper import STM32CryptoWrapper, to_checksum_address

# Anvil's built-in public default accounts (derived from the mnemonic "test test test ... junk").
# These private keys are publicly known and are for local-chain testing only; they hold no real assets —— never send mainnet funds to these addresses.
DEPLOYER_PK = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER_ADDR = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
INITIATOR_PK = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
INITIATOR_ADDR = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
SUBMITTER_PK = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
SUBMITTER_ADDR = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
RECIPIENT_ADDR = "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"

ANVIL_PORT = "18545"
RPC = f"http://127.0.0.1:{ANVIL_PORT}"

# Must be >= MIN_LOCK_TIME (30 days) in HongBaoTokenPool.
LOCK_SECONDS = 30 * 24 * 60 * 60
WARP_SECONDS = LOCK_SECONDS + 1

anvil_proc = None


def cleanup():
    global anvil_proc
    if anvil_proc and anvil_proc.poll() is None:
        anvil_proc.terminate()
        anvil_proc.wait()


atexit.register(cleanup)


def run(cmd, **kwargs):
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=30,
        cwd=kwargs.pop("cwd", SCRIPT_DIR),
        **kwargs,
    )
    if result.returncode != 0:
        print(f"  CMD FAILED: {' '.join(cmd)}")
        if result.stdout.strip():
            print(f"  stdout: {result.stdout.strip()[:300]}")
        if result.stderr.strip():
            print(f"  stderr: {result.stderr.strip()[:300]}")
        raise RuntimeError(f"Command failed: {cmd[0]}")
    return result.stdout.strip()


def cast_call(contract, sig, *args):
    return run(["cast", "call", contract, sig, *args, "--rpc-url", RPC])


def cast_send(contract, sig, *args, pk=DEPLOYER_PK):
    return run(
        ["cast", "send", contract, sig, *args, "--rpc-url", RPC, "--private-key", pk]
    )


def _parse_uint(raw: str) -> int:
    raw = raw.strip()
    # cast may return the format "100000000000000000000 [1e20]"; take only the first segment
    num = raw.split()[0] if raw.split() else raw
    return int(num, 16) if num.startswith("0x") else int(num)


def get_balance(token_addr, who) -> int:
    return _parse_uint(cast_call(token_addr, "balanceOf(address)(uint256)", who))


def card_total(pool, card_addr) -> int:
    return _parse_uint(cast_call(pool, "cardTotal(address)(uint256)", card_addr))


def _free_port(port: str):
    r = subprocess.run(
        ["lsof", "-ti", f":{port}"],
        capture_output=True,
        text=True,
        timeout=5,
        cwd=SCRIPT_DIR,
    )
    if r.returncode != 0 or not r.stdout.strip():
        return
    for pid in r.stdout.strip().split():
        try:
            subprocess.run(["kill", "-9", pid], capture_output=True, timeout=2)
        except Exception:
            pass
    time.sleep(0.8)


def start_anvil():
    global anvil_proc
    print("[Setup] Starting anvil...")
    _free_port(ANVIL_PORT)
    try:
        anvil_proc = subprocess.Popen(
            ["anvil", "--silent", "--port", ANVIL_PORT],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=SCRIPT_DIR,
        )
    except FileNotFoundError:
        raise RuntimeError(
            "Anvil not found. Please install Foundry (foundry.toolchain) and ensure anvil is in PATH."
        )
    time.sleep(1.5)
    if anvil_proc.poll() is not None:
        try:
            out, err = anvil_proc.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            out, err = "", ""
        msg = "Anvil failed to start."
        if err and err.strip():
            msg += f" stderr: {err.strip()[:500]}"
        if out and out.strip():
            msg += f" stdout: {out.strip()[:500]}"
        raise RuntimeError(msg)
    print(f"  anvil pid={anvil_proc.pid}")


def deploy(contract_path, *constructor_args) -> str:
    cmd = [
        "forge",
        "create",
        contract_path,
        "--rpc-url",
        RPC,
        "--private-key",
        DEPLOYER_PK,
        "--broadcast",
    ]
    if constructor_args:
        cmd += ["--constructor-args", *constructor_args]
    output = run(cmd)
    for line in output.split("\n"):
        if "Deployed to:" in line:
            return line.split("Deployed to:")[-1].strip()
    raise RuntimeError(f"Deployment failed:\n{output}")


def fresh_pool_and_token(initiator=INITIATOR_ADDR):
    """Deploy fresh MockERC20 + HongBaoTokenPool, fund initiator."""
    token = deploy("test/mocks/MockERC20.sol:MockERC20", "TestToken", "TT", "18")
    pool = deploy(
        "src/HongBao/token/HongBaoTokenPool.sol:HongBaoTokenPool",
        token,
        initiator,
    )

    cast_send(token, "mint(address,uint256)", INITIATOR_ADDR, str(10000 * 10**18))
    cast_send(
        token,
        "approve(address,uint256)",
        pool,
        str(2**256 - 1),
        pk=INITIATOR_PK,
    )
    return pool, token


def deposit(pool, card_addr, amount_tt, lock_seconds=LOCK_SECONDS):
    cast_send(
        pool,
        "deposit(address,uint256,uint256)",
        card_addr,
        str(int(amount_tt * 10**18)),
        str(lock_seconds),
        pk=INITIATOR_PK,
    )


def batch_deposit(pool, addrs, amount_tt, lock_seconds=LOCK_SECONDS):
    addrs_arg = "[" + ",".join(addrs) + "]"
    cast_send(
        pool,
        "batchDeposit(address[],uint256,uint256)",
        addrs_arg,
        str(int(amount_tt * 10**18)),
        str(lock_seconds),
        pk=INITIATOR_PK,
    )


def get_digest(pool, card_addr, to):
    return cast_call(
        pool,
        "getWithdrawDigest(address,address)(bytes32)",
        card_addr,
        to,
    )


def random_address() -> str:
    return to_checksum_address("0x" + secrets.token_hex(20))


def print_header(n, title):
    print(f"\n{'=' * 60}")
    print(f"  Test {n}: {title}")
    print(f"{'=' * 60}")


def main():
    print("=" * 60)
    print("  HongBao E2E Test — STM32 Device + On-chain Contract")
    print("=" * 60)

    start_anvil()

    print("\n[Device] Connecting STM32...")
    crypto = STM32CryptoWrapper()
    crypto.connect()
    card_addr = to_checksum_address(crypto.get_ethereum_address())
    print(f"  Card address: {card_addr}")

    results = []

    # ================================================================
    # Test 1: withdraw — full amount, anyone can submit
    # ================================================================
    print_header(1, "withdraw — full amount, submitted by submitter (not the initiator)")

    pool, token = fresh_pool_and_token()
    deposit(pool, card_addr, 100)
    print("  Deposited 100 TT")

    digest = get_digest(pool, card_addr, RECIPIENT_ADDR)
    sig = crypto.sign_digest_ethereum(digest)
    print(f"  Signature: v={sig['v']}")

    bal_before = get_balance(token, RECIPIENT_ADDR)
    cast_send(
        pool,
        "withdraw(address,address,uint8,bytes32,bytes32)",
        card_addr,
        RECIPIENT_ADDR,
        str(sig["v"]),
        sig["r"],
        sig["s"],
        pk=SUBMITTER_PK,  # Note: not the initiator, nor a "relayer"; just an arbitrary third party
    )
    payout = get_balance(token, RECIPIENT_ADDR) - bal_before

    ok = payout == 100 * 10**18
    print(f"  Received: {payout / 10**18} TT → {'PASS' if ok else 'FAIL'}")
    results.append(("withdraw (full amount, submitted by anyone)", ok))

    # ================================================================
    # Test 2: withdrawExpired — expired reclaim
    # ================================================================
    print_header(2, "withdrawExpired — Initiator reclaims after expiry")

    pool, token = fresh_pool_and_token()
    bal_init_before = get_balance(token, INITIATOR_ADDR)
    deposit(pool, card_addr, 100, lock_seconds=LOCK_SECONDS)
    print(f"  Deposited 100 TT, lockTime={LOCK_SECONDS}s")

    run(["cast", "rpc", "evm_increaseTime", str(WARP_SECONDS), "--rpc-url", RPC])
    run(["cast", "rpc", "evm_mine", "--rpc-url", RPC])
    print(f"  Fast-forwarded {WARP_SECONDS} seconds")

    cast_send(pool, "withdrawExpired(address)", card_addr, pk=INITIATOR_PK)
    net = get_balance(token, INITIATOR_ADDR) - bal_init_before  # -100 + 100 = 0

    ok = net == 0
    print(f"  initiator net change: {net / 10**18} TT → {'PASS' if ok else 'FAIL'}")
    results.append(("withdrawExpired (full return)", ok))

    # ================================================================
    # Test 3: batchDeposit — batch deposit, then withdraw one of them with a signature
    # ================================================================
    print_header(3, "batchDeposit — 3 cards, then withdraw 1 of them")

    pool, token = fresh_pool_and_token()
    extra1 = random_address()
    extra2 = random_address()
    cards = [card_addr, extra1, extra2]
    batch_deposit(pool, cards, 100)
    print(f"  Batch-deposited 3 cards, 100 TT each")

    for c in cards:
        total = card_total(pool, c)
        assert total == 100 * 10**18, f"card {c} total mismatch: {total}"

    # withdraw can only be performed for card_addr, for which we hold the private key.
    digest = get_digest(pool, card_addr, RECIPIENT_ADDR)
    sig = crypto.sign_digest_ethereum(digest)

    bal_before = get_balance(token, RECIPIENT_ADDR)
    cast_send(
        pool,
        "withdraw(address,address,uint8,bytes32,bytes32)",
        card_addr,
        RECIPIENT_ADDR,
        str(sig["v"]),
        sig["r"],
        sig["s"],
        pk=SUBMITTER_PK,
    )
    payout = get_balance(token, RECIPIENT_ADDR) - bal_before

    # The other two cards should remain untouched.
    other_totals_ok = (
        card_total(pool, extra1) == 100 * 10**18
        and card_total(pool, extra2) == 100 * 10**18
    )

    ok = payout == 100 * 10**18 and other_totals_ok
    print(
        f"  Received: {payout / 10**18} TT, other two cards unaffected: {other_totals_ok} → {'PASS' if ok else 'FAIL'}"
    )
    results.append(("batchDeposit + single withdraw", ok))

    # ================================================================
    # Test 4: Invalid signature — should revert
    # ================================================================
    print_header(4, "Invalid signature — should revert")

    pool, token = fresh_pool_and_token()
    deposit(pool, card_addr, 100)

    # Signed for DEPLOYER_ADDR but submitted with RECIPIENT_ADDR → digest does not match
    wrong_digest = get_digest(pool, card_addr, DEPLOYER_ADDR)
    sig = crypto.sign_digest_ethereum(wrong_digest)

    try:
        cast_send(
            pool,
            "withdraw(address,address,uint8,bytes32,bytes32)",
            card_addr,
            RECIPIENT_ADDR,
            str(sig["v"]),
            sig["r"],
            sig["s"],
            pk=SUBMITTER_PK,
        )
        ok = False
        print("  Result: FAIL (should have reverted but succeeded)")
    except RuntimeError:
        ok = True
        print("  Result: PASS (correctly reverted)")
    results.append(("invalid signature revert", ok))

    # ================================================================
    # Test 5: HongBaoTokenFactory — deploy, predicted address matches actual deployment
    # ================================================================
    print_header(5, "HongBaoTokenFactory.createPool + computePoolAddress")

    token = deploy("test/mocks/MockERC20.sol:MockERC20", "FactoryToken", "FT", "18")
    factory = deploy("src/HongBao/token/HongBaoTokenFactory.sol:HongBaoTokenFactory")

    predicted_raw = cast_call(
        factory,
        "computePoolAddress(address,address)(address)",
        token,
        INITIATOR_ADDR,
    )
    predicted = predicted_raw.strip()

    cast_send(
        factory,
        "createPool(address,address)",
        token,
        INITIATOR_ADDR,
    )

    registered_raw = cast_call(
        factory,
        "pools(address,address)(address)",
        token,
        INITIATOR_ADDR,
    )
    registered = registered_raw.strip()

    ok = predicted.lower() == registered.lower() and int(registered, 16) != 0
    print(f"  Predicted: {predicted}")
    print(f"  Deployed:  {registered}")
    print(f"  Result: {'PASS' if ok else 'FAIL'}")
    results.append(("factory computePoolAddress == createPool", ok))

    # ================================================================
    # Summary
    # ================================================================
    crypto.close()

    print("\n" + "=" * 60)
    print("  Test results summary")
    print("=" * 60)
    all_pass = True
    for name, ok in results:
        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {name}")
        if not ok:
            all_pass = False

    print(f"\n  {sum(1 for _, o in results if o)}/{len(results)} passed")
    print("=" * 60)
    if not all_pass:
        sys.exit(1)


if __name__ == "__main__":
    main()
