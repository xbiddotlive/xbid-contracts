# XBID Contracts

XBID 的 Solidity + Foundry 合约仓库。`OPEN-003` 与 `OPEN-011` 已关闭，当前已实现 Market Version 1 的 LMSR 数学、交易整数账本、不可升级 `MarketVault` / `SideToken` Clone、Crown 状态机，以及不可升级、Version 化的生产 `FeeVault`。

当前代码仍是开发版本，不代表已审计或可部署主网。生产 `RiskController`、Factory、Append-only Registry、部署脚本和审计仍未完成。

## Toolchain

- Foundry `v1.8.1`
- Solidity `0.8.30`
- EVM target `cancun`
- Optimizer enabled，`10,000` runs
- PRBMath `v4.2.0`
- Solady `v0.1.26`

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

## 验证

```bash
forge test --gas-report
forge test --match-path test/unit/FixedPointMathCandidates.t.sol -vvv
forge build --sizes
```

测试包含固定向量、Fuzz、真实 Token 资产流、恶意依赖回滚和 Stateful Invariant。`MarketVault` 状态机持续验证 Reserve、Supply、Settlement 守恒和 Fee Credit；`FeeVault` 状态机持续验证偿付能力、负债守恒、Split 守恒和 Claim Pause 下的 Credit Liveness。

Benchmark 候选代码位于 `src/libraries/benchmark/`，不是生产入口。生产数学使用 Solady `FixedPointMathLib` 和已经锁定的稳定 log-sum-exp、业务输入边界及有利于 Reserve 的整数舍入。
