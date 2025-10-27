# 前端集成文档：四类拍卖合约

适用合约：`contracts/Auctions/BatchAuction.sol`、`contracts/Auctions/Crowdsale.sol`、`contracts/Auctions/DutchAuction.sol`、`contracts/Auctions/HyperbolicAuction.sol`

目标功能：
- 创建各种拍卖（通过 `MISOMarket` 工厂）
- 参与各种拍卖（ETH 或 ERC20 支付）
- 结束后清算（finalize/cancel）
- 领取代币或退款（claim/withdraw）

推荐架构（前端全流程对接）
- 技术栈建议：
  - UI：React/Next.js 或任意现代框架（Vue/Svelte 亦可）
  - 钱包与链交互：`wagmi` + `viem`（或 `ethers`），配合 `@wagmi/core` 事件监听
  - 数据层：`TanStack Query`（react-query）做缓存与失效控制
  - 状态管理：Zustand/Redux（仅存放轻量 UI 状态）
- 分层设计：
  - `contracts/`：ABI 与地址映射（按链 ID）
  - `adapters/`：链上读写适配层（封装对 MISOMarket、各拍卖、MISOHelper、ListFactory、MISOLauncher 的调用）
  - `services/`：业务服务层（组合多合约调用形成领域动作，如“一键创建拍卖”“参与并自动授权”等）
  - `api/`（可选）：Next.js API Route/轻服务，用于索引与搜索缓存；无后端亦可直接读链上 + `MISOHelper`
  - `hooks/`：页面 Hook，衔接 Query 与 Services（例如 `useAuctionDetail`、`useCommit`）
- 多链与环境：
  - 维护 `addresses.{chainId}.json`（存放 `MISOAccessControls/MISOMarket/MISOLauncher/MISOTokenFactory/ListFactory/PostAuctionLauncher` 等地址）
  - 通过 `hardhat-deploy` 的 `deployments/<network>` 或运维发布提供地址清单
  - 仅支持 `@sushiswap/core-sdk` 已配置 `BENTOBOX_ADDRESS/WNATIVE_ADDRESS/FACTORY_ADDRESS` 的网络

核心数据模型（TypeScript，建议）
```ts
export enum AuctionType { Crowdsale = 1, Dutch = 2, Batch = 3, Hyperbolic = 4 }

export type Address = `0x${string}`

export interface AuctionBase {
  address: Address
  templateId: number // on MISOMarket
  type: AuctionType
  auctionToken: Address
  paymentCurrency: Address | 'ETH'
  startTime: number
  endTime: number
  finalized: boolean
}

export interface AuctionDetail extends AuctionBase {
  totalTokens: bigint
  commitmentsTotal: bigint
  // Specifics by type
  // Crowdsale
  rate?: bigint
  goal?: bigint
  // Dutch
  startPrice?: bigint
  minimumPrice?: bigint
  // Batch
  minimumCommitmentAmount?: bigint
  // Hyperbolic
  alpha?: bigint
}

export interface UserAuctionState {
  commitments: bigint
  tokensClaimable: bigint
  claimed: bigint
  isAdmin: boolean
}

export interface CreateAuctionInput {
  type: AuctionType
  token: Address
  tokenSupply: bigint
  pointList?: Address
  // time window
  startTime: number
  endTime: number
  // pricing
  rate?: bigint // crowdsale
  goal?: bigint // crowdsale
  startPrice?: bigint // dutch
  minimumPrice?: bigint // dutch/hyperbolic
  minimumCommitmentAmount?: bigint // batch
  factor?: bigint // hyperbolic
  wallet: Address // proceeds receiver (或 Launcher 地址)
}

export interface LauncherSetupInput {
  market: Address
  factory: Address // UniswapV2Factory
  liquidityPercent: number // 0~10000
  locktime: number // seconds
}
```

对外服务接口（建议 Service 定义）
- 市场与详情
  - `listMarkets(params): Promise<AuctionBase[]>`（优先调用 `MISOHelper.getMarkets`）
  - `getAuctionDetail(addr): Promise<AuctionDetail>`（按模板类型调用 `MISOHelper.get*AuctionInfo`）
  - `getUserState(addr, user): Promise<UserAuctionState>`（`MISOHelper.getUserMarketInfo`）
- 创建
  - `createAuction(input: CreateAuctionInput, opts?): Promise<Address>`
    - 读取 `currentTemplateId[type]` → 生成 `get*InitData` → `MISOMarket.createMarket`
    - 前置：`approve(MISOMarket, tokenSupply)`，`value >= minimumFee()`
