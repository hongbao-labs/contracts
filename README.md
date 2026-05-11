# HongBao — 锁仓红包合约

基于硬件签名设备的一次性锁仓红包合约。项目方将资产存入并绑定到卡片公钥地址，持卡人通过设备签名解锁资产。两套合约共享同一交互模型，分别支持 **ERC20** 与 **ERC721**：

| 变体 | 资产 | Pool | Factory | 集成文档 |
|------|------|------|---------|----------|
| Token | ERC20 | `HongBaoTokenPool` | `HongBaoTokenFactory` | [integration-examples/token](./integration-examples/token/README.md) |
| NFT   | ERC721 | `HongBaoNFTPool` | `HongBaoNFTFactory` | [integration-examples/nft](./integration-examples/nft/README.md) |

合约完全去中心化：无 owner、无 pause、无手续费、无特权中继。

## 核心流程

```
1. 项目方调用 deposit() 存入资产，绑定到卡片公钥地址
2. 持卡人通过硬件设备签名 Withdraw(unlockAddress, to)
3. 任何人提交签名，调用 withdraw() 解锁资产到 to
4. 若过期未领取，initiator/depositor 调用 withdrawExpired() 取回
```

ERC20 与 ERC721 在签名层面完全一致（同一 EIP-712 schema），仅资产类型与少量管理细节不同 —— 详见 [集成示例索引](./integration-examples/README.md) 中的差异表。

## 合约架构

```
src/HongBao/
├── shared/                              # 跨变体共用
│   ├── interfaces/
│   │   ├── IERC20.sol
│   │   ├── IERC721.sol
│   │   └── IERC721Receiver.sol
│   ├── libraries/
│   │   └── SafeERC20.sol
│   └── utils/
│       └── ReentrancyGuard.sol
├── token/                               # ERC20 变体
│   ├── HongBaoTokenFactory.sol          # CREATE2 工厂 + 注册表
│   ├── HongBaoTokenPool.sol             # 单 (token, initiator) 红包池
│   └── interfaces/
│       ├── IHongBaoTokenFactory.sol
│       └── IHongBaoTokenPool.sol
└── nft/                                 # ERC721 变体
    ├── HongBaoNFTFactory.sol            # CREATE2 工厂 + 注册表
    ├── HongBaoNFTPool.sol               # 单 (collection, initiator) 红包池
    └── interfaces/
        ├── IHongBaoNFTFactory.sol
        └── IHongBaoNFTPool.sol
```

每个项目方为每种资产部署一个独立 pool 实例，通过对应的 Factory 标准化部署。

## Pool 模式

构造参数 `initiator` 决定 pool 的权限模式。两套 pool 的判定规则相同，但 NFT 版本只支持限定模式：

| `initiator` | Token Pool | NFT Pool |
|---|---|---|
| `address(0)` | **开放模式** —— 任何人都能 deposit，按 depositor 记账份额 | 不支持（构造时 revert `ZeroInitiator`） |
| 非零地址 | **限定模式** —— 仅该地址可 deposit | 唯一支持的模式 |

Token 开放模式下多个 depositor 可给同一张卡续充（topup），解锁时一次性全额转给 `to`，过期后各自按份额取回。NFT 仅限定模式：一张卡只持有一个 tokenId，没有续充语义，过期由 initiator 取回。

## 签名机制

EIP-712 schema（两套合约一致）：

```
Withdraw(address unlockAddress, address to)
```

- Domain: `name="HongBao"`, `version="1"`, `chainId`, `verifyingContract`（每个 pool 独立）
- 单次签名：`unlockedAt != 0` 后无法再次提取，无需 nonce
- 防跨链/跨合约重放：Domain 绑 chainId + pool 地址

> ⚠️ **NFT 特别注意**：合约 withdraw 内部用 `safeTransferFrom`，`to` 必须能接收 ERC721。硬件设备每张卡只能签一次，签错了 `to`（如不实现 `IERC721Receiver` 的合约）这张卡就报废。集成方在让设备签名前必须校验 `to`。详见 [integration-examples/nft/README.md](./integration-examples/nft/README.md)。

## 核心函数

### Token Pool（`HongBaoTokenPool`）

#### 存款

| 函数 | 说明 |
|---|---|
| `deposit(unlockAddress, amount, lockTime)` | 存入 ERC20，首次 `lockTime >= MIN_LOCK_TIME`；续充忽略 `lockTime` |
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
| `lockedToken()` | 绑定的 ERC20 地址 |
| `initiator()` | 限定模式下的唯一 depositor（开放模式为 0） |

### NFT Pool（`HongBaoNFTPool`）

#### 存款

| 函数 | 说明 |
|---|---|
| `deposit(unlockAddress, tokenId, lockTime)` | Pull 路径。initiator 提前 approve 后调用 |
| `onERC721Received(...)` | Push 路径。initiator 直接 `safeTransferFrom(initiator, pool, tokenId, abi.encode(unlockAddress, lockTime))` |

NFT 没有 `batchDeposit` —— 一张卡只持有一个 tokenId，批量在脚本层用循环实现（见 `script/BatchDepositNFT.s.sol`）。

#### 提取

| 函数 | 调用者 | 说明 |
|---|---|---|
| `withdraw(unlockAddress, to, v, r, s)` | 任何人 | 转 NFT 给 `to`（用 `safeTransferFrom`），卡片消费 |
| `withdrawExpired(unlockAddress)` | initiator | 取回 NFT；严格 revert |
| `batchWithdrawExpired(unlockAddresses[])` | initiator | 批量；已兑付/无 deposit 静默跳过；单条 `safeTransferFrom` 失败也跳过，状态保留以便重试 |

#### View

