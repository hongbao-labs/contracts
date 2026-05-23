# HongBao Token (ERC20) 钱包 App 集成（收红包）

## 概述

本文档描述钱包 App 如何集成 `HongBaoTokenPool` 合约，实现 ERC20 "收红包"功能。

合约支持两种卡类型：

- **普通卡 (Plain card)** —— 一次签名领全额。`cardTaskCount(unlockAddress) == 0`。
- **任务卡 (Task card)** —— 一次签名只绑定收款地址 + 释放 `basicAmount`，后续每完成一个任务由项目方发布 preimage，任何人提交 `claimTask` 把任务奖励强转给已绑定的 to。`cardTaskCount(unlockAddress) > 0`。

普通卡核心流程：**读取卡信息 → 生成签名数据 → 硬件设备签名 → 提交 withdraw**。
任务卡在普通卡流程之后多一段："收齐 preimage → 提交 claimTask"。

合约无手续费、无特权中继，`withdraw` / `claimTask` 由**任何人**提交即可。Gas 代付是可选的应用层服务（不在合约范围内）。

## 前置条件

- `HongBaoTokenPool` 合约地址（由项目方通过 `HongBaoTokenFactory` 部署得到）
- RPC 节点

## 合约 ABI

```typescript
import { parseAbi } from "viem";

const HongBaoTokenPoolABI = parseAbi([
  // basics — apply to all cards
  "function lockedToken() view returns (address)",
  "function cardTotal(address unlockAddress) view returns (uint256)",
  "function cardExpire(address unlockAddress) view returns (uint256)",
  "function cardUnlockedAt(address unlockAddress) view returns (uint256)",
  "function isLocked(address unlockAddress) view returns (bool)",
  "function isExpired(address unlockAddress) view returns (bool)",
  "function remainingLockTime(address unlockAddress) view returns (uint256)",
  "function getWithdrawDigest(address unlockAddress, address to) view returns (bytes32)",
  "function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s)",

  // task card surface (returns sensible defaults on plain cards)
  "function cardTaskCount(address unlockAddress) view returns (uint8)",
  "function cardBasicAmount(address unlockAddress) view returns (uint256)",
  "function cardBoundTo(address unlockAddress) view returns (address)",
  "function cardClosed(address unlockAddress) view returns (bool)",
  "function task(address unlockAddress, uint8 taskIdx) view returns (bytes32 hash, uint256 amount, uint256 claimedAt)",
  "function computeTaskHash(address unlockAddress, uint8 taskIdx, bytes n) view returns (bytes32)",
  "function claimTask(address unlockAddress, uint8 taskIdx, bytes n)",

  // relayer-oriented batch entry points (skip-silently on per-entry failure)
  "function batchWithdraw(address[] unlockAddresses, address[] tos, uint8[] vs, bytes32[] rs, bytes32[] ss)",
  "function batchClaimTask(address[] unlockAddresses, uint8[] taskIdxs, bytes[] preimages)",
]);
```

## 集成流程

### Step 1: 获取卡片地址

从硬件设备获取 `unlockAddress`（卡片公钥对应的以太坊地址）。该地址是红包在合约中的唯一标识。

### Step 2: 查询红包状态

组合调用几个 view 函数：

```typescript
const [total, expire, unlockedAt, token] = await Promise.all([
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardTotal", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardExpire", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardUnlockedAt", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "lockedToken" }),
]);

const now = BigInt(Math.floor(Date.now() / 1000));
const isLocked = total > 0n && unlockedAt === 0n;
const isExpired = isLocked && now >= expire;
```

状态判断：

| 条件 | 含义 |
|------|------|
| `total === 0 && unlockedAt === 0` | 红包不存在 |
| `unlockedAt !== 0` | 已被领取 |
| `total > 0 && unlockedAt === 0 && now < expire` | 可领取 |
| `total > 0 && unlockedAt === 0 && now >= expire` | 已过期（持卡人仍可用签名领取，直到 depositor 回收为止） |

### Step 3: 获取代币展示信息

从 `lockedToken()` 拿到 ERC20 地址，再读 `symbol()` / `decimals()`：

```typescript
import { erc20Abi } from "viem";

const [symbolResult, decimalsResult] = await publicClient.multicall({
  contracts: [
    { address: token, abi: erc20Abi, functionName: "symbol" },
    { address: token, abi: erc20Abi, functionName: "decimals" },
  ],
});
```

### Step 4: 生成签名 Digest

用户确认领取并输入收款地址后：

```typescript
const digest = await publicClient.readContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
  functionName: "getWithdrawDigest",
  args: [unlockAddress, recipientAddress],
});
```

### Step 5: 硬件设备签名

将 digest（32 字节）发给硬件设备，设备用内置私钥签名后返回 `v`, `r`, `s`。

### Step 6: 提交 withdraw 交易

