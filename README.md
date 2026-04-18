# HongBao — ERC20 锁仓红包合约

基于硬件签名设备的一次性 ERC20 红包锁仓合约。项目方将代币存入并绑定到卡片公钥地址，持卡人通过设备签名解锁资产。合约完全去中心化：无 owner、无 pause、无手续费、无特权中继。

## 核心流程

```
1. 项目方（或任何人）调用 deposit() 存入 ERC20，绑定到卡片公钥地址
2. 持卡人通过硬件设备签名 Withdraw(unlockAddress, to)
3. 任何人提交签名，调用 withdraw() 解锁全额到 to
4. 若过期未领取，depositor 调用 withdrawExpired() 按份额取回
```

## 合约架构

```
src/HongBao/
├── HongBaoFactory.sol          # CREATE2 部署 pool 的工厂 + 注册表
├── HongBaoPool.sol             # 单 token 单 (token, initiator) 的红包池
├── interfaces/
│   ├── IHongBaoFactory.sol     # 工厂标准接口
│   ├── IHongBaoPool.sol        # 池标准接口（events + errors）
│   └── IERC20.sol
├── libraries/
│   └── SafeERC20.sol
└── utils/
    └── ReentrancyGuard.sol
```

每个项目方或每种 token 部署独立的 `HongBaoPool` 实例，通过 `HongBaoFactory` 标准化部署。

## Pool 模式

构造参数 `initiator` 决定 pool 的权限模式：

| `initiator` | 模式 | 存款者 |
|---|---|---|
| `address(0)` | 开放模式 | 任何人都能 deposit，系统按 depositor 记录份额 |
| 非零地址 | 限定模式 | 仅该地址可 deposit |

开放模式下多个 depositor 可给同一张卡续充（topup），解锁时一次性全额转给 `to`；过期未领取时各自按份额取回。限定模式天然无抢跑问题。

## 签名机制

EIP-712 schema：

```
Withdraw(address unlockAddress, address to)
```

- Domain: `name="HongBao"`, `version="1"`, `chainId`, `verifyingContract`（每个 pool 独立）
- 单次签名：`unlockedAt != 0` 后无法再次提取，无需 nonce
- 防跨链/跨合约重放：Domain 绑 chainId + pool 地址

## 核心函数

### Pool

#### 存款

| 函数 | 说明 |
|---|---|
| `deposit(unlockAddress, amount, lockTime)` | 存入 ERC20，首次存款 `lockTime >= MIN_LOCK_TIME`；续充忽略 `lockTime` |
| `batchDeposit(unlockAddresses[], amount, lockTime)` | 批量，每张卡相同 amount/lockTime |

#### 提取

| 函数 | 调用者 | 说明 |
|---|---|---|
| `withdraw(unlockAddress, to, v, r, s)` | 任何人 | 全额转给 `to`，卡片消费 |
| `withdrawExpired(unlockAddress)` | depositor | 取回自己份额；严格 revert |
| `batchWithdrawExpired(unlockAddresses[])` | depositor | 批量；已兑付/无份额条目静默跳过 |

#### View

| 函数 | 返回 |
|---|---|
| `cardTotal(unlockAddress)` | 当前可领取总额 |
| `cardExpire(unlockAddress)` | 过期时间戳 |
| `cardUnlockedAt(unlockAddress)` | 兑付时间戳（0 = 未兑付） |
| `depositRecord(unlockAddress, depositor)` | 某 depositor 的份额 |
| `isLocked(unlockAddress)` | 是否仍锁定 |
| `isExpired(unlockAddress)` | 是否已过期 |
| `remainingLockTime(unlockAddress)` | 剩余锁定秒数 |
| `getWithdrawDigest(unlockAddress, to)` | EIP-712 签名 digest |
| `lockedToken()` | 绑定的 ERC20 地址 |
| `initiator()` | 限定模式下的唯一 depositor（开放模式为 0） |

### Factory

| 函数 | 说明 |
|---|---|
| `createPool(token, initiator)` | CREATE2 部署新 pool；`(token, initiator)` 唯一 |
| `pools(token, initiator)` | 查询已注册 pool 地址（未部署返回 0） |
| `computePoolAddress(token, initiator)` | 确定性地址，部署前就能算出 |

## 常量

| 常量 | 值 |
|---|---|
| `MIN_LOCK_TIME` | 30 天（硬编码） |
| `WITHDRAW_TYPEHASH` | `keccak256("Withdraw(address unlockAddress,address to)")` |

## 开发

```bash
# 编译
forge build

# 跑全量测试（49 tests）
forge test -vv

# 仅 HongBao 测试
forge test --match-path "test/HongBao*.t.sol" -vv
```

### 测试覆盖

- **HongBaoPool 限定模式（33 tests）**: deposit / batchDeposit / topup / withdraw / withdrawExpired / batchWithdrawExpired（含跳过已兑付与零份额的用例）/ views / 构造参数校验
- **HongBaoPool 开放模式（4 tests）**: 多 depositor 同一卡 / 一次 withdraw 清扫所有 depositor / 过期按份额取回 / 抢跑 grief 场景
- **HongBaoFactory（8 tests）**: `createPool` 正常 / 重复 `PoolExists` / `computePoolAddress` 与实际部署地址一致 / 开放模式 pool / 不同 (token, initiator) 组合
- **SignTest（4 tests）**: 设备签名与 EVM `ecrecover` 兼容性

## 部署脚本

```bash
# 1. 部署 Factory（一次性）
forge script script/DeployFactory.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 2. 创建 Pool（每个 token × 每个 initiator 一次）
FACTORY=0x... TOKEN=0x... INITIATOR=0x... \
forge script script/CreatePool.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 3. 批量存款（每个 mint 批次）
POOL=0x... AMOUNT_ETHER=100 LOCK_DAYS=30 ADDRESSES_JSON=./addresses.json \
forge script script/BatchDeposit.s.sol --rpc-url $RPC --private-key $PK --broadcast
```

JSON 格式：
```json
{ "addresses": ["0xAbc...", "0xDef...", ...] }
```

## 端到端测试（设备 + 合约）

需要 STM32 设备连接：

```bash
../mac_tool/venv/bin/python3 e2e_test.py
```

测试覆盖：withdraw（任意人提交）/ withdrawExpired（快进 30 天）/ batchDeposit / 错误签名 revert / Factory 地址预测一致性。

## 许可

MIT