- 参与
  - `ensureAllowance(token, owner, spender, amount): Promise<void>`（若 `paymentCurrency` 非 ETH）
  - `commitWithEth(auction, beneficiary, value): Promise<TxReceipt>`
  - `commitWithToken(auction, amount, from?): Promise<TxReceipt>`
- 结算与领取
  - `finalizeAuction(auction): Promise<TxReceipt>`（需要 admin/wallet/角色 或超时）
  - `cancelAuction(auction): Promise<TxReceipt>`（未开始且无承诺）
  - `withdraw(auction, beneficiary?): Promise<TxReceipt>`（成功领取代币或失败退款）
- Launcher（可选，加池/锁仓）
  - `createLauncher(setup: LauncherSetupInput, token, tokenAmount): Promise<Address>`（`MISOLauncher.createLauncher`）
  - `finalizeLauncher(launcher): Promise<TxReceipt>`（会内部 `market.finalize()` 并添加流动性）
  - `withdrawLP(launcher): Promise<TxReceipt>`（到期提 LP）

事件监听与数据一致性
- 监听工厂事件：`MarketCreated(owner, addr, marketTemplate)` 获取新拍卖地址
- 监听拍卖事件：`AddedCommitment`、`AuctionFinalized`、`AuctionCancelled`
- 监听 Launcher 事件：`LiquidityAdded`
- 前端可用 `watchContractEvent`（wagmi/viem）+ Query 失效重刷，或轻后端/Index （The Graph 可选）

前置校验与交互准则
- 时间窗口：`now` 必须在 `[startTime, endTime]` 内才可 `commit*`
- 额度白名单：启用 `pointList` 时，链上会检查 `hasPoints(user, newCommitment)`；前端提前计算并提示
- 函数匹配：`paymentCurrency == ETH_ADDRESS` → 仅可 `commitEth`，否则 `commitTokens`
- 许可授权：
  - 参与前：`ensureAllowance(paymentCurrency, user, auction, amount)`
  - 创建前：`approve(MISOMarket, tokenSupply)`（发起者）
- Gas 与退款：Crowdsale/Dutch/Hyperbolic 超额自动退款；Batch 无“超额”概念但最终按平均价分配
- 价格与可得：
  - Crowdsale：`getTokenAmount(amount)` 直算
  - Dutch/Hyperbolic：显示 `priceFunction()` 与 `clearingPrice()`
  - Batch：显示 `commit * 1e18 / tokenPrice()` 的“估算可得”（最终以结算价格为准）

接口落地示例（伪代码）
```ts
// 1) 创建拍卖（以 Crowdsale 为例）
async function createCrowdsale(i: CreateAuctionInput) {
  const templateId = await misoMarket.currentTemplateId(AuctionType.Crowdsale)
  const data = await crowdsaleContract.getCrowdsaleInitData(
    /* funder */ signer.address,
    /* token */ i.token,
    /* paymentCurrency */ i.paymentCurrency,
    /* totalTokens */ i.tokenSupply,
    /* start */ i.startTime,
    /* end */ i.endTime,
    /* rate */ i.rate,
    /* goal */ i.goal,
    /* admin */ signer.address,
    /* pointList */ i.pointList ?? ethers.constants.AddressZero,
    /* wallet */ i.wallet,
  )
  await ensureAllowance(i.token, signer.address, misoMarket.address, i.tokenSupply)
  const minFee = await misoMarket.minimumFee()
  const tx = await misoMarket.createMarket(templateId, i.token, i.tokenSupply, ZeroAddress, data, { value: minFee })
  const rc = await tx.wait()
  const ev = rc.logs.find(/* MarketCreated */)
  return ev.args.addr as Address
}

// 2) 参与（ERC20）
async function commitWithToken(auction: Address, amount: bigint) {
  const payToken = await auctionContract.paymentCurrency()
  await ensureAllowance(payToken, signer.address, auction, amount)
  return await auctionContract.commitTokens(amount, true)
}

// 3) 结算 & 领取
await auctionContract.finalize() // admin/wallet/role or timeout
await auctionContract.withdrawTokens(signer.address)
```

通用注意事项
- 代币精度：所有拍卖出售的 `auctionToken` 要求 18 位小数。
- ETH 占位地址：`0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`（各合约内定义）
- 白名单/额度列表：若启用 `pointList`，参与者需要在列表内且额度足够。
- 协议同意布尔值：所有 `commit*` 方法都需传入 `readAndAgreedToMarketParticipationAgreement=true`，否则会 revert。
- 参与货币：若 `paymentCurrency == ETH_ADDRESS`，只能用 `commitEth`；否则使用 `commitTokens/commitTokensFrom`，并先对拍卖合约进行 `approve`。
- 结算角色：`finalize()` 可由 `admin`、`wallet`、或具有特定合约角色地址调用；超过结束时间 7 天后，任何人可触发（见各合约 `finalizeTimeExpired`）。
- 文件/元数据：管理员可通过 `setDocument(s)` 维护（仅部分合约暴露）。

