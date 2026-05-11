# HongBao NFT (ERC721) 钱包 App 集成（收红包）

## 概述

本文档描述钱包 App 如何集成 `HongBaoNFTPool` 合约，实现 NFT "收红包"功能。

核心流程：**读取红包信息 → 生成签名数据 → 硬件设备签名 → 提交 withdraw 交易**。与 ERC20 版本同构，主要差异：

- 单张卡绑定一个 tokenId（不支持 topup，不支持开放模式）
- `withdraw` / `withdrawExpired` 使用 `safeTransferFrom` — 收款地址必须能接收 ERC721
- 展示层需要读 ERC721 的 `tokenURI` / collection metadata，而不是 `symbol/decimals`

合约无手续费、无特权中继，`withdraw` 由**任何人**提交即可。Gas 代付是可选的应用层服务（不在合约范围内）。

## 前置条件

- `HongBaoNFTPool` 合约地址（由项目方通过 `HongBaoNFTFactory` 部署得到）
- RPC 节点

## 合约 ABI

```typescript
import { parseAbi } from "viem";

const HongBaoNFTPoolABI = parseAbi([
  "function lockedCollection() view returns (address)",
  "function cardTokenId(address unlockAddress) view returns (uint256)",
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
const [tokenId, expire, unlockedAt, collection] = await Promise.all([
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "cardTokenId", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "cardExpire", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "cardUnlockedAt", args: [unlockAddress] }),
  publicClient.readContract({ address: POOL, abi: HongBaoNFTPoolABI, functionName: "lockedCollection" }),
]);

const now = BigInt(Math.floor(Date.now() / 1000));
const exists = expire !== 0n;             // tokenId=0 是合法 id，需要用 expire 判断
const isLocked = exists && unlockedAt === 0n;
const isExpired = isLocked && now >= expire;
```

状态判断：

| 条件 | 含义 |
|------|------|
| `expire === 0` | 红包不存在 |
| `unlockedAt !== 0` | 已被领取（或已被 initiator 回收） |
| `expire > 0 && unlockedAt === 0 && now < expire` | 可领取 |
| `expire > 0 && unlockedAt === 0 && now >= expire` | 已过期（持卡人仍可用签名领取，直到 initiator 回收为止） |

> ⚠️ ERC721 中 `tokenId === 0` 是合法取值，不能用它判断红包是否存在。必须用 `cardExpire !== 0`。

### Step 3: 获取 NFT 展示信息

从 `lockedCollection()` 拿到 ERC721 地址，按需读取 collection metadata 和具体 tokenURI：

```typescript
const erc721MetadataAbi = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function tokenURI(uint256 tokenId) view returns (string)",
]);

const [nameResult, symbolResult, uriResult] = await publicClient.multicall({
  contracts: [
    { address: collection, abi: erc721MetadataAbi, functionName: "name" },
    { address: collection, abi: erc721MetadataAbi, functionName: "symbol" },
    { address: collection, abi: erc721MetadataAbi, functionName: "tokenURI", args: [tokenId] },
  ],
});
```

> ERC721 metadata extension 是**可选**的：有些 NFT 合约不实现 `name/symbol/tokenURI`。接入方要容忍 `multicall` 中单项失败，不能拿不到 symbol 就整个报错。

### Step 4: 生成签名 Digest

用户确认领取并输入收款地址后：

```typescript
const digest = await publicClient.readContract({
  address: POOL,
  abi: HongBaoNFTPoolABI,
  functionName: "getWithdrawDigest",
  args: [unlockAddress, recipientAddress],
});
```

EIP-712 schema 与 ERC20 版本完全相同：

```
Withdraw(address unlockAddress, address to)
Domain: name="HongBao", version="1", chainId, verifyingContract
```

### Step 5: 硬件设备签名

将 digest（32 字节）发给硬件设备，设备用内置私钥签名后返回 `v`, `r`, `s`。

> ⚠️ **`to` 必须能接收 ERC721**。合约内部使用 `safeTransferFrom`：如果 `to` 是合约且未实现 `IERC721Receiver`，转账会 revert。由于硬件设备每张卡**只能签一次**，如果用错了 `to`、签名完了才发现对方不收 NFT，这张卡事实上就报废了——签名已经用掉，但链上资产没释放。
>
> 集成方**必须**在让设备签名前校验 `to`：
> - 建议优先 EOA（普通用户钱包地址）
> - 若允许合约地址，应当 off-chain 先调用 `IERC165.supportsInterface(0x150b7a02)` 或 `IERC721Receiver.onERC721Received` dry-run 验证
> - UI 提示用户："确认后将不可更改收款地址"

### Step 6: 提交 withdraw 交易

`withdraw` 合约函数无调用者限制，任何地址都能提交。

#### 方式 A: 应用自有钱包付 gas

```typescript
const txHash = await walletClient.writeContract({
  address: POOL,
  abi: HongBaoNFTPoolABI,
  functionName: "withdraw",
  args: [unlockAddress, recipientAddress, v, r, s],
});
```

#### 方式 B: 由代付服务提交（可选）

如果产品要做"用户零 ETH 体验"，App 后端或第三方服务接收 `(unlockAddress, to, v, r, s)`，再以自己的钱包发交易。合约层不关心。

## 完整流程图

```
app 连接钱包
     │
     ▼
获取 unlockAddress（硬件设备）
     │
     ▼
读取 cardTokenId / cardExpire / cardUnlockedAt ──→ 展示红包 NFT 信息
     │
     ▼
  可领取？
   ├── 否 → 提示"已领取"或"不存在"
   │
   └── 是
       │
       ▼
   校验 to 能否接收 ERC721 (safeTransferFrom 兼容)
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
| `POOL_ADDRESS` | 是 | HongBaoNFTPool 合约地址 |
| `RPC_URL` | 是 | RPC 节点地址 |

```bash
cd integration-examples
npm install
npm run example:nft
```
