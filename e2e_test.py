#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ForgePool 端到端集成测试

完整流程：
  1. 启动 anvil 本地链
  2. 部署 MockERC20 + ForgePool
  3. 连接 STM32 设备，获取卡片以太坊地址
  4. Initiator 存入代币，锁定到卡片地址
  5. 从合约获取 withdraw digest
  6. 设备签名 digest
  7. 测试 withdrawFromCard（全额，无手续费）
  8. 测试 withdrawFromCardByRelayer（扣手续费）
  9. 测试 withdrawExpired（过期取回）
 10. 测试 batchWithdrawFromCardByRelayer
 11. 测试签名不匹配 revert

依赖: forge, cast, anvil (foundry), stm32_crypto_wrapper
"""

import os
import sys
import time
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
RELAYER_PK = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
RELAYER_ADDR = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
FEE_RECIPIENT = "0x90F79bf6EB2c4f870365E785982E1f101E93b906"
RECIPIENT_ADDR = "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"

ANVIL_PORT = "18545"
RPC = f"http://127.0.0.1:{ANVIL_PORT}"

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


def get_balance(token_addr, who) -> int:
    raw = cast_call(token_addr, "balanceOf(address)(uint256)", who).strip()
    # cast 可能返回 "100000000000000000000 [1e20]" 格式，只取数字部分
    num_part = raw.split()[0] if raw.split() else raw
    return int(num_part, 16) if num_part.startswith("0x") else int(num_part)


def _free_port(port: str):
    """若端口被占用则终止占用进程（便于上次未退出的 anvil 释放端口）。"""
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
        if not (err and err.strip()) and not (out and out.strip()):
            msg += f" 可能原因: 端口 {ANVIL_PORT} 已被占用，或 anvil 未正确安装。"
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


def fresh_pool_and_token():
    """Deploy fresh MockERC20 + ForgePool, configure for testing."""
    token = deploy("test/mocks/MockERC20.sol:MockERC20", "TestToken", "TT", "18")
    pool = deploy("src/Agora/ForgePool.sol:ForgePool", FEE_RECIPIENT)

    # Mint, approve, add relayer, set minLockTime=10s
    cast_send(token, "mint(address,uint256)", INITIATOR_ADDR, str(10000 * 10**18))
    cast_send(token, "approve(address,uint256)", pool, str(2**256 - 1), pk=INITIATOR_PK)
    cast_send(pool, "addRelayer(address)", RELAYER_ADDR)
    cast_send(pool, "setMinLockTime(uint256)", "10")

    return pool, token


def deposit(pool, token, card_addr, amount_tt, lock_seconds=60):
    cast_send(
        pool,
        "deposit(address,address,uint256,uint256)",
        card_addr,
        token,
        str(int(amount_tt * 10**18)),
        str(lock_seconds),
        pk=INITIATOR_PK,
    )


def get_digest(pool, card_addr, to, fee_bps):
    return cast_call(
        pool,
        "getWithdrawDigest(address,address,uint256)(bytes32)",
        card_addr,
        to,
        str(fee_bps),
    )


def print_header(n, title):
    print(f"\n{'=' * 60}")
    print(f"  Test {n}: {title}")
    print(f"{'=' * 60}")


def main():
    print("=" * 60)
    print("  ForgePool E2E Test — STM32 Device + On-chain Contract")
    print("=" * 60)

    start_anvil()

    # Connect device
    print("\n[Device] 连接 STM32...")
    crypto = STM32CryptoWrapper()
    crypto.connect()
    card_addr = to_checksum_address(crypto.get_ethereum_address())
    print(f"  卡片地址: {card_addr}")

    results = []
    FEE_BPS = 200  # 2%

    # ================================================================
    # Test 1: withdrawFromCard — 全额，无手续费
    # ================================================================
    print_header(1, "withdrawFromCard — 全额无手续费")

    pool, token = fresh_pool_and_token()
    deposit(pool, token, card_addr, 100)
    print("  存入 100 TT")

    digest = get_digest(pool, card_addr, RECIPIENT_ADDR, FEE_BPS)
    sig = crypto.sign_digest_ethereum(digest)
    print(f"  签名: v={sig['v']}")

    bal_before = get_balance(token, RECIPIENT_ADDR)
    cast_send(
        pool,
        "withdrawFromCard(address,address,uint256,uint8,bytes32,bytes32)",
        card_addr,
        RECIPIENT_ADDR,
        str(FEE_BPS),
        str(sig["v"]),
        sig["r"],
        sig["s"],
        pk=INITIATOR_PK,
    )
    payout = get_balance(token, RECIPIENT_ADDR) - bal_before
    fee = get_balance(token, FEE_RECIPIENT)

    ok = payout == 100 * 10**18 and fee == 0
    print(
        f"  到账: {payout / 10**18} TT, fee: {fee / 10**18} TT → {'PASS' if ok else 'FAIL'}"
    )
    results.append(("withdrawFromCard (full amount, no fee)", ok))

    # ================================================================
    # Test 2: withdrawFromCardByRelayer — 扣手续费
    # ================================================================
    print_header(2, "withdrawFromCardByRelayer — 扣 2% 手续费")

    pool, token = fresh_pool_and_token()
    deposit(pool, token, card_addr, 100)

    digest = get_digest(pool, card_addr, RECIPIENT_ADDR, FEE_BPS)
    sig = crypto.sign_digest_ethereum(digest)

    bal_r_before = get_balance(token, RECIPIENT_ADDR)
    bal_f_before = get_balance(token, FEE_RECIPIENT)

    cast_send(
        pool,
        "withdrawFromCardByRelayer(address,address,uint256,uint8,bytes32,bytes32)",
        card_addr,
        RECIPIENT_ADDR,
        str(FEE_BPS),
        str(sig["v"]),
        sig["r"],
        sig["s"],
        pk=RELAYER_PK,
    )

    payout = get_balance(token, RECIPIENT_ADDR) - bal_r_before
    fee = get_balance(token, FEE_RECIPIENT) - bal_f_before

    ok = payout == 98 * 10**18 and fee == 2 * 10**18
    print(
        f"  到账: {payout / 10**18} TT, fee: {fee / 10**18} TT → {'PASS' if ok else 'FAIL'}"
    )
    results.append(("withdrawFromCardByRelayer (2% fee)", ok))

    # ================================================================
    # Test 3: withdrawExpired — 过期取回
    # ================================================================
    print_header(3, "withdrawExpired — 过期后 Initiator 取回")

    pool, token = fresh_pool_and_token()
    bal_init_before = get_balance(token, INITIATOR_ADDR)
    deposit(pool, token, card_addr, 100, lock_seconds=10)
    print("  存入 100 TT, lockTime=10s")

    # 快进
    run(["cast", "rpc", "evm_increaseTime", "15", "--rpc-url", RPC])
    run(["cast", "rpc", "evm_mine", "--rpc-url", RPC])
    print("  快进 15 秒")

    cast_send(pool, "withdrawExpired(address)", card_addr, pk=INITIATOR_PK)
    bal_init_after = get_balance(token, INITIATOR_ADDR)
    net = bal_init_after - bal_init_before  # deposit -100, withdraw +100 = 0

    ok = net == 0
    print(f"  token 净变化: {net / 10**18} TT → {'PASS' if ok else 'FAIL'}")
    results.append(("withdrawExpired (full return)", ok))

    # ================================================================
    # Test 4: batchWithdrawFromCardByRelayer
    # ================================================================
    print_header(4, "batchWithdrawFromCardByRelayer — 批量 Relayer")

    pool, token = fresh_pool_and_token()
    deposit(pool, token, card_addr, 500)

    digest = get_digest(pool, card_addr, RECIPIENT_ADDR, FEE_BPS)
    sig = crypto.sign_digest_ethereum(digest)

    bal_r_before = get_balance(token, RECIPIENT_ADDR)
    bal_f_before = get_balance(token, FEE_RECIPIENT)

    param = (
        f"[({card_addr},{RECIPIENT_ADDR},{FEE_BPS},{sig['v']},{sig['r']},{sig['s']})]"
    )
    cast_send(
        pool,
        "batchWithdrawFromCardByRelayer((address,address,uint256,uint8,bytes32,bytes32)[])",
        param,
        pk=RELAYER_PK,
    )

    payout = get_balance(token, RECIPIENT_ADDR) - bal_r_before
    fee = get_balance(token, FEE_RECIPIENT) - bal_f_before

    ok = payout == 490 * 10**18 and fee == 10 * 10**18
    print(
        f"  到账: {payout / 10**18} TT, fee: {fee / 10**18} TT → {'PASS' if ok else 'FAIL'}"
    )
    results.append(("batchWithdrawFromCardByRelayer (500 TT, 2% fee)", ok))

    # ================================================================
    # Test 5: 错误签名 revert
    # ================================================================
    print_header(5, "Invalid signature — 应 revert")

    pool, token = fresh_pool_and_token()
    deposit(pool, token, card_addr, 100)

    # 签给 DEPLOYER_ADDR 但提交时传 RECIPIENT_ADDR
    wrong_digest = get_digest(pool, card_addr, DEPLOYER_ADDR, FEE_BPS)
    sig = crypto.sign_digest_ethereum(wrong_digest)

    try:
        cast_send(
            pool,
            "withdrawFromCard(address,address,uint256,uint8,bytes32,bytes32)",
            card_addr,
            RECIPIENT_ADDR,
            str(FEE_BPS),
            str(sig["v"]),
            sig["r"],
            sig["s"],
            pk=INITIATOR_PK,
        )
        ok = False
        print("  结果: FAIL (应 revert 但成功了)")
    except RuntimeError:
        ok = True
        print("  结果: PASS (正确 revert)")
    results.append(("invalid signature revert", ok))

    # ================================================================
    # Test 6: 非 Relayer 调用 revert
    # ================================================================
    print_header(6, "Non-relayer 调用 withdrawFromCardByRelayer — 应 revert")

    pool, token = fresh_pool_and_token()
    deposit(pool, token, card_addr, 100)

    digest = get_digest(pool, card_addr, RECIPIENT_ADDR, FEE_BPS)
    sig = crypto.sign_digest_ethereum(digest)

    try:
        cast_send(
            pool,
            "withdrawFromCardByRelayer(address,address,uint256,uint8,bytes32,bytes32)",
            card_addr,
            RECIPIENT_ADDR,
            str(FEE_BPS),
            str(sig["v"]),
            sig["r"],
            sig["s"],
            pk=INITIATOR_PK,
        )  # initiator 不是 relayer
        ok = False
        print("  结果: FAIL (应 revert)")
    except RuntimeError:
        ok = True
        print("  结果: PASS (正确 revert: NotRelayer)")
    results.append(("non-relayer revert", ok))

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
