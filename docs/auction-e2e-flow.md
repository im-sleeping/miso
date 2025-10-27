# 拍卖全流程梳理（创建 / 参与 / 结算 / 领取 / 加池 / 锁仓）

本流程覆盖五类拍卖合约：Crowdsale、DutchAuction、BatchAuction、HyperbolicAuction、ProRataFixedPrice，并串联工厂与后续加池组件，给出前端可直接调用的清单与要点。

核心合约入口
- MISOMarket 工厂：contracts/MISOMarket.sol:52
- 拍卖模板：
  - Crowdsale：contracts/Auctions/Crowdsale.sol:1
  - DutchAuction：contracts/Auctions/DutchAuction.sol:57
  - BatchAuction：contracts/Auctions/BatchAuction.sol:54
  - HyperbolicAuction：contracts/Auctions/HyperbolicAuction.sol:104
  - ProRataFixedPrice：contracts/Auctions/ProRataFixedPrice.sol:1
- 名单与额度：
  - ListFactory：contracts/Access/ListFactory.sol:1
  - PointList：contracts/Access/PointList.sol:1
- 加池与锁仓（Post-Auction）：
  - MISOLauncher 工厂：contracts/MISOLauncher.sol:51
  - PostAuctionLauncher：contracts/Liquidity/PostAuctionLauncher.sol:1
- 一键编排（可选）：contracts/Recipes/AuctionCreation.sol:1
- 查询辅助（可选）：contracts/Helper/MISOHelper.sol:1


## 创建（工厂或一键编排）

方式 A：通过 MISOMarket.createMarket
- 读取模板类型与 ID：
  - 模板类型常量（拍卖合约 `marketTemplate()`）：Crowdsale=1、Dutch=2、Batch=3、Hyperbolic=4、ProRataFixedPrice=5。
  - 取当前模板 ID：`MISOMarket.currentTemplateId[type]`。
- 组装初始化数据 `_data`：使用拍卖合约提供的 `get*InitData(...)` 生成（各合约为 `pure` 编码函数）。
  - Crowdsale：`getCrowdsaleInitData(...)`（价格 `rate`、`goal`、`start/endTime`、`pointList`、`wallet` 等）
  - DutchAuction：`getAuctionInitData(...)`（`startPrice`、`minimumPrice`、`start/endTime`、`pointList`、`wallet` 等）
  - BatchAuction：`getBatchAuctionInitData(...)`（`minimumCommitmentAmount`、`start/endTime`、`pointList`、`wallet` 等）
  - HyperbolicAuction：`getAuctionInitData(...)`（`minimumPrice`、`factor`、`start/endTime`、`pointList`、`wallet` 等）
  - ProRataFixedPrice：`getProRataInitData(...)`（固定价 `rate`、最低募资 `goal`、`start/endTime`、`pointList`、`wallet` 等）
- 代币与费用前置：
  - 创建方需先 `approve(MISOMarket, tokenSupply)`
  - 交易 `value` ≥ `MISOMarket.minimumFee()`
- 调用：`MISOMarket.createMarket(templateId, token, tokenSupply, integratorFeeAccount, data)` → 返回新拍卖地址。
- 注意：若启用白名单/额度，`data` 中传入 `pointList` 地址（见“名单/额度”）。

方式 B：一键编排 AuctionCreation.prepareMiso（可选）
- 合约：contracts/Recipes/AuctionCreation.sol:1
- 步骤串联：创建代币 →（可选）创建 PointList → 创建拍卖 → 创建 Launcher → 将拍卖 `wallet` 设为新 Launcher。
- 前端仅需一次调用并准备四段编码数据：`tokenFactoryData`、`accounts/amounts`、`marketData`、`launcherData`。

名单/额度（可选）
- 新建额度名单：`ListFactory.deployPointList(listOwner, accounts[], amounts[])` → 返回 `pointList`。
- 拍卖若开启 `usePointList`，参与者承诺额累加要通过 `IPointList.hasPoints(user, newAmount)` 校验。


## 参与（承诺资金）