工厂创建（MISOMarket）
- 合约：`contracts/MISOMarket.sol:275` `createMarket`（传入模板 ID、出售代币、售卖量、分润地址、初始化数据 `_data`）。
- 模板类型（合约内 `marketTemplate` 常量）：
  - Crowdsale=1（`contracts/Auctions/Crowdsale.sol:1`）
  - DutchAuction=2（`contracts/Auctions/DutchAuction.sol:1`）
  - BatchAuction=3（`contracts/Auctions/BatchAuction.sol:61`）
  - HyperbolicAuction=4（`contracts/Auctions/HyperbolicAuction.sol:117`）
  - ProRataFixedPrice=5（`contracts/Auctions/ProRataFixedPrice.sol:1`）
- 取实际模板 ID：`MISOMarket.currentTemplateId[templateType]`；或通过 `getTemplateId(templateAddress)` 反查。
- 初始化数据编码：各拍卖合约暴露 `get*InitData(...)`（纯函数）用于 `abi.encode(...)` 参数打包：
  - Crowdsale：`getCrowdsaleInitData(...)`（`contracts/Auctions/Crowdsale.sol:420`）
  - DutchAuction：`getAuctionInitData(...)`（`contracts/Auctions/DutchAuction.sol:508`）
  - BatchAuction：`getBatchAuctionInitData(...)`（`contracts/Auctions/BatchAuction.sol:312`）
  - HyperbolicAuction：`getAuctionInitData(...)`（`contracts/Auctions/HyperbolicAuction.sol:392`）
- 代币准备与费用：
  - 在 `createMarket` 前，项目方地址需 `approve(MISOMarket, _tokenSupply)`；调用时 `msg.value >= minimumFee()`。
  - `createMarket` 内部会将售卖代币转入新拍卖合约并执行 `initMarket(_data)`。

接口与错误处理建议
- 统一异常提示：
  - 时间错误：`enter an unix timestamp in seconds` → 统一翻译为“请使用秒级时间戳（小于 1e10）”
  - 权限不足：`sender must be an admin`/`must be operator` → 明确显示需要的角色与当前钱包地址
  - 币种不匹配：`Payment currency is not ETH/token` → 引导选择正确的提交方式
  - 额度不足：`hasPoints` 失败 → 显示剩余额度/已用额度
- 交易前 `simulate/estimateGas`，失败提前拦截并提示具体参数项
- 对关键写操作加“事务状态”：`签名中 → 打包中 → 已上链（N/12 确认）`

—

BatchAuction（批量按比例分配）
- 合约：`contracts/Auctions/BatchAuction.sol:54`
- 概述：固定时段内按承诺总额确定价格，用户按出资额按比例获得代币；未达最小募资额则失败退款。
- 关键变量/视图：
  - `tokenPrice()`（`contracts/Auctions/BatchAuction.sol:272`）：平均成交价=`commitmentsTotal * 1e18 / totalTokens`
  - `auctionSuccessful()`（`contracts/Auctions/BatchAuction.sol:370`）：是否达到 `minimumCommitmentAmount`
  - `auctionEnded()`（`contracts/Auctions/BatchAuction.sol:378`）：`block.timestamp > endTime`
  - `finalized()`（`contracts/Auctions/BatchAuction.sol:386`）与 `finalizeTimeExpired()`（`contracts/Auctions/BatchAuction.sol:391`）
- 参与：
  - ETH：`commitEth(beneficiary, agreed)`（`contracts/Auctions/BatchAuction.sol:201`）
  - ERC20：`commitTokens(amount, agreed)`（`contracts/Auctions/BatchAuction.sol:218`）或 `commitTokensFrom(from, amount, agreed)`（`contracts/Auctions/BatchAuction.sol:228`）
  - 领取数量：`tokensClaimable(user)`（`contracts/Auctions/BatchAuction.sol:355`）按最终价格计算；失败则退款。
- 结算/退款：
  - `finalize()`（`contracts/Auctions/BatchAuction.sol:284`）：成功将募资款打至 `wallet`；失败将未售代币退回 `wallet`。
  - `withdrawTokens([beneficiary])`（`contracts/Auctions/BatchAuction.sol:339`）：成功后领取代币；失败后在结束后领取退款。
