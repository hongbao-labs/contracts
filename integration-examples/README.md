# HongBao 钱包 App 集成示例

本目录提供 HongBao 红包合约的钱包 App 集成示例与文档。两个变体共享同一套交互模型（**读取卡信息 → 生成 EIP-712 digest → 硬件设备签名 → 提交 withdraw**），仅在底层资产类型上不同。

## 目录

| 变体 | 资产 | 合约 | 集成文档 | 示例代码 |
|------|------|------|----------|----------|
| Token | ERC20 | `HongBaoTokenPool` | [token/README.md](./token/README.md) | [token/viem](./token/viem/) |
| NFT   | ERC721 | `HongBaoNFTPool` | [nft/README.md](./nft/README.md) | [nft/viem](./nft/viem/) |

## 选择哪一个？

- 项目方派发的是同质化代币（USDT、自有 ERC20 等）→ **Token**
- 项目方派发的是单件 NFT（藏品、入场券、白名单凭证等）→ **NFT**

两类合约由各自的 Factory（`HongBaoTokenFactory` / `HongBaoNFTFactory`）独立部署，互不依赖。

## 共同设计

无论 Token 还是 NFT 版本，钱包 App 都按同样的步骤集成：

1. 从硬件设备读到 `unlockAddress`（卡片地址）
2. 调 pool 的 view 函数读取卡片信息（金额或 tokenId、过期时间、是否已领取）
3. 用户填入收款地址 `to`，调 `getWithdrawDigest(unlockAddress, to)` 拿到 32 字节 digest
4. 把 digest 送进硬件设备签名，拿到 `(v, r, s)`
5. 任意 EOA 提交 `withdraw(unlockAddress, to, v, r, s)` —— 合约不限制调用者

EIP-712 schema 在两个合约中完全一致：

```
Withdraw(address unlockAddress, address to)
Domain: name="HongBao", version="1", chainId, verifyingContract
```

签名脚本、digest 本地打包逻辑可以在两个变体间复用。

## 主要差异

| 方面 | Token | NFT |
|------|-------|-----|
| Pool 模式 | 开放 / 限定（initiator 是否为 0） | 仅限定模式 |
| 一卡多次充值 (topup) | 支持 | 不支持 |
| 关键卡字段 | `cardTotal` (uint256) | `cardTokenId` (uint256) |
| 卡是否存在的判定 | `cardTotal != 0 \|\| cardUnlockedAt != 0` | `cardExpire != 0`（tokenId=0 是合法值）|
| 资产合约入口 | `lockedToken()` | `lockedCollection()` |
| Withdraw 转账 | `IERC20.transfer` | `IERC721.safeTransferFrom` |
| 收款地址 `to` 校验 | 无特殊要求 | **必须**能接收 ERC721；签名前要校验 |
| 展示元数据 | `symbol()` / `decimals()` | `name()` / `symbol()` / `tokenURI()`（均可选）|

NFT 版本最关键的差异：硬件设备每张卡只能签一次。**一旦让设备对错误的 `to` 签了名（例如不能接收 ERC721 的合约），这张卡就报废了**——签名已经用掉，但链上资产无法转出。集成方必须在让设备签名前校验 `to`。详见 [nft/README.md](./nft/README.md) Step 5。

## 跑示例代码

```bash
cd integration-examples
npm install

npm run example:token   # Token 变体
npm run example:nft     # NFT 变体
```

或直接跑某个脚本：

```bash
npx tsx nft/viem/src/withdraw-cli.ts
npx tsx token/viem/src/create-pool.ts
```

需要的环境变量见各自 README。
