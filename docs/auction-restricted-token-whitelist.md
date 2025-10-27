# MISO 拍卖受限转账代币：资金流与白名单配置指引

本文说明当出售代币具备“转账受限”（需配置 transferFrom/transferTo 白名单）时，MISO 拍卖涉及的资金流路径，以及为何需要将哪些合约地址加入白名单。

## 背景与目标

- 出售代币具有两类限制：
  - transferFrom 白名单：限制“代扣者”（spender）
  - transferTo 白名单：限制“接收者”（to）
- MISO 创建/结算会在多合约间搬运出售代币；若未妥善配置白名单，创建或领取会失败。
- 目标：列清资金流路径，给出对应的白名单配置清单与理由。

## 资金流总览

A. 创建拍卖（MISOMarket 工厂）
- 前置：项目方对 `MISOMarket` 批准额度 `approve(MISOMarket, tokenSupply)`。
- 步骤：
  1) `MISOMarket.createMarket(...)`
     - MISOMarket 通过 `transferFrom(projectOwner → MISOMarket)` 拉入出售代币
     - MISOMarket `approve(newAuction, tokenSupply)`
     - 调用新拍卖合约 `initMarket(data)`
  2) `initMarket(...)`
     - 拍卖合约通过 `transferFrom(funder → auction)` 拉入出售代币
     - 强烈推荐：`funder = MISOMarket`（消费上一步的 approve）
  3) 兼容说明：若 `funder = projectOwner`，需另行对“新拍卖合约”授权，否则会失败
  4) 尾款：`MISOMarket` 将自身剩余出售代币余额退回项目方

B. 参与期（买家出资）
- ETH：买家直发 ETH 给拍卖合约（不受出售代币白名单影响）
- ERC20 支付币：买家 `approve(auction)` 后，拍卖合约 `transferFrom(buyer → auction)` 拉入支付币
- 注意：若“支付币”本身也受限，无法为“所有买家”配置白名单，流程不可行

C. 结算与领取
- 成功：`finalize()` 后，用户 `withdrawTokens()`，拍卖合约 `transfer(auctionToken → user)`
- 失败：`withdrawTokens()` 退还支付币（ETH 或支付 ERC20）

D. 可选：PostAuctionLauncher（加池/锁仓）
- Launcher 初始化：`transferFrom(caller → launcher)` 拉入出售代币作为 LP 种子
- 加池：向交易对合约 `transfer(token → pair)` 并铸造 LP

## 必须加入白名单的地址与原因

1) MISOMarket（工厂）
- transferFrom 白名单：创建时作为“代扣者”从项目方地址拉入出售代币
- transferTo 白名单：创建时作为“接收者”临时持有出售代币

2) 新拍卖合约地址（创建成功后立刻加入）
- transferFrom 白名单：在 `initMarket` 中作为“代扣者”从 `funder` 拉入出售代币
- transferTo 白名单：作为“接收者”持有并在领取时向用户转出出售代币

3) PostAuctionLauncher（若启用 Launcher，加池/锁仓）
- transferFrom 白名单：初始化时作为“代扣者”，从调用者地址拉入 LP 种子所需的出售代币
- transferTo 白名单：作为“接收者”在加池前暂存出售代币

4) UniswapV2 Pair（若会加池）
- transferTo 白名单：作为“接收者”，Launcher 向交易对合约转入两边资产铸造 LP

5) wallet 地址（拍卖收益/未售代币去向）
- transferTo 白名单：作为“接收者”，成功/失败结算时未售代币或资金会转入

6) 参与者地址（仅当你的代币“接收者也受限”时）
- transferTo 白名单：用户在 `withdrawTokens()` 时直接从拍卖合约接收出售代币
- 运维提示：难以事先收集所有参与者，通常需在领取窗口放松接收限制，或通过中间归集地址二次分发

## funder 参数的推荐设置

- 强烈建议：在 `initMarket` 的编码数据中，将 `funder` 设置为 `MISOMarket`。
  - 理由：`createMarket` 已在 MISOMarket 内准备好额度并 `approve(newAuction)`；此时由拍卖合约从 MISOMarket 拉币最顺畅
  - 若将 `funder` 设为项目方地址，则需项目方额外 `approve(newAuction)`，并为“拍卖合约”配置“代扣者白名单”；否则会失败

## 列表化清单

最小必需白名单
- transferFrom：`MISOMarket`、`<新拍卖合约>`
- transferTo：`MISOMarket`、`<新拍卖合约>`

按需追加（启用 Launcher/加池）
- transferFrom：`<PostAuctionLauncher>`
- transferTo：`<PostAuctionLauncher>`、`<UniswapV2 Pair>`、`<wallet>`

可能需要（若代币对接收者也有限制）
- transferTo：`<所有参与者地址>`，或在领取期放松该限制