通用规则
- 支付币种：若 `paymentCurrency == ETH_ADDRESS` → 使用 `commitEth(beneficiary, agreed=true)`；否则先 `approve(auction, amount)`，再 `commitTokens(amount, agreed=true)` 或 `commitTokensFrom(from, amount, agreed=true)`。
- 同意条款：所有 `commit*` 均需 `readAndAgreedToMarketParticipationAgreement=true`，否则会 revert。
- 白名单/额度：启用时，超过额度会 revert。

拍卖入口（函数同名，语义一致）
- Crowdsale：`commitEth` / `commitTokens` / `commitTokensFrom`
  - 超额逻辑：按 `calculateCommitment` 自动截断，多余 ETH/代币退回。
- DutchAuction：`commitEth` / `commitTokens` / `commitTokensFrom`
  - 前端可先读 `calculateCommitment(x)` 与 `clearingPrice()` 做预估。
- BatchAuction：`commitEth` / `commitTokens` / `commitTokensFrom`
  - 价格为平均成交价，最终统一结算；需达到 `minimumCommitmentAmount`。
- HyperbolicAuction：`commitEth` / `commitTokens` / `commitTokensFrom`
  - `priceFunction()` 在开始前返回 `-1`，前端需禁用购买显示“未开始”。
 - ProRataFixedPrice：`commitEth` / `commitTokens` / `commitTokensFrom`
  - 固定单价，允许超募，不截断；超出部分在领取阶段按比例退款。


## 结算（finalize / cancel）

通用规则
- 谁可结算：`admin`、`wallet`、有特殊合约角色者，或结束后 7 天任何人（`finalizeTimeExpired()`）。
- 分支：
  - 成功：将募集到的支付资产转给 `wallet`；（Crowdsale 还会把“未售代币”退给 `wallet`）
  - 失败：将全部/剩余拍卖代币退给 `wallet`（参与者后续提现退款）。
- 取消（未开始且无承诺）：`cancelAuction()`（管理员）。

各拍卖判断
- Crowdsale：`auctionSuccessful()` 为 `commitmentsTotal >= goal`；`auctionEnded()` 为过 `endTime` 或已售罄。
- Dutch/Hyperbolic：成功条件为 `tokenPrice() >= clearingPrice()`（清算价与平均价取大）；结束为成功或过 `endTime`。
- Batch：成功条件为 `commitmentsTotal >= minimumCommitmentAmount` 且 >0；结束为过 `endTime`。
 - ProRataFixedPrice：成功条件为 `commitmentsTotal >= goal` 且 >0；结束仅以过 `endTime`（不会因满额提前结束）。


## 领取（claim 或退款）

通用入口
- `withdrawTokens([beneficiary])`
  - 成功拍卖：需 `finalized == true` 后，用户可领取代币；数量由 `tokensClaimable(user)` 确定。
  - 失败拍卖：过 `endTime` 后，用户可领取退款（ETH 或支付代币）。

按类型的可领计算
- Crowdsale：固定单价；`tokensClaimable(user)` 基于 `rate` 与`commitments`。
- Dutch/Hyperbolic：按占比分配；`tokensClaimable(user) = commitments[user] * totalTokens / commitmentsTotal`（减去已领）。
- Batch：按平均价分配；`_getTokenAmount(commit)` 基于 `commit * 1e18 / tokenPrice()`。
 - ProRataFixedPrice：固定价下的按比例分配；
   - 定义 `maxC = totalTokens * rate / 1e18`，`acceptedTotal = min(commitmentsTotal, maxC)`；
   - 每地址 `accepted_i = (commit_i)` 或超募时 `commit_i * acceptedTotal / commitmentsTotal`；
   - 可领代币 `tokens_i = accepted_i * 1e18 / rate`（`tokensClaimable` 已扣除已领且受剩余代币余额约束）。


## 加池 / 锁仓（Post‑Auction Launcher）

创建方式
- MISOLauncher.createLauncher 或由 AuctionCreation.prepareMiso 自动创建。
- Launcher 合约：contracts/Liquidity/PostAuctionLauncher.sol:1

关键流程与函数
- 连接拍卖与钱包：拍卖的 `wallet` 必须设置为 Launcher 地址（`marketConnected()` 才为真）。
  - 一键编排已自动在创建后 `setAuctionWallet(newLauncher)`；非编排路径需手动设置。
