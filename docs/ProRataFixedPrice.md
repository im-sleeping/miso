# ProRataFixedPrice 拍卖对接说明（固定价 + 按比例分配 + 最低募资额）

- 合约文件：`miso/contracts/Auctions/ProRataFixedPrice.sol`
- 模板 ID：`marketTemplate() = 5`
- 出售代币需 18 位小数；支付币种支持 ETH 哨兵地址或标准 ERC20

## 模型概述

- 固定参数：
  - `totalTokens`（出售代币总量，18 位）
  - `rate`（每 1 个出售代币的价格，单位=支付币）
  - `goal`（最低募资额，单位=支付币）
- 参与期：
  - 任意地址可在时间窗内多次 commit；不截断、不即时退款（溢出在结算时按比例退款）
  - 可选启用 `PointList` 做单地址额度：`hasPoints(user, newCommitment)`
- 结算与分配：
  - 若 `commitmentsTotal < goal` → 失败：所有出售代币退回 `wallet`；用户后续全额退款
  - 若 `commitmentsTotal >= goal` → 成功：
    - 可接受总额 `acceptedTotal = min(commitmentsTotal, totalTokens * rate / 1e18)`
    - 每地址被接受资金 `accepted_i = commit_i`（未超额）或 `commit_i * acceptedTotal / commitmentsTotal`（超额按比例）
    - 每地址代币 `tokens_i = accepted_i * 1e18 / rate`
    - 退款 `refund_i = commit_i - accepted_i`

## 关键存储与视图

- `marketInfo() -> (startTime, endTime, totalTokens)`
- `marketPrice() -> (rate, goal)`（与 Crowdsale 一致的存储方式）
- `marketStatus() -> (commitmentsTotal, finalized, usePointList)`
- `auctionToken()`，`paymentCurrency()`，`wallet()`
- `tokenPrice()` → 返回 `rate`
- `auctionEnded()` → `block.timestamp > endTime`（不因满额提前结束）
- `auctionSuccessful()` → `commitmentsTotal >= goal && commitmentsTotal > 0`
- 辅助：
  - `maxCommitment()` = `totalTokens * rate / 1e18`
  - `getProRataInitData(...)` 生成初始化编码传给 `initMarket`

## 参与与管理接口

- 参与提交：
  - ETH：`commitEth(beneficiary, agreed)`（`paymentCurrency == ETH_SENTINEL`）
  - ERC20：先 `approve(auction, amount)`，再 `commitTokens(amount, agreed)` 或 `commitTokensFrom(from, amount, agreed)`
  - 所有 `commit*` 均需 `agreed == true`
- 结算与领取：
  - `finalize()`（`admin/smartContract/wallet` 或 `finalizeTimeExpired()`）
    - 成功：将 `acceptedTotal` 转给 `wallet`；未售代币退回 `wallet`
    - 失败：将全部出售代币退回 `wallet`
  - `withdrawTokens([beneficiary])`
    - 成功：发放代币（扣除已领 `claimed`）+ 退超额（扣除已退 `refunded`）
    - 失败：全额退款（扣除已退 `refunded`）
- 管理：
  - `setAuctionTime(startTime, endTime)`（开始前）
  - `setAuctionPrice(rate, goal)`（开始前；两个参数需一并设定）
  - `setAuctionWallet(wallet)`；`setList(pointList)`；`enableList(on/off)`

## 事件与监听建议

- 生命周期：`AuctionDeployed`、`AuctionTimeUpdated`、`AuctionPriceUpdated(rate, goal)`、`AuctionFinalized`、`AuctionCancelled`
- 参与：`AddedCommitment(addr, commitment)`
- 前端建议监听：`AddedCommitment`、`AuctionFinalized`、`AuctionCancelled`，并刷新 `marketInfo/marketStatus/marketPrice`

## 创建与初始化（通过 MISOMarket 工厂）

- 参数编码：`getProRataInitData(funder, token, paymentCurrency, totalTokens, startTime, endTime, rate, goal, admin, pointList, wallet)`
- 创建：`MISOMarket.createMarket(templateId=5, token, tokenSupply, integratorFeeAccount, data)`
- 先决条件：
  - `token.decimals == 18`
  - `rate > 0`，且 `goal <= totalTokens * rate / 1e18`
  - 时间戳为秒级（< 1e10）

## 前端对接要点

- 展示：
  - 价格：`tokenPrice() = rate`
  - 进度：`commitmentsTotal / goal`（注意上限 100%）
  - 时间：相对 `[startTime, endTime]`
- 交互：
  - 提交前不限制输入；如启用白名单，先 `hasPoints(user, newCommitment)` 预检
  - 仅在 `auctionEnded()` 后禁用提交按钮
  - 领取需在 `finalized == true` 之后；失败则展示“全额退款”
- 预估（可选）：
  - `maxC = totalTokens * rate / 1e18`
  - 假设本次输入 `x`，则提交后视角：
    - `newTotal = commitmentsTotal + x`
    - `acceptedTotal = min(newTotal, maxC)`
    - 若超额：`acceptedUserNew ≈ (commitUser + x) * acceptedTotal / newTotal`
    - 代币≈`acceptedUserNew * 1e18 / rate`；退款≈`(commitUser + x) - acceptedUserNew`
- 精度：
  - 代币换算：`tokens = payment * 1e18 / rate`
  - 建议与合约同序计算，避免四舍五入误差

## 常见错误映射

- `enter an unix timestamp in seconds` → 使用秒级时间戳
- `Payment currency is not ETH/token` → 选择正确的提交方式
- `No agreement provided` → 勾选参与协议
- `outside auction hours` → 不在拍卖时间窗
- PointList `hasPoints` 失败 → 额度不足或未在列表中

## 快速参考（读/写）

- 读：`marketInfo()`、`marketPrice()`、`marketStatus()`、`auctionEnded()`、`auctionSuccessful()`、`tokenPrice()`
- 写：`commitEth/commitTokens/commitTokensFrom`、`finalize()`、`withdrawTokens([beneficiary])`
- 管理：`setAuctionTime`、`setAuctionPrice`、`setAuctionWallet`、`setList/enableList`
- 编码：`getProRataInitData(...)` 配合 `MISOMarket.createMarket(...)`
