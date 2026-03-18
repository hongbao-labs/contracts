# ForgePool - 一次性礼品卡锁仓合约

基于硬件签名设备的 ERC20 锁仓合约。用户存入代币并绑定到卡片公钥地址，持卡人通过设备签名解锁资产。

## 核心流程

```
1. Initiator 调用 deposit() 存入 ERC20，绑定到卡片公钥地址
2. 持卡人（或 Relayer）提交设备签名，调用 withdraw 解锁资产
3. 若过期未领取，Initiator 可调用 withdrawExpired() 取回
```

## 合约架构

```
src/Agora/
├── ForgePool.sol        # 主合约（deposit / withdraw / admin config）
├── ForgePoolAccess.sol  # 权限管理（Owner / Relayer / Pause）
├── ForgePoolTypes.sol   # 结构体 / Events / Errors
└── SafeERC20.sol        # SafeTransfer 库
```

## 签名机制

设备只签名一次，两种提取路径共用同一个签名：

```
EIP-712 Withdraw(address unlockAddress, address to, uint256 feeBps)
```

- **直接提取** `withdrawFromCard()` — 验签，全额转出，feeBps 仅用于验签不实际扣费
- **Relayer 提取** `withdrawFromCardByRelayer()` — 验签，按 feeBps 扣手续费

feeBps 由签名者决定（愿意给 Relayer 多少手续费），合约层面 clamp 到 `[minFeeBps, maxFeeBps]`：
- 签的值 < minFeeBps → 按 minFeeBps 扣
- 签的值 > maxFeeBps → 按 maxFeeBps 扣

防重放：一次性卡片，`unlockedAt != 0` 后无法再次提取，无需 nonce。

EIP-712 Domain 绑定 chainId + 合约地址，防止跨链/跨合约重放。

## 核心函数

### 存款

| 函数 | 说明 |
|---|---|
| `deposit(unlockAddress, token, amount, lockTime)` | 存入 ERC20，锁定到卡片地址，lockTime >= minLockTime |

### 提取

| 函数 | 调用者 | 手续费 |
|---|---|---|
| `withdrawFromCard(unlockAddress, to, feeBps, v, r, s)` | 任何人 | 无 |
| `withdrawFromCardByRelayer(unlockAddress, to, feeBps, v, r, s)` | Relayer | feeBps (clamped) |
| `batchWithdrawFromCardByRelayer(params[])` | Relayer | 同上，批量 |
| `withdrawExpired(unlockAddress)` | Initiator | 无 |
| `batchWithdrawExpired(unlockAddresses[])` | Initiator | 无，批量 |

### View

| 函数 | 返回 |
|---|---|
| `getDepositInfo(unlockAddress)` | 完整存款信息 |
| `isLocked(unlockAddress)` | 是否仍锁定 |
| `isExpired(unlockAddress)` | 是否已过期 |
| `remainingLockTime(unlockAddress)` | 剩余锁定秒数 |
| `getWithdrawDigest(unlockAddress, to, feeBps)` | 签名 digest（给设备端用） |

### 管理

| 函数 | 说明 |
|---|---|
| `addRelayer(address)` / `removeRelayer(address)` | 管理 Relayer 白名单 |
| `transferOwnership(address)` / `acceptOwnership()` | 两步转移所有权 |
| `setMinLockTime(uint256)` | 最小锁定时间（默认 180 天） |
| `setMinFeeBps(uint256)` | 最小手续费（默认 50 = 0.5%） |
| `setMaxFeeBps(uint256)` | 最大手续费（默认 1000 = 10%） |
| `setFeeRecipient(address)` | 手续费接收地址 |
| `pause()` / `unpause()` | 暂停/恢复合约 |

## 默认参数

| 参数 | 默认值 |
|---|---|
| minLockTime | 180 天 |
| minFeeBps | 50 (0.5%) |
| maxFeeBps | 1000 (10%) |
| BPS_DENOMINATOR | 10000 |

## 开发

```bash
# 编译
forge build

# 测试（32 tests）
forge test -vv

# 仅 ForgePool 测试
forge test --match-contract ForgePoolTest -vv
```

### 测试覆盖

- Deposit: 正常 / zero amount / already locked / lock too short / zero address
- WithdrawFromCard: 全额到账 / 错误签名 / 已解锁 / 无存款 / zero to
- WithdrawByRelayer: 扣费正确 / 同签名两路径 / fee clamp min / fee clamp max / 非 relayer
- BatchWithdrawByRelayer: 3 笔批量
- WithdrawExpired: 正常 / 未过期 / 非 initiator
- BatchWithdrawExpired: 3 笔批量
- View: isLocked / isExpired / remainingLockTime / digest 确定性
- Access: relayer 增删 / ownership transfer / onlyOwner
- Admin: setMinLockTime / setMinFeeBps / setMaxFeeBps / setFeeRecipient
- Pause: 阻止 deposit / 阻止 withdraw

## 端到端测试（设备 + 合约）

需要 STM32 设备连接：

```bash
# SignTest 合约：验证设备签名与 EVM ecrecover 兼容
cd contract && ../mac_tool/venv/bin/python3 e2e_test.py
```

此测试从合约获取 digest，发给设备签名，再在 EVM 中用 ecrecover 验证。