## 常见坑与规避

- 不要将“受限转账代币”作为支付币种：买家侧无法普遍加入 transferFrom 白名单，`commitTokens` 将失败
- 出售代币必须 18 位小数（拍卖定价与做市组件按 18 位处理）
- 创建成功后务必监听 `MarketCreated` 事件，第一时间将“新拍卖合约地址”加入白名单
- 启用 Launcher 时，创建后立刻将新 Launcher 地址加入白名单；若要加池，也需为目标交易对地址配置接收白名单

## 参考调用顺序（建议）

- 创建前
  - 配置白名单：`MISOMarket`（from/to）
  - 项目方 `approve(MISOMarket, tokenSupply)`
  - 组装 `initMarket` 数据时设置 `funder = MISOMarket`
- 创建后
  - 监听 `MarketCreated` 获取 `<新拍卖合约>`，加入（from/to）
- 使用 Launcher（可选）
  - 创建 `<PostAuctionLauncher>` 后加入（from/to）
  - 若加池，加入 `<UniswapV2 Pair>` 的 transferTo
- 领取期
  - 如代币限制接收者，需放宽或纳入参与者地址，避免 `withdrawTokens` 回退

## XSwyrl 合约（docs/XSwyrl.sol）专项说明

XSwyrl 使用“发起地址豁免集 + 接收地址豁免集”的双白名单门控，核心逻辑在 `_update(from, to, value)`：
- 放行条件：`exempt.contains(from)` 或 `from == 0`（mint）或 `to == 0`（burn）或 `exemptTo.contains(to)`；否则 revert，错误信息为 `NOT_WHITELISTED(from)`。
- 特例：若 `VOTER.isGauge(from)` 或 `VOTER.isFeeDistributor(from)`，会自动将 `from` 加入 `exempt` 集合后放行。
- 管理接口（仅 `ACCESS_HUB` 治理可调）：
  - `setExemption(address[] exemptee, bool[] on)` → 维护 `exempt`（发起方豁免）
  - `setExemptionTo(address[] exemptee, bool[] on)` → 维护 `exemptTo`（接收方豁免）

据此，结合 MISO 资金流，推荐最小配置如下：

1) 创建前（确保项目方 → MISOMarket 的代扣通过）
- `setExemptionTo([MISOMarket], [true])`
  - 解释：第一跳为 `transferFrom(projectOwner → MISOMarket)`，需“接收方豁免”。
- 同时建议：`setExemption([MISOMarket], [true])`
  - 解释：第二跳为 `transferFrom(MISOMarket → newAuction)`，将 MISOMarket设为“发起方豁免”，不依赖新拍卖地址是否已在接收豁免集中。

2) 拍卖创建后（拿到 `MarketCreated` 的新拍卖地址）
- `setExemption([newAuction], [true])`
  - 解释：用户领取 `withdrawTokens` 时会执行 `transfer(auction → user)`，拍卖合约作为“发起方”，需在发起豁免集中，避免要求给所有用户加接收豁免。
- 可选：`setExemptionTo([newAuction], [true])`
  - 解释：若未将 MISOMarket 加入发起豁免，也可给新拍卖地址加“接收豁免”，放行 `MISOMarket → newAuction`。

3) 启用 Launcher（可选）
- `setExemptionTo([launcher], [true])`
  - 解释：初始化时 `transferFrom(caller → launcher)`，caller 可能是 EOA，不在发起豁免，需给 Launcher 作为“接收方”豁免。
- `setExemption([launcher], [true])`
  - 解释：加池时 `transfer(launcher → pair)`，Launcher 作为“发起方”需豁免。
- 可选：`setExemptionTo([pair], [true])`
  - 解释：如不想豁免 Launcher 的“发起”，也可改为豁免交易对作为“接收方”。Pair 地址通常可通过工厂 `pairFor` 预计算。

4) 其它地址
- `wallet` 无需额外配置：由于拍卖合约在“发起方豁免”中，`transfer(auction → wallet)` 将被允许。
- 一般不需要为所有参与者地址配置接收豁免，因为拍卖合约已在发起豁免集中。

5) 治理与权限
- 仅 `ACCESS_HUB` 可调用豁免配置；请准备治理账户或多签执行：
  - `setExemption([MISOMarket, newAuction, launcher], [true, true, true])`
  - `setExemptionTo([MISOMarket, launcher, pair?], [true, true, true?])`

要点回顾：在 XSwyrl 的门控模型下，优先“发起方豁免（exempt）”，可覆盖后续任意接收方；仅在首跳来源是普通 EOA 时，补“接收方豁免（exemptTo）”。这与 MISO 的首跳（projectOwner → MISOMarket）和 Launcher 首跳（caller → launcher）场景高度匹配。