`withdraw` 合约函数无调用者限制，任何地址都能提交。

#### 方式 A: 应用自有钱包付 gas

```typescript
const txHash = await walletClient.writeContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
  functionName: "withdraw",
  args: [unlockAddress, recipientAddress, v, r, s],
});
```

适用于 App 已经管理了一个发送地址，或用户自带 EOA 的情况。

#### 方式 B: 由代付服务提交（可选）

如果产品要做"用户零 ETH 体验"，App 后端或第三方服务接收 `(unlockAddress, to, v, r, s)`，再以自己的钱包发交易。

由于合约不收取任何手续费、没有白名单限制，这一层完全是业务逻辑：后端决定是否对用户收费、如何收费。合约层不关心。

#### 方式 C: relayer 批量提交（可选）

后端代付服务积攒一段时间的 withdraw 请求，一次性 `batchWithdraw` 上链，摊薄 tx 费：

```typescript
await walletClient.writeContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
  functionName: "batchWithdraw",
  args: [unlockAddresses, tos, vs, rs, ss],
});
```

合约对每个条目**静默跳过失败**（坏签名 / 卡已兑付 / 卡已 close / `to == 0`），不会因为某条过期而毁掉整批。Relayer 应当通过 `Withdrawn` 事件判定哪些条目成功，只对成功的用户结算。`batchClaimTask` 同理（见任务卡章节）。

> ⚠️ **代币兼容性**：`batch*` 内部的 ERC20 `transfer` 没有 `try/catch`。如果 `lockedToken` 带 recipient-side callback（ERC777 `tokensReceived`、ERC1363 `onTransferReceived` 等），且某条目的 `to`（或任务卡的 `boundTo`）是一个会在回调里 revert 的合约，**整批会被这一条 DoS**。标准 ERC20（USDC、DAI、纯 ERC20）没有这种回调，不受影响。如果你打算上 ERC777 类代币，relayer 提交前应在 off-chain 过滤 `to` 是否为已知问题合约。

## 任务卡 (Task Card)

任务卡用于"完成任务才能领取额外奖励"场景。项目方在锁卡时为每张卡承诺 1..255 个任务，每个任务对应一个 `(hash, amount)`：

- `hash = keccak256(abi.encode(chainid, pool, unlockAddress, taskIdx, preimage))` —— preimage 由项目方链下生成保管
- `amount` —— 完成该任务后释放的金额
- `basicAmount` —— 签名 withdraw 时立即释放的"开卡奖励"（可以为 0，纯绑定）

设计目的：**把签名从"一次性领钱凭证"变成"绑定收款地址的凭证"**。
- 用户签名 `Withdraw(unlockAddress, to)` 后：合约转 `basicAmount` 给 `to`，并把 `to` 记进 `boundTo`。卡仍 active。
- 后续每完成一个任务，项目方发 preimage 给用户。**任何人**（用户自己 / relayer / 第三方）都可以提交 `claimTask(unlockAddress, taskIdx, preimage)`，合约校验 hash 后**强制**把该任务的金额转给 `boundTo`。即使 preimage 泄露给第三方也没关系 —— 资金只能去 `boundTo`。
- 防 preimage 跨链 / 跨卡复用：hash 绑定 `(chainid, pool, unlockAddress, taskIdx)`，同一段 preimage 在别的链 / 池 / 卡 / 槽位上算出的 hash 不同。

### Step 1: 识别卡类型

```typescript
const taskCount = await publicClient.readContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
  functionName: "cardTaskCount",
  args: [unlockAddress],
});

if (taskCount === 0) {
  // 普通卡 —— 走上面 Step 1-6
} else {
  // 任务卡 —— 走下面的扩展流程
}
```

### Step 2: 读取任务卡状态

```typescript
const [basicAmount, boundTo, closed, total, unlockedAt] = await Promise.all([
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardBasicAmount", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardBoundTo", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardClosed", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardTotal", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoTokenPoolABI, functionName: "cardUnlockedAt", args: [unlockAddress] }),
]);

const tasks = await Promise.all(
  Array.from({ length: taskCount }, (_, i) =>
    publicClient.readContract({
      address: POOL,
      abi: HongBaoTokenPoolABI,
      functionName: "task",
      args: [unlockAddress, i],
    })
  )
);
// each: [hash, amount, claimedAt]
```

状态判断：

| 条件 | 含义 |
|------|------|
| `closed === true` | 项目方已回收，卡已死，所有 claim/withdraw 都会 revert |
| `unlockedAt === 0` | 还没签名绑定收款地址。先走 withdraw 流程绑定 |
| `unlockedAt !== 0 && boundTo !== 0` | 已绑定。`tasks[i].claimedAt === 0` 的槽位可领 |

### Step 3: 绑定收款地址（withdraw）

完全复用普通卡的 Step 4-6：

