# 拍卖合约部署指南（AuctionCreation / BatchAuction / Crowdsale / DutchAuction / HyperbolicAuction / ProRataFixedPrice）

本指南帮助你在受支持的网络上部署以下拍卖相关合约：`AuctionCreation`、`BatchAuction`、`Crowdsale`、`DutchAuction`、`HyperbolicAuction`。仓库采用 `hardhat-deploy`，会自动解析并部署依赖。

## 合约依赖关系
- `AuctionCreation` 依赖：`MISOTokenFactory`、`ListFactory`、`MISOLauncher`、`MISOMarket`。
- `MISOMarket` 依赖：`BatchAuction`、`Crowdsale`、`DutchAuction`、`HyperbolicAuction`、`ProRataFixedPrice`、`MISOAccessControls`。
- `MISOLauncher`、`MISOMarket` 初始化使用常量：`BENTOBOX_ADDRESS`、`WNATIVE_ADDRESS`、`FACTORY_ADDRESS`（来自 `@sushiswap/core-sdk`）。
  - 可通过环境变量覆盖 WETH/WNATIVE：设置 `WETH_ADDRESS=0x...` 将用于 `PostAuctionLauncher` 的构造参数与校验脚本。
- 说明：即使仅指定部署 `AuctionCreation`，也会因依赖关系自动部署上述组件（包括 `HyperbolicAuction`）。

## 完全功能部署清单（创建 / 参与 / 结算 / 领取 / 加池 / 白名单 / 查询）
- 核心拍卖（必须）：
  - `MISOAccessControls`
  - `MISOMarket`（拍卖工厂）
  - 拍卖模板：`Crowdsale`、`DutchAuction`、`BatchAuction`、`HyperbolicAuction`、`ProRataFixedPrice`
- 白名单与额度（可选，若前端需启用 pointList）：
  - `PointList`（模板合约）
  - `ListFactory`（通过 `PointList` 模板克隆名单）
- 加池与锁仓（可选，拍卖结束后一键加池/锁仓）：
  - `PostAuctionLauncher`（Launcher 模板）
  - `MISOLauncher`（Launcher 工厂，并添加上面的模板）
- 一键编排（可选，前端一次调用完成建拍/名单/加池）：
  - `MISOTokenFactory`（代币工厂：`FixedToken`、`MintableToken`、`SushiToken` 模板）
  - `AuctionCreation`（编排合约）
- 查询辅助（推荐，前端读数与列表页）：
  - `MISOHelper`

对应部署脚本 tags（可组合使用）：
- 核心拍卖：`MISOAccessControls,BatchAuction,Crowdsale,DutchAuction,HyperbolicAuction,ProRataFixedPrice,MISOMarket`
- 白名单：`PointList,ListFactory`
- 加池：`PostAuctionLauncher,MISOLauncher`
- 代币与编排：`MISOTokenFactory,AuctionCreation`
- 查询：`MISOHelper`

注意：
- 在“非 SDK 支持网络”（本地链等）上，脚本会自动兜底：
  - 没有 `BENTOBOX_ADDRESS` → 自动部署/复用 `BentoFactoryLite`（仅克隆+审批能力）
- 没有 `WNATIVE_ADDRESS` → 自动部署/复用 `WETH9`（或显式提供 `WETH_ADDRESS` 环境变量）
  - 没有 `FACTORY_ADDRESS` → 自动部署/复用 `UniswapV2Factory`

## 环境准备
- Node.js 16+ 与 Yarn/NPM。
- 安装依赖：`yarn` 或 `npm install`。
- 复制 `.env.example` 为 `.env` 并设置：
  - `MNEMONIC`（用于 `namedAccounts`：`deployer`=第 0 个地址，`admin`=第 1 个地址等）；
  - 至少一个 RPC Key：`INFURA_API_KEY` 或 `ALCHEMY_API_KEY`；
  - 可选：`ETHERSCAN_API_KEY`（Etherscan 验证）、`TENDERLY_PROJECT`、`TENDERLY_USERNAME`（Tenderly 验证）。
- 选择网络：须为 `@sushiswap/core-sdk` 已配置 `BENTOBOX_ADDRESS`、`WNATIVE_ADDRESS`、`FACTORY_ADDRESS` 的网络（如 Ethereum、Polygon、Arbitrum 等）。
  - 若 SDK 未配置 WETH，可设置 `WETH_ADDRESS` 或允许脚本自动部署本地 `WETH9`。

## 编译
```sh
hardhat compile
# 或
yarn build
```

## 一键部署（推荐）
使用 `AuctionCreation` 的 tag，会自动部署依赖（含 `BatchAuction`、`Crowdsale`、`DutchAuction`、`HyperbolicAuction`、`ProRataFixedPrice` 等）。
```sh
npx yarn hardhat --network monadTestnet deploy --tags AuctionCreation
# 或
yarn hardhat --network monadTestnet deploy --tags AuctionCreation
# 或（若有 hh 别名）
hh --network monadTestnet deploy --tags AuctionCreation
```

