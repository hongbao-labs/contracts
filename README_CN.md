# HongBao — 锁仓红包合约

*[English version →](./README.md)*

基于硬件签名设备的锁仓红包合约。项目方将资产存入并绑定到卡片公钥地址，持卡人通过设备签名解锁资产。两套合约共享同一交互模型，分别支持 **ERC20** 与 **ERC721**：

| 变体 | 资产 | Pool | Factory | 集成文档 |
|------|------|------|---------|----------|
| Token | ERC20 | `HongBaoTokenPool` | `HongBaoTokenFactory` | [integration-examples/token](./integration-examples/token/README.md) |
| NFT   | ERC721 | `HongBaoNFTPool` | `HongBaoNFTFactory` | [integration-examples/nft](./integration-examples/nft/README.md) |

Token pool 同时支持两种卡：

- **普通卡 (plain)** —— 一次签名领全额，传统红包。
- **任务卡 (task)** —— 一次签名只绑定收款地址 + 释放 `basicAmount`，后续每完成一个任务由项目方下发 preimage，**任何人**提交 `claimTask` 把任务奖励强转给已绑定地址。CTF-flag 风格的渐进解锁，把签名从"领钱凭证"换成"绑定凭证"。

合约完全去中心化：无 owner、无 pause、无手续费、无特权中继。

## 核心流程

```
普通卡:
  1. 项目方 deposit() 存入资产
  2. 持卡人硬件签名 Withdraw(unlockAddress, to)
  3. 任何人提交 withdraw() → 全额到 to，卡消费
  4. 过期未领 → initiator/depositor withdrawExpired() 回收

任务卡 (仅 Token, 限定模式):
  1. 项目方 depositWithTasks() 锁卡 + 上链 taskHashes[]
  2. 持卡人硬件签名 Withdraw(unlockAddress, to) → withdraw() 转 basicAmount 给 to 并永久绑定 boundTo
  3. 用户完成任务 → 项目方下发 preimage → 任何人 claimTask() 强转 boundTo
  4. 过期未领 → initiator withdrawExpired() 一次性回收剩余并 close 卡
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

Token pool 同时支持两种卡：

- **普通卡 (`cardTaskCount == 0`)** —— 一次签名领全额，行为同 ERC20 版本最初设计。
- **任务卡 (`cardTaskCount > 0`)** —— "礼品卡 + 完成任务领奖"模式。一次签名只绑定 `to` + 释放 `basicAmount`；后续每个任务由项目方下发 preimage，**任何人**提交 `claimTask` 把该任务的金额强转 `boundTo`。仅限定模式可用。

#### 存款

| 函数 | 卡类型 | 说明 |
|---|---|---|
| `deposit(unlockAddress, amount, lockTime)` | 普通 / 任务卡 topup | 普通卡首次创建 / 任意卡补 `basicAmount`；首次 `lockTime >= MIN_LOCK_TIME`，续充忽略 |
| `batchDeposit(unlockAddresses[], amount, lockTime)` | 普通 | 批量普通卡，每张相同 amount/lockTime |
| `depositWithTasks(unlockAddress, basicAmount, taskHashes[], taskAmounts[], lockTime)` | 任务卡 | 一次性建任务卡；hashes/amounts 一旦上链不可改 |
| `batchDepositWithTasks(unlockAddresses[], basicAmounts[], taskHashes[][], taskAmounts[][], lockTime)` | 任务卡 | 原子批量任意形态任务卡，一次 `safeTransferFrom` 拉总额 |

#### 提取

| 函数 | 调用者 | 说明 |
|---|---|---|
| `withdraw(unlockAddress, to, v, r, s)` | 任何人 | 普通卡：全额转 `to`，卡消费。任务卡：转 `basicAmount` + 永久绑定 `boundTo = to`，卡仍 active |
| `batchWithdraw(unlockAddresses[], tos[], vs[], rs[], ss[])` | 任何人（relayer 用） | 批量 withdraw；坏签名 / 已兑付 / 已 closed / 零 to 条目静默跳过，不毁掉整批 |
| `claimTask(unlockAddress, taskIdx, n)` | 任何人 | 校验 `keccak256(abi.encode(chainid, pool, unlockAddress, taskIdx, n)) == taskHashes[taskIdx]`，转 `taskAmounts[taskIdx]` 到 `boundTo`。需先 `withdraw` 绑定 |
| `batchClaimTask(unlockAddresses[], taskIdxs[], preimages[])` | 任何人（relayer 用） | 批量 claim；非任务卡 / 越界 / 已 closed / 未 bind / 已 claim / 错 preimage 条目静默跳过 |
| `withdrawExpired(unlockAddress)` | 普通：depositor；任务：initiator | 普通卡按份额回收；任务卡 initiator 一次性回收剩余并 `closed = true` |
| `batchWithdrawExpired(unlockAddresses[])` | 同上 | 批量；已 closed / 已兑付 / 无份额条目静默跳过；普通 + 任务卡可混合一批 |

> `batchWithdraw` / `batchClaimTask` 设计成 skip-silently 是为了 relayer：一批 N 条请求里有一条状态过期 / 签名错，不应该让其它 N-1 条陪葬。Off-chain 通过事件 (`Withdrawn` / `TaskClaimed`) 判定哪些成功。

#### View

| 函数 | 返回 |
|---|---|
| `cardTotal(unlockAddress)` | 当前可领取剩余总额（basic 未领 + 未 claim 的 task amount） |
| `cardBasicAmount(unlockAddress)` | 下一次 `withdraw` 会释放的金额；普通卡镜像 `cardTotal` |
| `cardTaskCount(unlockAddress)` | 0 = 普通卡，>0 = 任务卡 |
| `cardBoundTo(unlockAddress)` | 任务卡 `withdraw` 之后绑定的 to（普通卡或未绑定返回 0） |
| `cardClosed(unlockAddress)` | 任务卡是否已被 initiator 通过 `withdrawExpired` 关闭 |
| `cardExpire(unlockAddress)` | 过期时间戳 |
| `cardUnlockedAt(unlockAddress)` | 兑付时间戳（普通卡=领取时间；任务卡=basic withdraw 时间） |
| `task(unlockAddress, taskIdx)` | `(hash, amount, claimedAt)` |
| `computeTaskHash(unlockAddress, taskIdx, n)` | 链下校验工具，等价于 `keccak256(abi.encode(chainid, pool, unlockAddress, taskIdx, n))` |
| `depositRecord(unlockAddress, depositor)` | 某 depositor 的份额（开放模式普通卡用） |
| `lockedToken()` | 绑定的 ERC20 地址 |
| `initiator()` | 限定模式下的唯一 depositor（开放模式为 0；任务卡必为非零） |
| `MAX_TASKS_PER_CARD()` | 255 |

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
# 编译（启用 optimizer + via_ir，详见 foundry.toml）
forge build

# 跑全量测试（130 tests，覆盖 Token / NFT / 任务卡）
forge test -vv

# 仅 Token 测试
forge test --match-path "test/HongBaoToken*.t.sol" -vv

# 仅 NFT 测试
forge test --match-path "test/HongBaoNFT*.t.sol" -vv
```

