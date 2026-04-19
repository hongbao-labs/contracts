# HongBao Token (ERC20) 钱包 App 集成（收红包）

## 概述

本文档描述钱包 App 如何集成 `HongBaoTokenPool` 合约，实现 ERC20 "收红包"功能。

核心流程：**读取红包信息 → 生成签名数据 → 硬件设备签名 → 提交 withdraw 交易**。

合约无手续费、无特权中继，`withdraw` 由**任何人**提交即可。Gas 代付是可选的应用层服务（不在合约范围内）。

## 前置条件

- `HongBaoTokenPool` 合约地址（由项目方通过 `HongBaoTokenFactory` 部署得到）
- RPC 节点

## 合约 ABI

```typescript
import { parseAbi } from "viem";

const HongBaoTokenPoolABI = parseAbi([
  "function lockedToken() view returns (address)",
  "function cardTotal(address unlockAddress) view returns (uint256)",
  "function cardExpire(address unlockAddress) view returns (uint256)",
  "function cardUnlockedAt(address unlockAddress) view returns (uint256)",
  "function isLocked(address unlockAddress) view returns (bool)",
  "function isExpired(address unlockAddress) view returns (bool)",
  "function remainingLockTime(address unlockAddress) view returns (uint256)",
  "function getWithdrawDigest(address unlockAddress, address to) view returns (bytes32)",
  "function withdraw(address unlockAddress, address to, uint8 v, bytes32 r, bytes32 s)",
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

## 完整流程图

```
app 连接钱包
     │
     ▼
获取 unlockAddress（硬件设备）
     │
     ▼
读取 cardTotal / cardExpire / cardUnlockedAt ──→ 展示红包信息
     │
     ▼
  可领取？
   ├── 否 → 提示"已领取"或"不存在"
   │
   └── 是
       │
       ▼
   getWithdrawDigest(unlockAddress, to) ──→ digest
       │
       ▼
   发送 digest 到硬件设备签名 ──→ v, r, s
       │
       ▼
   提交 withdraw(unlockAddress, to, v, r, s)
   ├── 自有钱包发交易
   └── 转交给代付服务（可选，纯业务层）
```

## 运行示例代码

| 变量 | 必填 | 说明 |
|------|------|------|
| `POOL_ADDRESS` | 是 | HongBaoTokenPool 合约地址 |
| `RPC_URL` | 是 | RPC 节点地址 |

```bash
cd integration-examples/token/viem
npm install
npx tsx src/index.ts
```
