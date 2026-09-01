# XBID Contracts

XBID 的 Solidity + Foundry 合约仓库。当前只包含开发基线、数学候选 Benchmark 和测试骨架；正式资金逻辑必须等待 `OPEN-003` 与 `OPEN-011` 关闭。

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

## OPEN-002 Benchmark

```bash
forge test --gas-report
forge test --match-path test/unit/FixedPointMathCandidates.t.sol -vvv
forge build --sizes
```

Benchmark 候选代码位于 `src/libraries/benchmark/`，不是最终 LMSR 生产实现。当前选择 Solady `FixedPointMathLib`；稳定 log-sum-exp、业务输入边界和有利于 Reserve 的交易级舍入将在 `OPEN-003`、`OPEN-011` 中锁定。