- Launcher.finalize()
  - 若拍卖未 `finalized`，会先调用 `market.finalize()`。
  - 检查 `auctionSuccessful()`，计算应注入的两边资产，必要时创建交易对，转入两边资产并 `mint` LP。
  - 记录 `liquidityAdded`，并设置首次 `unlock` 时间（`block.timestamp + locktime`）。
- 取回 LP：`withdrawLPTokens()`（需到 `unlock` 且管理员/运营者权限），将 LP 转给 `wallet`。
- 存入资产：`depositETH()`、`depositToken1/2(amount)`（用于补充做市资产，未启动前）。

参数与显示
- `liquidityPercent`：将拍卖所得支付资产的百分比用于做市（精度 10000）。
- `locktime`：LP 锁仓时长（秒），`unlock` 达到后可提取。
- `getTokenAmounts()`：前端可展示预计注入的两边资产数量（按拍卖清算价格对齐两边）。


## 查询与列表（可选）

- 使用 MISOHelper 聚合：contracts/Helper/MISOHelper.sol:1
  - `getMarkets()`/`get*AuctionInfo(addr)`：分页或全量列出市场，查询拍卖详情（时间、价格、文档、货币、是否成功等）。
  - `getUserMarketInfo(auction, user)`：用户在某拍卖的承诺、可领、已领、是否管理员等。


## 常见注意事项

- 代币精度：出售 `auctionToken` 必须 18 位小数；`paymentCurrency` 若非 ETH，也需是标准 ERC20。
- 时间戳秒级：传入时间需 < 1e10，否则触发“请使用秒级时间戳而非毫秒”。
- 参与函数匹配支付币种：ETH 仅限 `commitEth`；ERC20 需先 `approve` 后 `commitTokens`。
- 白名单/额度：启用 `pointList` 时，前端需在提交前做额度预校验，避免链上回滚。
- 结算权限与超时：`finalize()` 支持角色与超时后开放；成功拍卖的领取必须在 `finalized` 之后。
- Gas 与退款：Crowdsale/Dutch/Hyperbolic 对超额有自动退款逻辑（ETH 直接退回，多 Token 仅转入实际需要部分）。


## PointList 与 Launcher 整合（深入）

### PointList 机制与用法

- 概念：按地址设置“额度点数”，用于限制单地址的最大承诺总额。核心合约：`contracts/Access/PointList.sol:17`，工厂：`contracts/Access/ListFactory.sol:48`。
- 判定接口：
  - `isInList(account)`：是否有任意额度（>0）。
  - `hasPoints(account, amount)`：账户额度是否 ≥ 指定 amount（拍卖在累计承诺 newCommitment 时调用）。
- 创建与初始化：
  - `ListFactory.deployPointList(listOwner, accounts[], amounts[])` → 返回新 `pointList` 地址；需支付 `minimumFee`。
  - 若传入数组非空：工厂临时作为 admin 设置额度，随后将 `listOwner` 设为 admin 并移除自身权限。
  - 后续调整额度：由 `listOwner` 或具有 operator 权限的地址，调用 `PointList.setPoints(accounts[], amounts[])` 批量更新。
- 与拍卖的集成：
  - 拍卖存储 `pointList` 地址与 `usePointList` 开关；提交时在 `_addCommitment` 中校验 `hasPoints(user, newCommitment)`：
    - Crowdsale：`contracts/Auctions/Crowdsale.sol:322`
    - Dutch：`contracts/Auctions/DutchAuction.sol:447`
    - Batch：`contracts/Auctions/BatchAuction.sol:251`
    - Hyperbolic：`contracts/Auctions/HyperbolicAuction.sol:365`
    - ProRataFixedPrice：`contracts/Auctions/ProRataFixedPrice.sol:203`
  - 管理入口：
    - `setList(pointList)`：绑定名单地址；`enableList(true/false)`：启用/停用校验。
- 前端建议：
  - 在链上提交前调用 `hasPoints(user, userCommit + input)` 预校验，避免回滚。
  - 展示用户剩余额度 `points[user] - commitments[user]`（需额外查询 commitments）。


### MISOLauncher 与 PostAuctionLauncher（做市与锁仓）