若需“完全接入”前端功能（白名单/加池/查询），可一次执行包含多 tag 的部署（依赖会自动排序）：
```sh
yarn hardhat --network monadTestnet deploy \
  --tags MISOAccessControls,PointList,ListFactory,PostAuctionLauncher,MISOLauncher,\
BatchAuction,Crowdsale,DutchAuction,HyperbolicAuction,ProRataFixedPrice,MISOMarket,MISOTokenFactory,AuctionCreation,MISOHelper
```

完成后执行授权（授予 AuctionCreation 铸币权限）：
```sh
yarn hardhat --network monadTestnet add-minter --address $(jq -r .address deployments/monadTestnet/AuctionCreation.json)
```

## 分步部署（按需）
1) 部署拍卖模板：
```sh
yarn hardhat --network monadTestnet deploy --tags BatchAuction
yarn hardhat --network monadTestnet deploy --tags Crowdsale
yarn hardhat --network monadTestnet deploy --tags DutchAuction
yarn hardhat --network monadTestnet deploy --tags HyperbolicAuction
yarn hardhat --network monadTestnet deploy --tags ProRataFixedPrice
```
2) 部署/初始化 `MISOMarket`：
```sh
yarn hardhat --network monadTestnet deploy --tags MISOMarket
```
3) （可选）白名单组件：
```sh
yarn hardhat --network monadTestnet deploy --tags PointList
yarn hardhat --network monadTestnet deploy --tags ListFactory
```
4) （可选）加池/锁仓组件：
```sh
yarn hardhat --network monadTestnet deploy --tags PostAuctionLauncher
yarn hardhat --network monadTestnet deploy --tags MISOLauncher
```
5) （可选）代币与一键编排：
```sh
yarn hardhat --network monadTestnet deploy --tags MISOTokenFactory
yarn hardhat --network monadTestnet deploy --tags AuctionCreation
```
6) （推荐）查询辅助：
```sh
yarn hardhat --network monadTestnet deploy --tags MISOHelper
```

说明：若 `add-minter` 因 `admin` 账户余额不足失败，可改用 `deployer` 账户自动重试（脚本已内置）。

## 初始化与自动化
- 部署脚本会自动完成以下初始化：
  - `MISOAccessControls`：`initAccessControls(deployer)` 并将 `admin` 加为管理员
  - `MISOMarket`：首次部署后调用 `initMISOMarket(accessControls, BentoBoxAddress, [四类拍卖模板])`
  - `MISOLauncher`：首次部署后调用 `initMISOLauncher(accessControls, BentoBoxAddress)` 并 `addLiquidityLauncherTemplate(PostAuctionLauncher)`
  - `ListFactory`：`initListFactory(accessControls, PointListTemplate, minimumFee)`
  - `MISOTokenFactory`：`initMISOTokenFactory(accessControls)` 并添加 `FixedToken/MintableToken/SushiToken` 模板
  - `AuctionCreation`：部署后执行任务 `add-minter` 将其设为 `MINTER_ROLE`
  - `MISOHelper`：构造参数注入 `AccessControls/TokenFactory/Market/Launcher` 地址

- 四类拍卖模板（`Crowdsale/Dutch/Batch/Hyperbolic`）与 `PostAuctionLauncher/PointList` 均作为“模板”部署，无需初始化；实例由工厂克隆后在新地址调用 `init*` 完成初始化。

手动部署（不走脚本）时需手工调用的初始化汇总：
- `MISOMarket.initMISOMarket(accessControls, bentoBox, [templates])`
- `MISOLauncher.initMISOLauncher(accessControls, bentoBox)` → `addLiquidityLauncherTemplate(postAuctionTemplate)`
- `ListFactory.initListFactory(accessControls, pointListTemplate, minimumFee)`
- `MISOTokenFactory.initMISOTokenFactory(accessControls)` → `addTokenTemplate(...)`
- `MISOAccessControls.addAdminRole(admin)`、`MISOAccessControls.addMinterRole(AuctionCreation)`（如需）

## 不支持网络的兜底（本地链等）
- BentoBox：若无 `BENTOBOX_ADDRESS`，脚本会自动部署/复用 `contracts/Utils/BentoFactoryLite.sol` 并用于 `MISOMarket/MISOLauncher`，仅用于“克隆+审批”。
- WETH：若无 `WNATIVE_ADDRESS`，脚本会自动部署/复用 `contracts/Utils/WETH9.sol`，或使用环境变量 `WETH_ADDRESS`，供 `PostAuctionLauncher` 使用。
- AMM 工厂：若无 `FACTORY_ADDRESS`，脚本会自动部署/复用 `contracts/UniswapV2/UniswapV2Factory.sol`，并将地址传入 `AuctionCreation`。

## 验证与排错
- 验证：
  - 部署结果地址：`deployments/monadTestnet/*.json`
  - 关键状态：
    - `MISOMarket.auctionTemplateId()>0`、`getAuctionTemplate(id)` 返回非零
    - `MISOLauncher.launcherTemplateId()>0`
    - `ListFactory.numberOfChildren()` 可用
    - `MISOTokenFactory` 模板已添加
