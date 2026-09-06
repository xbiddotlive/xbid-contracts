# XBID 合约安全修复记录

日期：2026-09-05  
依据：`2026-09-05-contract-security-review.zh-CN.md`  
状态：代码修复与本地验证完成，尚未提交、尚未部署或切换测试网默认版本。

## 修复结果

### M-01：已修复

`XbidTradeMathV2._nextQuantityFromInput` 已由绝对指数逆解改为等价的 log-partition 相对域计算：

```text
targetLogZ = currentLogZ + curveInput / b
normalizedCurrentWeight
  = 1 - exp(otherQ / b - targetLogZ) - exp(ln(98) - targetLogZ)
nextQ = b × (targetLogZ + ln(normalizedCurrentWeight))
```

两个 `exp` 输入始终不大于零，因此 `b = 150,000`、`q / b <= 200` 的完整声明域不再构造超出 Solady `expWad` 或 `int256` 范围的绝对权重。原有容量判断、一个 Settlement base unit 的向下重试、费用舍入与交易后储备校验均保留。

下列原故障输入已改为成功回归：

- 空市场 21,000,000 USDC 毛额买入；
- 空市场 19,850,000 USDC 毛额买入；
- 先买入 19,000,000 USDC，再追加 1,000,000 USDC；
- 30,000,000 token 最大源仓位全量 flip；
- 一侧 30,000,000 token、另一侧为零时，对落后一侧执行 1 USDC 最小买入。

独立 TypeScript decimal.js 模型与 Solidity 边界输出进行了交叉核对；大额和最大失衡向量的误差限制为 `1e12` token wei，即 `0.000001` token。

### L-01：已修复到工作树

- V2 状态不变量测试已覆盖全量 b=150k 可执行买入区间。
- handler 会预先计算保守可执行容量；任何本应可执行却回滚的 buy 都累计为失败，并由 invariant 直接拒绝。
- 新增 10,000 组空市场完整容量 fuzz、10,000 组任意 qA/qB 状态 fuzz、大额顺序买入、最大失衡和最大仓位 flip 测试。
- 审计测试从“期待溢出”改为“要求成功并保持资金/供应量不变量”。

这些新增文件当前仍属于本地工作树；只有提交到 Git 后远端 CI 才能获得相同覆盖。

### T-01：信任边界已澄清

Factory 的合约注释现在明确区分：

- Factory 升级无法改变历史 MarketVault 字节码和 Registry 记录；
- 用户留给可升级 Factory 地址的 ERC-20 allowance 仍信任未来治理批准的实现。

现有 Launch 流程已核对为只向 Factory 授权精确的 5 Test USDC 创建费，不使用无限 Factory allowance。本轮未改变治理模型或交易业务规则。

## 新市场版本

由于已创建 MarketVault 是不可升级 Clone，线上 V2 不会被这次源码修改自动修复。新增 `MarketVaultV3`：

- 市场参数继续为 `b = 150,000`；
- 费率、Crown、储备、买卖、flip 与 ABI 不变；
- 只接受 `marketVersion = 3` 初始化；
- V1/V2 历史市场与 Registry 记录不变。

共享 TypeScript、Backend 和 Frontend 的市场参数选择器已支持 V3，V3 使用与 V2 相同的定价参数。正式上线仍需部署 V3 implementation、登记不可变 Market Version 3、经过治理切换 Factory 默认版本，并完成链上代码哈希与端到端验收。

## 验证命令

```sh
FOUNDRY_PROFILE=ci forge test --match-contract MarketV2MathTest -vv
FOUNDRY_PROFILE=ci forge test --match-contract MarketVaultV2InvariantTest -vv
FOUNDRY_PROFILE=ci forge test --summary
bash scripts/check-storage-layout.sh
forge build --sizes

cd ../shared/typescript/math && pnpm typecheck && pnpm test
cd ../../../backend-nestjs && pnpm build && node --test test/market-pricing.test.mjs
cd ../frontend-nextjs && pnpm typecheck
```

## 部署约束

本轮没有执行链上交易、升级、Registry 登记或默认版本切换。禁止把新的本地 `MarketVaultV2` 字节码误认为链上旧 V2 已发生改变；正确发布路径是新的 V3 append-only registration。测试网发布后还需验证新实现 runtime hash、Clone runtime hash、Registry bindings、Factory default version、实际大额 preview/buy/sell 流程和索引显示。

## 最终本地结果

- 完整 Foundry CI 配置：21 个套件、148 个测试项通过，0 失败、0 跳过。
- 两组新增交易数学 fuzz 各 10,000 次；6 个状态不变量组总计 600,000 次 handler 调用。
- V2 专项 invariant：1,000 runs、100,000 次调用，预期可执行 buy 的意外失败数保持为零。
- TypeScript 高精度模型：22/22 通过；Backend V3 定价测试：4/4 通过；Frontend TypeScript 检查通过。
- Factory ERC-7201 存储布局：2/2 通过；V2/V3 runtime size 均为 17,149 bytes，低于 EIP-170 限制。