### 测试覆盖

- **HongBaoTokenPool 普通卡限定模式（34 tests）**: deposit / batchDeposit / topup / withdraw / withdrawExpired / batchWithdrawExpired（含跳过已兑付与零份额的用例）/ high-S 签名拒绝 / views / 构造参数校验
- **HongBaoTokenPool 普通卡开放模式（4 tests）**: 多 depositor 同一卡 / 一次 withdraw 清扫所有 depositor / 过期按份额取回 / 抢跑 grief 场景
- **HongBaoTokenPool 任务卡（45 tests）**: depositWithTasks（happy / 边界 / 所有 reject）/ topup 进 basic / withdraw 释放 basic + 绑定 boundTo / claimTask（happy / 任何人可调 / hash 绑定跨链 + 跨卡复用必败 / 过期未 close 仍可领 / 已 close revert）/ withdrawExpired 任务卡分支 / batchWithdrawExpired 混合普通 + 任务卡 / batchDepositWithTasks 原子失败回滚 / views
- **HongBaoTokenPool batchWithdraw / batchClaimTask（17 tests）**: 两个批量函数的 happy path（同一卡多任务、跨卡）/ skip-silently（坏签名、已兑付、零 to、错 preimage、basic 未完成、已 close、越界 idx、非任务卡、已领过的槽位）/ 长度校验
- **HongBaoTokenFactory（8 tests）**: `createPool` 正常 / 重复 `PoolExists` / `computePoolAddress` 与实际部署地址一致 / 开放模式 pool / 不同 (token, initiator) 组合
- **HongBaoNFTPool（19 tests）**: pull / push deposit / withdraw / withdrawExpired / batchWithdrawExpired / 接收方兼容性 / views / 构造参数校验
- **HongBaoNFTFactory（3 tests）**: `createPool` 正常 / 重复 `PoolExists` / `computePoolAddress` 与实际部署地址一致

## 部署脚本

### Token 变体

```bash
# 1. 部署 Factory（一次性）
forge script script/DeployFactory.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 2. 创建 Pool（每个 token × 每个 initiator 一次）
FACTORY=0x... TOKEN=0x... INITIATOR=0x... \
forge script script/CreatePool.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 3a. 普通卡批量存款（每张相同金额）
POOL=0x... AMOUNT_ETHER=100 LOCK_DAYS=30 ADDRESSES_JSON=./addresses.json \
forge script script/BatchDeposit.s.sol --rpc-url $RPC --private-key $PK --broadcast

# 3b. 任务卡批量建卡（每张卡独立 basicAmount + tasks）
POOL=0x... LOCK_DAYS=30 CARDS_JSON=./task-cards.json \
forge script script/BatchDepositWithTasks.s.sol --rpc-url $RPC --private-key $PK --broadcast
```

`addresses.json`（普通卡）：
```json
{ "addresses": ["0xAbc...", "0xDef...", ...] }
```

`task-cards.json`（任务卡，金额为 token 最小单位）：
```json
{
  "cards": [
    {
      "unlockAddress": "0xCard1...",
      "basicAmount": 10000000000000000000,
      "taskHashes":  ["0xabc...", "0xdef..."],
      "taskAmounts": [20000000000000000000, 30000000000000000000]
    }
  ]
}
```
`taskHashes[i] = keccak256(abi.encode(chainid, pool, unlockAddress, i, preimage_i))`，preimage 链下生成保管，**且必须按目标链的 chainid 计算** —— 不同链需要不同 hash。详见 [integration-examples/token/README.md](./integration-examples/token/README.md#任务卡-task-card)。

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

> ⚠️ **外部用户不可用**：`e2e_test.py` 依赖一套私有的 STM32 硬件签名工具（仓库外的 `../mac_tool/stm32_crypto_wrapper`）以及实体设备连接，未随本仓库开源。外部贡献者请以 `forge test`（130 个单元测试）为准——它用 Foundry 的 `vm.sign` 模拟设备签名，覆盖了全部合约逻辑。

需要 STM32 设备 + 私有 `mac_tool` 时：

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