- 角色与工厂：
  - `MISOLauncher`（工厂）：`contracts/MISOLauncher.sol:51`，用于克隆并初始化做市模板；需支付 `launcher.minimumFee()`。
  - `PostAuctionLauncher`（模板）：`contracts/Liquidity/PostAuctionLauncher.sol:54`，在拍卖结束后，将一部分支付资产与出售代币按拍卖价格注入 SushiSwap 池，并可锁定 LP。
- 初始化数据与参数：
  - `initLauncher(abi.encode(market, factory, admin, wallet, liquidityPercent, locktime))`。
  - `market`：拍卖合约地址；`factory`：UniswapV2/Sushi 工厂；`admin`：管理者；`wallet`：收益/提取目的地；
  - `liquidityPercent`：把拍卖所得支付资产的百分比用于做市（精度 10000，对应 0–100.00%）；`locktime`：LP 锁仓时长（秒）。
- 与拍卖的连接方式：
  - Launcher 需要成为拍卖的 `wallet`，这样 finalize 后拍卖所得会进入 Launcher，由其再进行做市。
  - 一键编排 `AuctionCreation.prepareMiso` 已在创建 Launcher 后自动执行 `IMisoMarket(newMarket).setAuctionWallet(newLauncher)`，手动路径需自行调用同名函数。
- `finalize()` 流程（PostAuctionLauncher）：
  - 若拍卖未结束或未成功，直接失败或仅回收代币；若拍卖未 `finalized`，会先调用 `market.finalize()`。
  - 计算两侧注入数量：读取 `market.tokenPrice()` 与两侧代币 `decimals()`，再按 `liquidityPercent` 与价格对齐两边资产（`getTokenAmounts()`）。
  - 若 `paymentCurrency` 为 ETH，会将合约余额包装为 WETH；随后创建交易对（若不存在），向 Pair 转入两侧资产并 `mint` LP。
  - 首次铸造 LP 时记录 `unlock = block.timestamp + locktime`，并累计 `liquidityAdded`。
  - 事后操作：
    - `withdrawLPTokens()`：到期后（达到 `unlock`），将 LP 转给 `wallet`（需 admin/operator）。
    - `withdrawDeposits()`：做市后仍残留在 Launcher 的两侧资产可提走（需 admin/operator）。
    - 辅助显示：`getTokenAmounts()`、`getLPTokenAddress()`、`getLPBalance()`、`getToken1/2Balance()`。


### 推荐整合路径

- 一键编排（推荐）：
  - 使用 `AuctionCreation.prepareMiso`，一次性完成：创建代币 →（可选）PointList → 创建拍卖 → 创建 Launcher → 将拍卖 `wallet` 指向 Launcher。
  - 仅需准备四段编码：`tokenFactoryData`、`accounts/amounts`、`marketData`、`launcherData`（详见上文“创建”）。
- 手动工厂路径：
  - A. 若需要名单：通过 `ListFactory.deployPointList` 部署名单，并在拍卖初始化数据中传入 `pointList`；拍卖部署后可 `enableList(true)`。
  - B. 创建拍卖：`MISOMarket.createMarket(templateId, token, tokenSupply, integrator, data)`，并按模板提供的 `get*InitData(...)` 生成 `data`。
  - C. （可选）创建 Launcher：`MISOLauncher.createLauncher(templateId, token, tokenForLiquidity, integrator, launcherData)`，随后调用 `auction.setAuctionWallet(launcher)`。
  - D. 等拍卖成功并 `finalize()` 后，由 Launcher 进行做市与锁仓管理。


### 常见对接坑位

- 忘记把拍卖 `wallet` 指向 Launcher，导致做市资金未进入 Launcher（`finalize()` 后余额不在 Launcher）。
- `liquidityPercent` 设置过大/过小，或拍卖规模太小，导致 `getTokenAmounts()` 一侧为 0，从而无法开池。
- 代币精度与价格：出售代币必须 18 位，否则 `tokenPrice()` 与做市对齐会出现数量级错误。
- 名单额度：`usePointList` 开启后，未提前校验额度导致链上回滚；建议前端预校验 `hasPoints`。
- 时间戳单位：所有时间参数均为“秒”（< 1e10）；传毫秒会触发显式的 require 报错。