- 管理：
  - `setAuctionTime`（`contracts/Auctions/BatchAuction.sol:454`）、`setAuctionPrice`（`contracts/Auctions/BatchAuction.sol:468`）、`setAuctionWallet`（`contracts/Auctions/BatchAuction.sol:481`）需在开始前调用。
  - `cancelAuction()`（`contracts/Auctions/BatchAuction.sol:318`）开始前且未有承诺可取消。
- 事件：
  - `AuctionDeployed`（`contracts/Auctions/BatchAuction.sol:98`）、`AuctionTimeUpdated`（`contracts/Auctions/BatchAuction.sol:100`）、`AuctionPriceUpdated`（`contracts/Auctions/BatchAuction.sol:103`）
  - `AddedCommitment`（`contracts/Auctions/BatchAuction.sol:110`）、`AuctionFinalized`（`contracts/Auctions/BatchAuction.sol:115`）、`AuctionCancelled`（`contracts/Auctions/BatchAuction.sol:117`）
- 前端对接要点：
  - UI 显示“预计获得量”可用 `_getTokenAmount(contribution)` 思路：`contribution * 1e18 / tokenPrice()`；注意实时价格变动与最终结算差异。
  - 开启白名单时需先查询 `pointList.hasPoints(user, newCommitment)`。

—

Crowdsale（固定单价众筹）
- 合约：`contracts/Auctions/Crowdsale.sol:1`
- 概述：固定价格，先到先得，达到硬顶（总售卖量）即售罄；未达 `goal` 则失败。
- 关键变量/视图：
  - `tokenPrice()`（`contracts/Auctions/Crowdsale.sol:435`）即 `rate`
  - `calculateCommitment(x)`（`contracts/Auctions/Crowdsale.sol:298`）会按剩余额度截断（多余自动退款/不转入）
  - `auctionSuccessful()`（`contracts/Auctions/Crowdsale.sol:469`）与 `auctionEnded()`（`contracts/Auctions/Crowdsale.sol:477`）
- 参与：
  - ETH：`commitEth(beneficiary, agreed)`（`contracts/Auctions/Crowdsale.sol:232`），多余自动退款
  - ERC20：`commitTokens/commitTokensFrom`（`contracts/Auctions/Crowdsale.sol:265`、`contracts/Auctions/Crowdsale.sol:275`）
  - 领取数量：`tokensClaimable(user)`（`contracts/Auctions/Crowdsale.sol:342`）按固定单价计算；失败则退款。
- 结算/退款：
  - `finalize()`（`contracts/Auctions/Crowdsale.sol:383`）：成功将募资款打至 `wallet`，并将“未售代币”退回 `wallet`；失败将全部代币退回 `wallet`。
  - `withdrawTokens([beneficiary])`（`contracts/Auctions/Crowdsale.sol:333`、`contracts/Auctions/Crowdsale.sol:342`）
- 管理与事件：
  - `setAuctionTime/Price/Wallet`（`contracts/Auctions/Crowdsale.sol:457` 起多处）仅限开始前；`cancelAuction()`（`contracts/Auctions/Crowdsale.sol:422`）。
  - 事件同 BatchAuction（见 `AuctionDeployed/AddedCommitment/AuctionFinalized/AuctionCancelled`）。
- 前端对接要点：
  - 输入金额 → `getTokenAmount(amount)` 计算可购代币数；显示“剩余额度”可用 `totalTokens - _getTokenAmount(commitmentsTotal)`。
  - ETH 支付时注意 gas 与自动退款逻辑；ERC20 需先 `approve`。

—

DutchAuction（线性下降的荷兰拍）
- 合约：`contracts/Auctions/DutchAuction.sol:1`
- 概述：价格从起始价线性下降至最低价；清算价 `clearingPrice = max(tokenPrice, priceFunction)`。
- 关键变量/视图：
  - `priceFunction()`（`contracts/Auctions/DutchAuction.sol:222`）、`clearingPrice()`（`contracts/Auctions/DutchAuction.sol:238`）
  - `tokenPrice()`（`contracts/Auctions/DutchAuction.sol:213`）= 平均成交价
  - `auctionSuccessful/auctionEnded/finalizeTimeExpired/finalized`（`contracts/Auctions/DutchAuction.sol:397`、`contracts/Auctions/DutchAuction.sol:405`、`contracts/Auctions/DutchAuction.sol:419`、`contracts/Auctions/DutchAuction.sol:412`）