```typescript
const digest = await pool.getWithdrawDigest(unlockAddress, recipientAddress);
const { v, r, s } = await hardwareSign(digest);   // 设备签名
await pool.withdraw(unlockAddress, recipientAddress, v, r, s);
```

任务卡的 `withdraw`：
- 转 `basicAmount` 给 `to`（可能为 0）
- 把 `to` 写入 `boundTo`（不可改）
- 设 `unlockedAt = now`
- **卡仍 active**，可继续 claim 任务

> ⚠️ 一旦 withdraw 成功，`boundTo` 永久锁定。后续所有 claim 都只能转到这个地址。

### Step 4: 提交任务领奖

项目方在后台验证用户完成任务后，把对应槽位的 `preimage`（字节串）发给用户。**任何人**都可以提交：

```typescript
// preimage 是 bytes，viem 用 Hex 字符串表示
const preimage: Hex = "0x...";

// （可选）本地预验：算 hash 跟链上对比，避免提交一定会失败的 tx
const computed = await publicClient.readContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
  functionName: "computeTaskHash",
  args: [unlockAddress, taskIdx, preimage],
});
if (computed !== tasks[taskIdx].hash) {
  throw new Error("preimage does not match committed hash");
}

const txHash = await walletClient.writeContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
  functionName: "claimTask",
  args: [unlockAddress, taskIdx, preimage],
});
```

合约保证：
- `boundTo` 还没绑定 → revert（必须先 withdraw）
- 卡已 closed → revert
- hash 不匹配 → revert
- 该槽位已领过 → revert
- 否则 → 转 `tasks[taskIdx].amount` 到 `boundTo`，标记 `claimedAt = now`

#### 批量 claim（relayer 用）

```typescript
await walletClient.writeContract({
  address: POOL,
  abi: HongBaoTokenPoolABI,
  functionName: "batchClaimTask",
  args: [unlockAddresses, taskIdxs, preimages],
});
```

合约对每个条目静默跳过失败（非任务卡 / 越界 / 已 closed / basic 未完成 / 已 claim / preimage 错），单次失败不毁掉整批。Relayer 通过 `TaskClaimed` 事件判定成功条目。

### 项目方端（生成 preimage / 锁卡）

项目方链下：
1. 为每张卡随机生成 N 个 preimage（推荐 32 字节 random）
2. 计算 hash = `keccak256(abi.encode(pool, unlockAddress, taskIdx, preimage))`
3. 调 `depositWithTasks(unlockAddress, basicAmount, hashes[], amounts[], lockTime)`，或批量 `batchDepositWithTasks(...)`
4. preimage 链下保管，按完成情况下发

合约层 hash 算法的 viem 实现：

```typescript
import { encodeAbiParameters, keccak256 } from "viem";

function commitHash(
  chainId: bigint | number,
  pool: Address,
  unlockAddress: Address,
  taskIdx: number,
  preimage: Hex,
): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "uint256" }, { type: "address" }, { type: "address" }, { type: "uint8" }, { type: "bytes" }],
      [BigInt(chainId), pool, unlockAddress, taskIdx, preimage],
    ),
  );
}
```

> 项目方一旦 `depositWithTasks`，task 数量、hashes、amounts **永久不可改**。`basicAmount` 可继续通过 `deposit(unlockAddress, amount, 0)` 续充（直到用户完成 withdraw 绑定）。

## 完整流程图

```
app 连接钱包
     │
     ▼
获取 unlockAddress（硬件设备）
     │
     ▼
读取 cardTaskCount(unlockAddress)
     │
     ├── 0  (普通卡)
     │     │
     │     ▼
     │   读取 cardTotal / cardExpire / cardUnlockedAt
     │     │
     │     ▼
     │   getWithdrawDigest → 设备签名 → withdraw(unlockAddress, to, v, r, s)
     │   卡片消费，全额到账
     │
     └── >0 (任务卡)
           │
           ▼
         读取 cardBasicAmount / cardBoundTo / cardClosed
         + task(idx) ×N
           │
           ▼
         未绑定？(unlockedAt == 0)
           │   ├── 是 → withdraw 绑定 to + 收 basicAmount
           │   │       (此时签名权用尽，boundTo 永久锁定)
           │   │
           │   └── 否 → 跳到 claim 阶段
           │
           ▼
         项目方下发 preimage_i（用户完成任务后）
           │
           ▼
         claimTask(unlockAddress, i, preimage_i)
         金额强转 boundTo，可由任何人（用户/relayer）提交
```

## 运行示例代码

| 变量 | 必填 | 说明 |
|------|------|------|
| `POOL_ADDRESS` | 是 | HongBaoTokenPool 合约地址 |
| `RPC_URL` | 是 | RPC 节点地址 |

```bash
cd integration-examples
npm install
npm run example:token
```
