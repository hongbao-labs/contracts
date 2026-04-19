#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HongBao 端到端集成测试

完整流程：
  1. 启动 anvil 本地链
  2. 部署 MockERC20 + HongBaoTokenPool（直接部署 + 通过 HongBaoTokenFactory）
  3. 连接 STM32 设备，获取卡片以太坊地址
  4. Initiator 存入代币，锁定到卡片地址
  5. 从合约获取 withdraw digest
  6. 设备签名 digest
  7. 测试 withdraw（全额，任何人可提交）
  8. 测试 withdrawExpired（过期取回）
  9. 测试 batchDeposit
 10. 测试签名不匹配 revert
 11. 测试 HongBaoTokenFactory.createPool + computePoolAddress

依赖: forge, cast, anvil (foundry), stm32_crypto_wrapper
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

# Anvil 默认账户
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
    # cast 可能返回 "100000000000000000000 [1e20]" 格式，只取首段
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
    print("[Setup] 启动 anvil...")
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
            "Anvil 未找到。请安装 Foundry (foundry.toolchain) 并确保 anvil 在 PATH 中。"
        )
    time.sleep(1.5)
    if anvil_proc.poll() is not None:
        try:
            out, err = anvil_proc.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            out, err = "", ""
        msg = "Anvil 启动失败。"
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
    raise RuntimeError(f"部署失败:\n{output}")


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

    print("\n[Device] 连接 STM32...")
    crypto = STM32CryptoWrapper()
    crypto.connect()
    card_addr = to_checksum_address(crypto.get_ethereum_address())
    print(f"  卡片地址: {card_addr}")

    results = []

    # ================================================================
    # Test 1: withdraw — 全额，任何人可提交
    # ================================================================
    print_header(1, "withdraw — 全额，由 submitter（非 initiator）提交")

    pool, token = fresh_pool_and_token()
    deposit(pool, card_addr, 100)
    print("  存入 100 TT")

    digest = get_digest(pool, card_addr, RECIPIENT_ADDR)
    sig = crypto.sign_digest_ethereum(digest)
    print(f"  签名: v={sig['v']}")

    bal_before = get_balance(token, RECIPIENT_ADDR)
    cast_send(
        pool,
        "withdraw(address,address,uint8,bytes32,bytes32)",
        card_addr,
        RECIPIENT_ADDR,
        str(sig["v"]),
        sig["r"],
        sig["s"],
        pk=SUBMITTER_PK,  # 注意：非 initiator，也非 "relayer"，就是任意第三方
    )
    payout = get_balance(token, RECIPIENT_ADDR) - bal_before

    ok = payout == 100 * 10**18
    print(f"  到账: {payout / 10**18} TT → {'PASS' if ok else 'FAIL'}")
    results.append(("withdraw (full amount, submitted by anyone)", ok))

    # ================================================================
    # Test 2: withdrawExpired — 过期取回
    # ================================================================
    print_header(2, "withdrawExpired — 过期后 Initiator 取回")

    pool, token = fresh_pool_and_token()
    bal_init_before = get_balance(token, INITIATOR_ADDR)
    deposit(pool, card_addr, 100, lock_seconds=LOCK_SECONDS)
    print(f"  存入 100 TT, lockTime={LOCK_SECONDS}s")

    run(["cast", "rpc", "evm_increaseTime", str(WARP_SECONDS), "--rpc-url", RPC])
    run(["cast", "rpc", "evm_mine", "--rpc-url", RPC])
    print(f"  快进 {WARP_SECONDS} 秒")

    cast_send(pool, "withdrawExpired(address)", card_addr, pk=INITIATOR_PK)
    net = get_balance(token, INITIATOR_ADDR) - bal_init_before  # -100 + 100 = 0

    ok = net == 0
    print(f"  initiator 净变化: {net / 10**18} TT → {'PASS' if ok else 'FAIL'}")
    results.append(("withdrawExpired (full return)", ok))

    # ================================================================
    # Test 3: batchDeposit — 批量存款，随后用签名提取其中一张
    # ================================================================
    print_header(3, "batchDeposit — 3 张卡，随后 withdraw 其中 1 张")

    pool, token = fresh_pool_and_token()
    extra1 = random_address()
    extra2 = random_address()
    cards = [card_addr, extra1, extra2]
    batch_deposit(pool, cards, 100)
    print(f"  批量存入 3 张卡，每张 100 TT")

    for c in cards:
        total = card_total(pool, c)
        assert total == 100 * 10**18, f"card {c} total mismatch: {total}"

    # 只能对有私钥的 card_addr 执行 withdraw。
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

    # 其它两张卡应原封不动。
    other_totals_ok = (
        card_total(pool, extra1) == 100 * 10**18
        and card_total(pool, extra2) == 100 * 10**18
    )

    ok = payout == 100 * 10**18 and other_totals_ok
    print(
        f"  到账: {payout / 10**18} TT, 其它两张卡未受影响: {other_totals_ok} → {'PASS' if ok else 'FAIL'}"
    )
    results.append(("batchDeposit + single withdraw", ok))

    # ================================================================
    # Test 4: Invalid signature — 应 revert
    # ================================================================
    print_header(4, "Invalid signature — 应 revert")

    pool, token = fresh_pool_and_token()
    deposit(pool, card_addr, 100)

    # 签给 DEPLOYER_ADDR 但提交时传 RECIPIENT_ADDR → digest 对不上
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
        print("  结果: FAIL (应 revert 但成功了)")
    except RuntimeError:
        ok = True
        print("  结果: PASS (正确 revert)")
    results.append(("invalid signature revert", ok))

    # ================================================================
    # Test 5: HongBaoTokenFactory — 部署、预测地址、实际部署一致
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
    print(f"  结果: {'PASS' if ok else 'FAIL'}")
    results.append(("factory computePoolAddress == createPool", ok))

    # ================================================================
    # Summary
    # ================================================================
    crypto.close()

    print("\n" + "=" * 60)
    print("  测试结果汇总")
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
