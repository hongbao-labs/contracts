# ForgePool 钱包 App 集成（收红包）

## 概述

本文档描述钱包 App 如何集成 ForgePool 合约，实现"收红包"功能。

收红包的核心流程：**读取红包信息 → 生成签名数据 → 硬件设备签名 → 提交交易提取资产**。

## 前置条件

- ForgePool 合约地址
- RPC 节点

## 合约 ABI

```typescript
import { parseAbi } from "viem";

const ForgePoolABI = parseAbi([
  "function getDepositInfo(address unlockAddress) view returns ((address initiator, address unlockAddress, address token, uint256 amount, uint256 lockTime, uint256 mintTimeStamp, uint256 expire, uint256 unlockedAt))",
  "function getWithdrawDigest(address unlockAddress, address to, uint256 feeBps) view returns (bytes32)",
  "function getFeeRange() view returns (uint256 minFeeBps, uint256 maxFeeBps)",
  "function withdrawFromCard(address unlockAddress, address to, uint256 feeBps, uint8 v, bytes32 r, bytes32 s)",
]);
```

## 集成流程

### Step 1: 获取卡片地址

从硬件设备获取 `unlockAddress`（卡片公钥对应的以太坊地址）。

此地址是红包在合约中的唯一标识。

### Step 2: 查询红包状态

调用 `getDepositInfo` 获取红包详情：

```typescript
const info = await publicClient.readContract({
  address: FORGEPOOL_ADDRESS,
  abi: ForgePoolABI,
  functionName: "getDepositInfo",
  args: [unlockAddress],
});
```

返回字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| `initiator` | `address` | 存款发起人 |
| `unlockAddress` | `address` | 卡片公钥地址 |
| `token` | `address` | ERC20 代币地址 |
| `amount` | `uint256` | 锁定金额 |
| `lockTime` | `uint256` | 锁定时长（秒） |
| `mintTimeStamp` | `uint256` | 存款时间戳 |
| `expire` | `uint256` | 过期时间戳 |
| `unlockedAt` | `uint256` | 解锁时间戳，`0` 表示未领取 |

状态判断逻辑：

```typescript
const isLocked = info.amount > 0n && info.unlockedAt === 0n;  // 可领取
const isExpired = isLocked && BigInt(Date.now() / 1000) >= info.expire;  // 已过期
```

- `amount === 0` → 红包不存在
- `unlockedAt !== 0` → 已被领取
- `isLocked && !isExpired` → 可以领取

### Step 3: 获取代币展示信息

用 ERC20 的 `symbol()` 和 `decimals()` 做金额展示。可以用 `multicall` 合并为一次 RPC 请求：

```typescript
import { erc20Abi } from "viem";

const [symbolResult, decimalsResult] = await publicClient.multicall({
  contracts: [
    { address: info.token, abi: erc20Abi, functionName: "symbol" },
    { address: info.token, abi: erc20Abi, functionName: "decimals" },
  ],
});
```

### Step 4: 生成签名 Digest

用户确认领取后，调用 `getWithdrawDigest` 生成待签名的 EIP-712 digest：

```typescript
const digest = await publicClient.readContract({
  address: FORGEPOOL_ADDRESS,
  abi: ForgePoolABI,
  functionName: "getWithdrawDigest",
  args: [unlockAddress, recipientAddress, feeBps],
});
```

参数说明：

| 参数 | 说明 |
|------|------|
| `unlockAddress` | 卡片公钥地址（Step 1 获取） |
| `recipientAddress` | 收款人地址（用户的钱包地址） |
| `feeBps` | 手续费比例（基点，如 `200n` = 2%），仅 Relayer 路径生效 |

### Step 5: 硬件设备签名

将 digest（32 字节）发送给硬件设备，设备用内置私钥签名后返回 `v`, `r`, `s`。

### Step 6: 提交提取交易

有两种提取路径：

#### 方式 A: Relayer 代付 Gas（推荐）