- 参与：
  - ETH：`commitEth`（`contracts/Auctions/DutchAuction.sol:273`），过量自动退款
  - ERC20：`commitTokens/commitTokensFrom`（`contracts/Auctions/DutchAuction.sol:304`、`contracts/Auctions/DutchAuction.sol:315`）
  - 额度判断：`calculateCommitment(x)`（`contracts/Auctions/DutchAuction.sol:402` 上方一段）
  - 领取数量：`tokensClaimable(user)`（`contracts/Auctions/DutchAuction.sol:352`）按承诺占比分配
- 结算/退款：
  - `finalize()`（`contracts/Auctions/DutchAuction.sol:481`）成功将募资款打至 `wallet`；失败在结束后退回代币至 `wallet`。
  - `withdrawTokens([beneficiary])`（`contracts/Auctions/DutchAuction.sol:509`、`contracts/Auctions/DutchAuction.sol:519`）
- 事件与管理：同前述（含 `AuctionDeployed/AuctionFinalized/AuctionCancelled/AddedCommitment`）。
- 前端对接要点：
  - 实时显示 `priceFunction()` 与 `tokenPrice()`，成交价取两者较大值。
  - ETH 参与时多余款会退回；对 ERC20 先 `approve`，并在前端用 `calculateCommitment` 做预校验。

—

HyperbolicAuction（双曲线下降）
- 合约：`contracts/Auctions/HyperbolicAuction.sol:104`
- 概述：价格按双曲线下降（`price = alpha / elapsed` 至 `minimumPrice`）；清算价取 `max(tokenPrice, priceFunction)`。
- 关键变量/视图：
  - `priceFunction()`（`contracts/Auctions/HyperbolicAuction.sol:217`）：开始前返回 `-1`（需前端特殊处理，不应允许购买）；结束后为 `minimumPrice`
  - `clearingPrice()`（`contracts/Auctions/HyperbolicAuction.sol:228`）
  - `tokenPrice()`（`contracts/Auctions/HyperbolicAuction.sol:208`）
  - `auctionSuccessful/auctionEnded/finalizeTimeExpired/finalized`（`contracts/Auctions/HyperbolicAuction.sol:376` 起）
- 参与：
  - ETH：`commitEth`（`contracts/Auctions/HyperbolicAuction.sol:271`）有退款逻辑
  - ERC20：`commitTokens/commitTokensFrom`（`contracts/Auctions/HyperbolicAuction.sol:306`、`contracts/Auctions/HyperbolicAuction.sol:313`）
  - 领取数量：`tokensClaimable(user)`（`contracts/Auctions/HyperbolicAuction.sol:409`）按承诺占比分配
- 结算/退款：
  - `finalize()`（`contracts/Auctions/HyperbolicAuction.sol:411`）成功将募资款打至 `wallet`；失败在结束后退回代币至 `wallet`。
  - `withdrawTokens([beneficiary])`（`contracts/Auctions/HyperbolicAuction.sol:427` 起）
- 前端对接要点：
  - 开始前 `priceFunction()` 为 `-1`，前端需显示“未开始”并禁用购买。
  - 双曲线价格在起始时刻非常高，注意显示上限与数值格式化。

—

通用前端交互流程
- 创建：
  1) 选择拍卖类型 → 读取 `currentTemplateId[type]`；
  2) 组织者 `approve(MISOMarket, tokenSupply)`；
  3) 组装 `_data`（使用相应 `get*InitData` 的参数签名）并调用 `MISOMarket.createMarket`，`msg.value` 覆盖最小费；
  4) 监听 `MarketCreated`（`contracts/MISOMarket.sol:118`）获取新拍卖地址。
- 参与：
  - ETH → `commitEth(beneficiary, true)` 携带 `value`；
  - ERC20 → 先 `approve(auction, amount)` 再 `commitTokens(amount, true)`（或 `commitTokensFrom`）。
- 清算：
  - 结束后由 `admin/wallet` 调用 `finalize()`；已超 7 天也可。
- 领取：
  - 成功拍卖：`finalize()` 后用户 `withdrawTokens()` 领取代币；
  - 失败拍卖：结束后用户 `withdrawTokens()` 领取退款（ETH 或支付代币）。

—

错误与边界
- 时间戳单位必须为秒（< 1e10 检查）；
- `paymentCurrency` 与提交函数类型必须对应；
- 白名单开启时，超过额度会 revert；
- 未 `finalize()` 前，成功拍卖无法领取；失败拍卖需过 `endTime` 才能退款；
- 重复领取受 `claimed`/`commitments` 限制。