| 函数 | 返回 |
|---|---|
| `cardTokenId(unlockAddress)` | 卡片绑定的 tokenId（**注意**：0 是合法值，需用 `cardExpire != 0` 判定是否存在）|
| `cardExpire(unlockAddress)` | 过期时间戳（0 表示卡不存在） |
| `cardUnlockedAt(unlockAddress)` | 兑付时间戳（0 = 未兑付） |
| `lockedCollection()` | 绑定的 ERC721 collection 地址 |
| `initiator()` | 唯一 depositor（保证非零） |

### 共用 View（两套 pool 一致）

| 函数 | 返回 |
|---|---|
| `isLocked(unlockAddress)` | 是否仍持有资产 |
| `isExpired(unlockAddress)` | 是否已过期且未兑付 |
| `remainingLockTime(unlockAddress)` | 剩余锁定秒数 |
| `getWithdrawDigest(unlockAddress, to)` | EIP-712 签名 digest |
| `DOMAIN_SEPARATOR()` | EIP-712 domain separator |
| `WITHDRAW_TYPEHASH()` | EIP-712 type hash |
| `MIN_LOCK_TIME()` | 最小锁定时长（30 天）|

### Factory

`HongBaoTokenFactory` 与 `HongBaoNFTFactory` 接口完全对称，仅资产参数命名不同：

| Token Factory | NFT Factory | 说明 |
|---|---|---|
| `createPool(token, initiator)` | `createPool(collection, initiator)` | CREATE2 部署新 pool；`(asset, initiator)` 唯一 |
| `pools(token, initiator)` | `pools(collection, initiator)` | 查询已注册 pool 地址（未部署返回 0） |
| `computePoolAddress(token, initiator)` | `computePoolAddress(collection, initiator)` | 确定性地址，部署前就能算出 |

> NFT Factory 的 `createPool` 拒绝 `initiator == 0`，与 NFT pool 仅限定模式的设计一致。

## 常量

| 常量 | 值 |
|---|---|
| `MIN_LOCK_TIME` | 30 天（两套 pool 硬编码） |
| `WITHDRAW_TYPEHASH` | `keccak256("Withdraw(address unlockAddress,address to)")` |

## 开发

```bash
# 编译
forge build

# 跑全量测试（71 tests，覆盖 Token / NFT 变体）
forge test -vv

# 仅 Token 测试
forge test --match-path "test/HongBaoToken*.t.sol" -vv

# 仅 NFT 测试
forge test --match-path "test/HongBaoNFT*.t.sol" -vv
```

### 测试覆盖

- **HongBaoTokenPool 限定模式（33 tests）**: deposit / batchDeposit / topup / withdraw / withdrawExpired / batchWithdrawExpired（含跳过已兑付与零份额的用例）/ views / 构造参数校验
- **HongBaoTokenPool 开放模式（4 tests）**: 多 depositor 同一卡 / 一次 withdraw 清扫所有 depositor / 过期按份额取回 / 抢跑 grief 场景
- **HongBaoTokenFactory（8 tests）**: `createPool` 正常 / 重复 `PoolExists` / `computePoolAddress` 与实际部署地址一致 / 开放模式 pool / 不同 (token, initiator) 组合
- **HongBaoNFTPool（19 tests）**: pull / push deposit / withdraw / withdrawExpired / batchWithdrawExpired / 接收方兼容性 / views / 构造参数校验
- **HongBaoNFTFactory（3 tests）**: `createPool` 正常 / 重复 `PoolExists` / `computePoolAddress` 与实际部署地址一致
- **SignTest（4 tests）**: 设备签名与 EVM `ecrecover` 兼容性

## 部署脚本

### Token 变体

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

`addresses.json`：
```json
{ "addresses": ["0xAbc...", "0xDef...", ...] }
```

### NFT 变体

> ⚠️ **Collection 尽调（部署方责任，Factory 不校验）**：合约信任 `lockedCollection` 忠实遵循 ERC721。可升级 / 恶意 collection 可以注册幽灵卡永久 brick `unlockAddress`。建议：
> - 非升级合约（无 EIP-1967 proxy slot）
> - 来源可信 / 经过审计
> - `safeTransferFrom`、`transferFrom`、`ownerOf` 行为标准

```bash
# 1. 部署 Factory（一次性）
forge script script/DeployNFTFactory.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 2. 创建 Pool（每个 collection × 每个 initiator 一次；INITIATOR 必填）
FACTORY=0x... COLLECTION=0x... INITIATOR=0x... \
forge script script/CreateNFTPool.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 3. 批量存款（脚本层循环 deposit；任一失败整批 revert）
POOL=0x... LOCK_DAYS=30 ENTRIES_JSON=./entries.json \
forge script script/BatchDepositNFT.s.sol --rpc-url $RPC --private-key $PK --broadcast
```

`entries.json`：
```json
{
  "entries": [
    { "unlockAddress": "0xAbc...", "tokenId": "1" },
    { "unlockAddress": "0xDef...", "tokenId": "2" }
  ]
}
```

## 端到端测试（设备 + 合约）

需要 STM32 设备连接：

```bash
../mac_tool/venv/bin/python3 e2e_test.py
```

当前覆盖 Token 变体：withdraw（任意人提交）/ withdrawExpired（快进 30 天）/ batchDeposit / 错误签名 revert / Factory 地址预测一致性。NFT 变体的 e2e 待补。

## 集成

钱包 App 集成示例与文档：

- [integration-examples/](./integration-examples/README.md) —— 总览与变体对比
- [integration-examples/token/](./integration-examples/token/README.md) —— ERC20 集成（含 viem 示例）
- [integration-examples/nft/](./integration-examples/nft/README.md) —— ERC721 集成（含 viem 示例 + `to` 校验注意事项）

## 许可

MIT