App 将签名提交给后端 Relayer API，由 Relayer 发交易调用 `withdrawFromCardByRelayer`，按 `feeBps` 扣手续费。

这是推荐的方式。收红包的用户不需要持有 ETH、不需要管理钱包私钥，只需提供收款地址和硬件签名即可。对新用户体验最友好。

查询手续费范围：

```typescript
const { minFeeBps, maxFeeBps } = await getFeeRange();
// minFeeBps: 50 (0.5%), maxFeeBps: 1000 (10%)
```

MVP 阶段先用 `minFeeBps` 作为手续费，后续后端根据队列计算并提供 API。

##### Relayer API

**`POST /api/withdrawal`** — 提交提取请求

Request:

```json
{
  "unlockAddress": "0x...",
  "to": "0x...",
  "feeBps": 50,
  "v": 27,
  "r": "0x...",
  "s": "0x..."
}
```

Response:

```json
{
  "unlockAddress": "0x..."
}
```

Error Response:

```json
{
  "error": "NO_DEPOSIT | ALREADY_UNLOCKED | INVALID_SIGNATURE | INTERNAL_ERROR",
  "message": "no deposit found"
}
```

**`GET /api/withdrawal/:unlockAddress`** — 查询提取状态

Response:

```json
{
  "unlockAddress": "0x...",
  "status": "unknown | pending | submitted | confirmed | failed",
  "txHash": "0x...",
  "blockNumber": 12345678
}
```

状态流转：

```
unknown → pending → submitted → confirmed
                            ↘ failed
```

| 状态 | 含义 |
|------|------|
| `unknown` | Relayer 无此记录，未提交过 |
| `pending` | 已收到请求，排队中 |
| `submitted` | 交易已发送，等待确认 |
| `confirmed` | 链上已确认 |
| `failed` | 交易失败 |

Relayer 处理流程：

```
App 提交 POST /api/withdrawal
     │
     ▼
Relayer 校验参数
├── getDepositInfo 确认红包存在且未领取
├── 链下验签
│
├── 失败 → 返回错误
│
└── 通过
     │
     ▼
调用 withdrawFromCardByRelayer(unlockAddress, to, feeBps, v, r, s)
     │
     ▼
返回 unlockAddress → App 轮询 GET /api/withdrawal/:unlockAddress
```

#### 方式 B: 用户自付 Gas（`withdrawFromCard`）

全额到账，不扣手续费。但用户需要有一个独立的钱包（持有 ETH 付 Gas），在移动端实现较复杂，mvp阶段可以先不实现。
```typescript
const txHash = await walletClient.writeContract({
  address: FORGEPOOL_ADDRESS,
  abi: ForgePoolABI,
  functionName: "withdrawFromCard",
  args: [unlockAddress, recipientAddress, feeBps, v, r, s],
});
```

## 完整流程图

```
app连接钱包
       │
       ▼
获取 unlockAddress
       │
       ▼
getDepositInfo(unlockAddress) ──→ 展示红包信息
       │                          (金额、代币、状态)
       ▼
  红包可领取？
   ├── 否 → 提示"已领取"或"不存在"
   │
   └── 是
       │
       ▼
getWithdrawDigest(unlockAddress, to, feeBps) ──→ 得到 digest
       │
       ▼
发送 digest 到硬件设备签名 ──→ 得到 v, r, s
       │
       ▼
   选择提取方式
   ├── Relayer（推荐）→ 提交签名到 Relayer API
   │                     扣除手续费后到账，用户无需持有 ETH
   │
   └── 自付 Gas → withdrawFromCard(unlockAddress, to, feeBps, v, r, s)
                   全额到账，需要独立钱包付 Gas
```

## 运行示例代码

| 变量 | 必填 | 说明 |
|------|------|------|
| `FORGEPOOL_ADDRESS` | 是 | ForgePool 合约地址 |
| `RPC_URL` | 是 | 测试网RPC 节点地址 |


```bash
cd contract/integration-examples/viem
npm install
npx tsx src/index.ts
```