- 常见问题：
  - 余额不足：`add-minter` 交易失败 → 给 `admin/deployer` 账户充值或直接使用 `deployer` 账户
  - 地址缺失：SDK 映射无 `BENTOBOX/WNATIVE/FACTORY` → 使用兜底（已自动）或切换到支持网络/主网 fork

```sh
yarn hardhat --network monadTestnet deploy --tags AuctionCreation
```

## 部署结果
- 产物写入 `deployments/monadTestnet`（包含地址与构造参数）。
- 控制台会输出地址日志，如：`BatchAuction deployed at ...`。

## 验证
- Etherscan（hardhat-deploy）：
```sh
yarn hardhat --network monadTestnet etherscan-verify --license GPL-3.0 --force-license
```
- 内置任务（调用 Tenderly，需登录 tenderly-cli）：
```sh
yarn hardhat --network monadTestnet verify-all
```
- 单合约验证（可选）：
```sh
yarn hardhat --network monadTestnet verify:verify --address <deployed_address> --constructor-args <args...>
```

## 账户与权限
- `namedAccounts`（见 `hardhat.config.ts`）：
  - `deployer`：`MNEMONIC` 第 0 个地址；
  - `admin`：第 1 个地址（`tasks/add-minter.ts` 使用 `admin` 给 `AuctionCreation` 授权 minter）。
- 首次部署 `MISOAccessControls`：会用 `deployer` 初始化为 admin，随后将 `admin` 地址加入 admin 角色。
- 确保 `deployer` 与 `admin` 在目标链上余额充足。

## 常见问题
- No BentoBox/WETH address for chain X：换用 `@sushiswap/core-sdk` 已支持网络。
- `add-minter` 失败：确认 `admin` 账户存在且有余额，`MISOAccessControls` 已初始化。
- 验证失败：检查 `ETHERSCAN_API_KEY`、部署地址/构造参数是否匹配，并适当等待区块确认。

## AuctionCreation 说明（部署与作用）
- 合约：`contracts/Recipes/AuctionCreation.sol`
- 部署参数（脚本自动注入）：`MISOTokenFactory`、`ListFactory`、`MISOLauncher`、`MISOMarket`、`UniswapV2Factory` 地址
- 部署后自动执行动作：调用任务 `add-minter`，为 `AuctionCreation` 赋予 `MISOAccessControls.MINTER_ROLE`，使其在 `MISOMarket/MISOLauncher/MISOTokenFactory` 处于 locked 状态时仍可创建实例。
- 一键编排方法：`prepareMiso(tokenFactoryData, accounts, amounts, marketData, launcherData)`，顺序完成：
  - 创建或接收代币（若选择“已部署代币”，会将初始供应从调用者转入本合约）
  - （可选）创建 `PointList` 名单并批量设置额度
  - 创建拍卖：通过 `MISOMarket.createMarket` 克隆模板并 `initMarket`
  - 授权：将新拍卖 `admin` 权限赋予调用者
  - （可选）创建 Launcher，并将拍卖的 `wallet` 更新为新 Launcher，实现结算后一键加池/锁仓
  - 返还：未用完的代币余额转回给调用者

通过依赖链自动部署：
- 访问控制与工厂
      - MISOAccessControls
      - MISOMarket（已 initMISOMarket 并挂上模板）
      - MISOLauncher（已 initMISOLauncher 并添加 PostAuctionLauncher 模板）
      - MISOTokenFactory（已 initMISOTokenFactory 并添加 FixedToken/MintableToken/SushiToken 模板）
      - ListFactory（已 initListFactory，注入 PointList 模板与最低费）
  - 模板合约
      - 拍卖模板：BatchAuction、Crowdsale、DutchAuction、HyperbolicAuction
      - 白名单模板：PointList
      - Launcher 模板：PostAuctionLauncher
      - 代币模板：FixedToken、MintableToken、SushiToken
  - 一键编排
      - AuctionCreation（部署后已执行 add-minter 授权）
  - 兜底（仅在 SDK 缺地址的网络上才会自动部署）
      - BentoFactoryLite（替代 BentoBox 的克隆/审批能力）
      - WETH9（替代 WNATIVE_ADDRESS）
      - UniswapV2Factory（替代 FACTORY_ADDRESS）

运行 `--tags AuctionCreation` 后还需要补充什么？
- 标准拍卖流程（创建/参与/结算/领取）：无需额外初始化，工厂、模板与权限已在部署脚本中完成。
- 白名单/额度：确保 `PointList` 与 `ListFactory` 已部署（见“完全接入”组合命令），调用 `prepareMiso` 时传入名单参数。
- 一键加池/锁仓：确保 `PostAuctionLauncher` 与 `MISOLauncher` 已部署并已添加模板（脚本已自动添加），调用 `prepareMiso` 时提供 `launcherData`（百分比/锁定时长等）。
- 前端查询：部署 `MISOHelper` 后即可通过 Helper 拉取市场列表与用户状态。

提示：在非 SDK 支持网络上，建议确认日志显示已部署/复用 `BentoFactoryLite`、`WETH9`、`UniswapV2Factory` 三个兜底组件，以确保一键流程可用。
