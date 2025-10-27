# MISOMarket 合约说明与前端对接要点

文件：`contracts/MISOMarket.sol`

作用概述
- 作为拍卖工厂：注册拍卖模板，收取创建费，通过 BentoBox 工厂部署拍卖实例，并调用拍卖合约的 `initMarket` 完成初始化。
- 管理费率、白名单角色与模板版本，暴露查询接口给前端与后端服务。

核心状态与结构
- 访问控制：`accessControls`（`MISOAccessControls`），通过其 `hasAdminRole/hasMinterRole/hasOperatorRole` 控制敏感操作。
- 费用与分润：`marketFees.minimumFee`、`marketFees.integratorFeePct`、`misoDiv`（平台分成地址）。
- 模板注册：
  - `auctionTemplates[templateId] -> templateAddress`
  - `auctionTemplateToId[templateAddress] -> templateId`
  - `currentTemplateId[templateType] -> templateId`（按模板类别指向当前版本）
- 拍卖记录：`auctions[]` 与 `auctionInfo[auctionAddress] -> {exists, templateId, index}`。
- 锁定开关：`locked`（上锁时仅 `admin/minter/MARKET_MINTER_ROLE` 可创建）。

初始化（部署时）
- `initMISOMarket(_accessControls, _bentoBox, _templates)`（contracts/MISOMarket.sol:129）：
  - 只能调用一次；设定访问控制与 BentoBox 工厂地址；批量添加拍卖模板；默认 `locked=true`。

创建与部署流程
- `deployMarket(templateId, integratorFeeAccount)`（contracts/MISOMarket.sol:226）
  - 校验 `locked` 与角色、`msg.value >= minimumFee()`、模板存在。
  - 计算分润：`integratorFee = msg.value * integratorFeePct / 1000`，其余给 `misoDiv`。
  - 通过 `bentoBox.deploy(templateAddress, "", false)` 部署拍卖实例；记录 `auctionInfo`，emit `MarketCreated`（contracts/MISOMarket.sol:118）。
- `createMarket(templateId, token, tokenSupply, integratorFeeAccount, data)`（contracts/MISOMarket.sol:275）
  - 封装 `deployMarket`；如 `tokenSupply > 0`，先从发起者转入并 `approve` 给新拍卖，再调用 `IMisoMarket(newMarket).initMarket(data)` 完成初始化，最后把剩余未用代币退回发起者。
  - 前端需确保发起者已对 `MISOMarket` 授权足够的 `tokenSupply`。

模板与类型（配合前端选择）
- 各拍卖合约暴露 `marketTemplate()`：
  - Crowdsale=1、DutchAuction=2、BatchAuction=3、HyperbolicAuction=4（详见各合约文件）。
- 前端可读取 `currentTemplateId[type]` → 得到当前模板 ID，再传给 `createMarket`。
- 扩展/升级：运维可 `addAuctionTemplate`、`removeAuctionTemplate`、`setCurrentTemplateId(type, templateId)` 切换默认版本。

运营与参数变更
- `setMinimumFee(amount)`（contracts/MISOMarket.sol:162）：设置创建最低费用（以 `msg.value` 支付）。
- `setIntegratorFeePct(amount)`（contracts/MISOMarket.sol:210）：设置集成方分润比例，千分制（≤1000）。
- `setDividends(address)`（contracts/MISOMarket.sol:188）：设置平台分润地址 `misoDiv`。
- `setLocked(bool)`（contracts/MISOMarket.sol:171）：上锁/解锁工厂。

查询接口（便于前端索引/展示）
- `minimumFee()`（contracts/MISOMarket.sol:342）
- `getAuctionTemplate(templateId)`、`getTemplateId(templateAddress)`（contracts/MISOMarket.sol:357, 362）
- `getMarkets()`、`numberOfAuctions()`（contracts/MISOMarket.sol:346, 338）
- `getMarketTemplateId(auctionAddr)`（contracts/MISOMarket.sol:350）
- `hasMarketMinterRole(address)`（contracts/MISOMarket.sol:215）

前端集成要点
- 选择模板：读取 `currentTemplateId[type]`；或允许高级用户直接填 `templateId`。
- 费用与分润：
  - 交易 `value` 至少等于 `minimumFee()`；
  - 设置 `integratorFeeAccount` 可返还千分比给合作方，否则全部进 `misoDiv`。
- 组装初始化参数：使用拍卖合约提供的 `get*InitData(...)` 生成 `bytes data`，传给 `createMarket`。
- 代币转移：`createMarket` 会在内部 `approve(newMarket, tokenSupply)`，但前置条件是发起者先把 `tokenSupply` 授权给 `MISOMarket`。
- 安全与权限：若 `locked=true`，非授权账户无法创建；前端需提示无权限与最低费用不足等错误信息。

常见错误与排查
- `Auction template doesn't exist`：模板 ID 不存在或已被移除 → 读取/刷新 `currentTemplateId`。
- `Failed to transfer minimumFee`：`msg.value` 小于 `minimumFee()`。
- `Sender must be minter if locked`：工厂处于上锁态且调用者无权限。
- 初始化失败：`initMarket` 的 `_data` 编码或参数不合法（时间戳须为秒；代币精度为 18；支付币种需匹配等）。

