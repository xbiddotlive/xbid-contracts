# XBID Contracts

XBID 的 Solidity + Foundry 合约仓库。当前已实现 Market Version 1 的 LMSR 数学、交易整数账本、不可升级 `MarketVault` / `SideToken` Clone、Crown 状态机、不可升级并 Version 化的生产 `FeeVault` / `RiskController`、Append-only `MarketRegistry`，以及使用 ERC-7201 Storage 的 UUPS `XBIDFactory`。

当前代码仍是开发版本，不代表已审计或可部署主网。Robinhood Testnet 两阶段部署、Manifest、链上 Validator、Source Verification 和 Storage Layout CI 已实现并通过本地 fork 演练；真实 Testnet 角色登记与部署、独立审计和 Bug Bounty 仍未完成。

## Toolchain

- Foundry `v1.8.1`
- Solidity `0.8.30`
- EVM target `cancun`
- Optimizer enabled，`10,000` runs
- PRBMath `v4.2.0`
- Solady `v0.1.26`
- OpenZeppelin Contracts / Contracts Upgradeable `v5.7.0`

依赖通过 Git submodule 和 `foundry.lock` 锁定。首次拉取：

```bash
git submodule update --init --recursive
forge test
```

## 当前核心实现

```text
src/core/MarketVault.sol
src/core/SideToken.sol
src/core/FeeVault.sol
src/core/RiskController.sol
src/core/MarketRegistry.sol
src/core/XBIDFactory.sol
src/libraries/XbidLmsrMath.sol
src/libraries/XbidTradeMath.sol
src/libraries/XbidCrownMath.sol
src/interfaces/IFeeVault.sol
src/interfaces/IMarketRegistry.sol
src/interfaces/IRiskController.sol
```

`MarketVault` 当前提供：

- `previewBuy` / `buy`；
- `previewSell` / `sell`；
- `previewSellAll` / `sellAll`；
- `previewFlip` / `flip`；
- Deadline、最终资产 Slippage、Risk-Off / Full Pause；
- Settlement Token 与 SideToken 的精确 Balance Delta；
- Reserve、Curve Cost 与 SideToken Supply 不变量；
- FeeVault 同步原子 Credit；
- 交易入口重入保护；
- 70K Reserve 激活、48% Challenge、52%/60 秒 Hold、55% Defense、严格低于 45% 重武装；
- Permissionless `finalizeCrownChallenge()`，在 Risk-Off / Full Pause 下仍可结算已满足的 Crown 转移。

`SideToken` 是 18 decimals ERC-20 + ERC-2612 Permit Clone。只有永久绑定的 MarketVault 可以 Mint，且只能 Burn 已经转入 Vault 自身的 Token。

`FeeVault` 由 Constructor 部署且不可升级，永久绑定 6-decimal Settlement Token、Append-only MarketRegistry、Governance Timelock 和 Fee Version。只有已登记 MarketVault 可以原子 Credit；Claim Pause 不影响 Credit 或 Risk-Off SELL。Fee Split、Protocol Treasury 与 Emergency Role 只能由 Governance Timelock 更新。

`RiskController` 不可升级、不持有资金且不调用外部合约。它以常量 Gas 读取 Global 与 Per-Market 模式的较高值；Emergency Role 只能严格升档，只有 Governance Timelock 可以降档或恢复，且两个角色地址强制分离。

`MarketRegistry` 不可升级，只允许当前 Registrar 顺序追加 Market Version 和 Contest。登记时同时验证 Implementation Code Hash、Solady EIP-1167 Clone Runtime Code Hash、FeeVault / RiskController Version、共同 Governance Domain，以及 MarketVault / SideToken 的双向永久绑定；旧记录不存在覆盖、删除或复用入口。

`XBIDFactory` 是唯一可升级的核心创建组件。它通过 OpenZeppelin UUPS + ERC-7201 Namespaced Storage 管理未来 Contest 创建；每次创建直接把固定 5 Settlement Token 转入当前 Team Treasury，并在同一交易中确定性部署、验证和初始化一个 MarketVault 与两个 SideToken Clone，再追加 Registry 记录。Risk-Off 和 Full Pause 均阻断新建，失败时 Fee 与全部 Clone 原子回滚。Factory 不持有 Reserve 或 Creation Fee，升级不改变 Registry 历史记录。

## 验证

```bash
forge test --gas-report
forge test --match-path test/unit/FixedPointMathCandidates.t.sol -vvv
forge build --sizes
bash scripts/check-storage-layout.sh
```

当前全量为 `126 passed / 0 failed`。测试包含固定向量、Fuzz、真实 Token 资产流、恶意依赖回滚、Timelock 角色/等待期和 Stateful Invariant。`MarketVault` 状态机持续验证 Reserve、Supply、Settlement 守恒和 Fee Credit；`FeeVault` 状态机持续验证偿付能力、负债守恒、Split 守恒和 Claim Pause 下的 Credit Liveness；`RiskController` 状态机持续验证最大风险模式、Emergency 单向权限与非托管边界；`FactoryRegistry` 状态机持续验证历史 Version / Contest 不变、禁止重复或越权登记、Creation Fee 资金守恒，以及 Factory / Registry 零资金滞留。

## Robinhood Testnet 发布工具

```text
script/DeployRobinhoodTestnet.s.sol
script/ValidateRobinhoodTestnet.s.sol
script/DeployRobinhoodTimelock.s.sol
script/ValidateRobinhoodTimelock.s.sol
deployments/robinhood-testnet/timelock.schema.json
deployments/robinhood-testnet/manifest.schema.json
scripts/deploy-robinhood-timelock.sh
scripts/finalize-robinhood-timelock-manifest.sh
scripts/validate-robinhood-timelock.sh
scripts/verify-robinhood-timelock.sh
scripts/deploy-robinhood-testnet.sh
scripts/validate-robinhood-testnet.sh
scripts/verify-robinhood-testnet.sh
```

Robinhood Testnet 已在 `0xDD935c94d8433CF959d12Dd915bb3Cd0a245876B` 部署无临时管理员的 5 分钟 Governance Timelock；Governance Safe 是唯一 Proposer、Canceller 和 Executor，Emergency Safe 不拥有 Timelock 角色。Timelock 源码已在 Robinhood Testnet Blockscout 公开验证。协议部署后进入 `defaultMarketVersion = 0` 的不可创建状态，再由 Testnet Timelock 在同一 Batch 中切换 Registry Registrar 和默认 Version。主网延迟仍锁定为 48 小时。复制 `.env.example` 后按 `xbid-docs/deployment/ROBINHOOD_TESTNET_DEPLOYMENT_RUNBOOK.md` 执行；不得跳过 Safe 校验、模拟、未激活验证或 Timelock 等待期。

Benchmark 候选代码位于 `src/libraries/benchmark/`，不是生产入口。生产数学使用 Solady `FixedPointMathLib` 和已经锁定的稳定 log-sum-exp、业务输入边界及有利于 Reserve 的整数舍入。
