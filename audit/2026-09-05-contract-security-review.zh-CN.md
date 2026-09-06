# XBID 合约安全评估与审计报告

日期：2026-09-05  
评估方式：源码审查、已有测试回归、定向攻击路径复现、模糊/状态不变量测试、测试网只读核验  
状态：审计完成；已确认问题尚未修复；本报告不构成主网上线安全认证。

> 2026-09-05 修复更新：M-01 已在本地代码中按新 Market V3 方案修复，L-01 的边界与状态不变量覆盖已补齐；测试网已登记的 V2 Clone 不会被本地改动自动更新。修复证据见 [`2026-09-05-contract-security-remediation.zh-CN.md`](./2026-09-05-contract-security-remediation.zh-CN.md)。本节之后保留最初审计快照，便于追踪问题原貌。

## 1. 执行摘要

本轮没有确认到普通外部攻击者能够绕过当前合约权限、盗取其他用户持仓或直接抽走 MarketVault 储备金的路径。这个结论仅覆盖本轮审查及测试范围，不能解释成“绝对安全”。

确认了 **1 项中风险数学缺陷、1 项低风险测试交付问题**，另列出治理、部署与依赖方面的安全注意事项。

| 编号 | 分类 | 结论 | 状态 |
| --- | --- | --- | --- |
| M-01 | 中风险 / 数学边界 | V2 的 `b = 150k` 与买入逆函数的指数、整数范围不匹配，部分声明容量内的合法买入会回滚 | 已本地复现，未修复 |
| L-01 | 低风险 / 测试交付 | 现有 V2 状态不变量测试文件未被 Git 跟踪，干净检出不能获得本机相同覆盖；V2 大额逆函数边界亦缺少回归 | 已确认 |
| T-01 | 治理信任边界，不计作无权限漏洞 | 恶意或被攻破的治理可以通过 Factory 升级动用历史 ERC-20 授权 | 已用本地恶意实现复现 |
| N-01 | 上线前配置要求 | 当前治理延迟是测试网用的 300 秒，不能直接当作主网配置；部署清单状态存在滞后 | 已只读核验 |
| N-02 | 编译器/依赖注意事项 | Solidity 0.8.30 落在已公开缺陷的版本区间，但本轮未发现匹配当前编译设置与代码的触发条件 | 需保留上线复核 |

建议：修复 M-01、交付 L-01 的测试后，再进行修复复审与主网配置验收。不能仅凭已有测试全绿就直接放行主网。

本轮没有修改生产合约、没有发起链上交易、没有升级部署或推送 GitHub。仅新增本报告及本地审计测试；没有执行线上攻击或 DoS/压力测试。

## 2. 审查对象与证据版本

仓库：`contracts-solidity-foundry`  
审查基线：`92576fab3efe8f4e8fee75e4121ee856a1d5dc42`  
编译器：Solidity `0.8.30`；优化开启，10,000 runs；EVM `cancun`；`viaIR = false`。

主要源码范围：

- `src/core/MarketVault.sol`、`MarketVaultV2.sol`：买入、卖出、sellAll、flip、储备、Crown 状态机。
- `src/core/XBIDFactory.sol`、`MarketRegistry.sol`：UUPS、原子创建、Clone 初始化、版本与市场绑定。
- `src/core/FeeVault.sol`、`RiskController.sol`、`SideToken.sol`：手续费、领取、风控、铸造/销毁、Permit。
- `src/libraries/XbidLmsrMath*.sol`、`XbidTradeMath*.sol`、`XbidCrownMath*.sol`：V1/V2 公式、精度、整数结算、阈值。
- 上述接口、部署预检、Timelock 配置、存储布局及相关测试。
- 使用到的 Solady 数学/转账/Clone/Token、OpenZeppelin 初始化与 UUPS 路径。

依赖锁定快照：

| 依赖 | 本地版本/提交 |
| --- | --- |
| OpenZeppelin Contracts | package.json `5.7.0`；`cab19933c33c2ad1d4c7a84864a3601dddfd16f3` |
| OpenZeppelin Upgradeable | `5.7.0`；`14f52c54d3a1eefbda3d4071efba24d3c1e07e8a` |
| Solady | `acd959aa4bd04720d640bf4e6a5c71037510cc4b` |

开始审计时已有未跟踪文件 `test/invariant/MarketVaultV2Invariant.t.sol`，本轮保留原文件，没有改写；以下本机测试统计包含它。

不在本轮范围：前端、后端、索引器、服务器、钱包插件、私钥保管实况、主网结算币实现全审计、链共识安全、全量 MEV/经济博弈建模。对这些项目不作安全保证。

## 3. 测试网源码对应关系

2026-09-05 只读 RPC 采样时观察到区块高度 `113483109`；以下调用为随后近邻区块上的 latest 读数，并非同一固定区块的完整快照。

| 项目 | 核验结果 |
| --- | --- |
| chainId | `46630` |
| Factory | `0x8f9208FD358c62FB4052e4C2FBbCA3152A17E4b6` |
| Factory 默认市场版本 | `2` |
| Registry | `0x0B68fD82965Fd853907CA4E2f7E6E6d478Aaef8b` |
| Registry V2 implementation | `0x085B14926DC8cB15AD2614Ae68323A041A06e5b7` |
| V2 runtime keccak256 | `0x4a644e3f70a03c7afe89132ea356964393b1c667c3f21e45009524ae281af604` |
| 本地 V2 编译 runtime hash | 与上述链上 runtime hash 完全一致 |
| Factory governance | `0xDD935c94d8433CF959d12Dd915bb3Cd0a245876B` |
| Timelock minimum delay | `300` 秒 |
| Governance Safe | `0xf72028a7f304e0585bdF7cd8BB0E0cB91fF2fBe1`，阈值 `2`、owner 数 `3` |

Registry V2 返回的 SideToken、FeeVault、RiskController、Settlement Token 与部署清单绑定一致。确认线上使用的是本轮发现数学边界问题的 V2 实现，而非仅本地尚未上线的代码。

限定：本轮没有逐一重验所有历史市场余额、全部依赖运行时代码及 Safe modules/guard/全部 Timelock 角色。2-of-3 owner 数量不能证明三把私钥由独立主体保管，也不能代替模块和角色验收。

## 4. 已确认问题

### M-01：V2 买入逆函数在声明容量内超出数值域

严重度：中风险。影响买入及复用同一逆函数的 flip 买入腿。未发现此缺陷能够直接盗取资金；已复现的失败交易完整回滚，已有持仓能够卖出。

定位：

- [`XbidLmsrMathV2.sol:13`](../src/libraries/XbidLmsrMathV2.sol#L13)：`b = 150_000e18`。
- 同文件第 21 行：仍允许每边 `q <= 30_000_000e18`。
- [`XbidTradeMathV2.sol:165`](../src/libraries/XbidTradeMathV2.sol#L165)：`_solveBuyQuantity` 用最大曲线成本判断容量。
- 同文件第 191–220 行：`_nextQuantityFromInput` 直接计算正指数，并将 `nextWeightWad` 转为 `int256`。
- `lib/solady/src/utils/FixedPointMathLib.sol:207`：`expWad` 的有界输入实现。

#### 原因

曲线本身的成本和价格采用稳定的 log-sum-exp，但买入逆函数没有完整采用这种数值稳定处理。它依次计算：

```text
x = currentQuantity / b
t = curveInput / b
growth = exp(t) - 1
Z = exp(logPartition)
nextWeight = exp(x) + Z × growth
nextQuantity = b × ln(int256(nextWeight))
```

Solady `expWad` 的正输入上界约为 `135.306`。V1 的 `30m / 270k ≈ 111.11`，但 V2 的 `30m / 150k = 200`。降低 b 后，原先对指数及中间整数安全的推导失效。

问题不仅是 `exp(t)`：即使 t 没超过上界，`nextWeight` 也可能大于 `int256.max`，转为负数后调用 `lnWad` 回滚。因此，源码里“Capacity validation proves nextWeightWad fits in int256”的注释对 V2 不成立。

#### 本地复现

以下 USDC 数量都仅用于本地 MockSettlementToken，没有在测试网或主网发送这些交易。

1. 空市场买入 **21,000,000 USDC**：扣费后的曲线输入为 20,790,000 USDC，低于该市场声明的约 29,309,224.47 USDC 单边成本容量；同额 V1 报价成功，V2 报价及实际 buy 都以 `ExpOverflow` 回滚。
2. 空市场买入 **19,850,000 USDC**：曲线输入仍在容量内，输入指数也没有到 exp 上界；但中间权重转成有符号整数后，`lnWad` 以 `LnWadUndefined` 回滚。
3. 从空市场实际买入 **19,000,000 USDC** 能成功，再追加 **1,000,000 USDC** 在容量仍足够时失败。失败不改变储备或持仓；随后卖出全部持仓成功。

在单边高度占优时，相关中间数值限制约对应 20.30m token 数量；从空市场单笔买入的毛额临界规模约为 19.80m USDC。这里只提供数量级，不应把这个近似数作为新的安全常量。

复现测试位于 [`test/audit/ContractSecurityReview20260905.t.sol`](../test/audit/ContractSecurityReview20260905.t.sol)：

- `testKnownIssueV2BuyOverflowsInsideDeclaredCapacityButV1Succeeds`
- `testKnownIssueV2NextWeightCastFailsBelowCapacityAndBeforeExpInputLimit`
- `testKnownIssueLargeReachableMarketRejectsAdditionButOwnerCanExit`

这些用例显示 PASS 表示“成功复现了预期缺陷”，并不表示缺陷已经修复。

#### 影响与建议

- 当前问题是经济容量与实际可执行范围不一致，并非可确认的储备盗取路径，也不是测试到的永久无法退出。
- 高状态下的 flip 存在同源风险，因为其目的侧复用 `_solveBuyQuantity`；本轮直接故障复现聚焦 buy，未宣称穷尽所有 flip 临界状态。
- 优先在保持 `b = 150k` 和既定业务参数的前提下，将逆函数改为数值稳定的对数域/归一化算法，并证明所有中间量的范围。
- 不要只提高指数上限、使用 unchecked、忽略 revert、放宽储备校验或删除费用舍入保护。
- 同时补充两边接近最大 q、极度失衡、高初始成本、小追加额、大单、flip 两个方向以及整数临界值 ±1 的 V2 测试，并用独立高精度模型作差异验证。

部署约束：MarketVault V2 是固定实现 Clone，不能通过升级 Factory 直接修改已有市场代码。修复后的实现应作为新 Market Version 登记并切换未来创建默认值；旧市场继续保留原实现。旧市场是否限购或进入 RiskOff，应另行评估和授权，不能以冻结所有卖出来代替修复。

### L-01：V2 测试覆盖尚未完整进入可交付仓库

严重度：低风险，属于测试/发布完整性问题，不是独立资金盗取漏洞。

审计开始时 `git status --short` 显示：

```text
?? test/invariant/MarketVaultV2Invariant.t.sol
```

这意味着本机运行的 V2 储备、资金守恒、供应量与 Crown 状态测试，不会自动出现在当前提交的干净 CI checkout 中。原有 `MarketV2Math.t.sol` 主要覆盖 b、价格变化和 Crown 阈值，不能替代大额交易逆函数的边界测试。

此外，现有状态测试的 handler 会捕获部分交易 revert。日志里的“handler reverts = 0”不能等价为“所有内部交易成功”；也不能证明完整参数域都可交易。这解释了现有测试全绿仍能遗漏 M-01。

建议：将经过评审的 V2 invariant 和本轮回归测试纳入正式提交；在 CI 中分别统计 buy/sell/flip 实际成功次数、访问过的 q 区间及被捕获的错误类型。修复 M-01 后，将已知缺陷测试改为成功结果和资金不变量断言。

## 5. 治理与运行信任边界

### T-01：Factory 升级能影响历史授权，不只是未来创建

`XBIDFactory.sol:16` 的注释称升级只影响未来创建。对不可升级的历史市场代码和 Registry 历史记录而言，这个隔离方向是正确的；但对用户历史上给 Factory 的 ERC-20 allowance 而言，这个表述过于宽泛。

本地测试验证了以下区别：

1. 普通攻击者调用 `upgradeToAndCall` 被 `Unauthorized` 拒绝。
2. 若授权治理主体主动执行恶意升级，新的实现可以通过原 Factory 地址对曾授权用户执行 `transferFrom`。
3. 本地模拟受害者留下无限授权后，恶意实现可以转走其模拟钱包余额。

这不是发现了一个绕过多签/Timelock 的办法。前提是治理被攻破或治理本身作恶。暴露的是钱包里仍被授权的资产，而不是已经锁在现有 MarketVault 内、未授权 Factory 的 Reserve。

证据：`testTrustBoundaryGovernanceUpgradeCanSpendHistoricalFactoryAllowance`。测试里的恶意实现只存在于 `test/audit`，没有部署到链上。

建议：

- Factory 的创建费采用按需、精确金额授权，避免默认无限授权；支持撤销残余授权。
- 对治理升级维持独立多签、延迟、可见的待执行升级和取消流程。
- 文档应分别描述“历史市场不可升级”和“Factory 历史授权仍信任未来实现”。
- Factory 当前没有直接取出旧市场 Reserve 的管理接口；但这不能被推广为管理员在整个系统中完全没有资金相关权限。

### FeeVault / RiskController 的边界

- FeeVault 的 creator/referrer 领取只能支付对应账户；代领不能把收款人改成调用者。协议部分由当前 protocolTreasury 领取。
- Governance 可以改变未来手续费拆分、轮换 protocolTreasury，以及控制恢复；已经记账的用户 claimable 不会因 fee split 变化重新定价。
- `creditFee` 信任 Registry 已登记的市场调用者。当前 V1/V2 先精确转入费用再记账，且总负债不能超过实际余额。本轮没有发现普通地址伪造 credit 或从已记账负债中套利的路径。
- 未来新增 Market Version 仍必须审核其 FeeVault 调用行为；“已登记”不是对未来任意恶意实现的自动安全证明。
- RiskOff 保留 SELL，FullPause 会阻止 SELL；紧急权限是预期的运行信任边界，不能宣传成任何情况下都无需信任的退出保证。

## 6. 资金、公式与攻击路径核对

### 核心账本关系

```text
实际 USDC 余额 >= reserveUnits
reserveUnits >= ceil(C(qA, qB) / 10^12)
tokenA.totalSupply == qAWei
tokenB.totalSupply == qBWei

FeeVault 实际余额 >= totalLiabilityUnits
protocol fee + creator fee + referrer fee == 收到的 fee
```

V2 曲线使用：

```text
C(qA,qB) = b × [ln(exp(qA/b) + exp(qB/b) + 98) - ln(100)]
```

实现使用自身固定点原点保证 C(0,0)=0。Settlement 是 6 位小数；token 数量及曲线成本为 18 位小数，中间换算为 `10^12`。

核对结果：

- BUY：1% 手续费向上取整；费用与曲线 Reserve 分离；买入后再次验证储备。超出已付成本的逆解会下调一个 Settlement base unit 重算，而不是允许负储备缓冲。
- SELL：释放成本向下取整，费用向上取整，先转入并销毁调用者自己的 SideToken，再精确付款。
- FLIP：先计算源侧释放成本，仅收一次费用，再用于目的侧买入；Reserve 只减少这笔费用，不产生额外可提取 USDC。
- `sellAll`：校验当前持仓与 expectedBalance，净输出必须大于零。
- 捐赠 USDC 不进入交易者的赎回报价，未发现首存/捐赠型份额膨胀攻击。
- 用户之间的 SideToken 转账不改变总供应量和 q，不会把他人已授权的持仓变成当前调用者可出售资产。
- 交易入口有 nonReentrant、deadline、最小输出保护；最小输出设为零仍意味着调用者接受极宽价格变化，不能视为合约提供了额外的 MEV 保护。
- Permit 使用 Clone 自身域与 nonce；补充测试确认同一签名不能重放或用于另一 SideToken Clone。
- Clone 创建与初始化在 Factory 同笔交易中完成；实现初始化已锁定。普通地址不能通过重新 initialize 获得现有市场权限。
- Registry 校验市场、两边 token、版本与代码绑定，历史记录追加后不能被普通外部调用覆盖。
- Crown 48/52/55/45 阈值、60 秒持续条件及重置状态有现有测试覆盖；Crown 不是结算派奖，不赋予直接提走 Reserve 的权限。

### 新增经济路径测试

本轮新增两组各 10,000 次 fuzz：

1. 空市场中的买入→全量 flip→卖出，不存在没有外部交易者时凭循环获得净 USDC 的已复现路径。
2. 市场已有其他持仓者的储备后再执行上述循环，即使把该循环产生的全部费用视为返还给执行者，其余额也未增加，原有 Reserve 未被抽取，最终 q 恢复原值。

上述随机交易毛额范围约 1,000–1,000,000 USDC，不是对全域的数学证明。高状态缺陷另外通过 M-01 的定向测试覆盖。没有宣称套利、MEV 或任何未来组合路径已被穷尽。

## 7. 主网上线前的配置与依赖要求

### N-01：测试网配置不能直接复用主网

当前 RPC 读到 Timelock 延迟 300 秒，部署代码明确将其定义为测试网参数；项目安全基线要求主网 48 小时。300 秒本身不是测试网漏洞，但复制为主网治理延迟会降低发现和取消恶意升级的窗口。

同时，`deployments/robinhood-testnet/market-v2.json` 的状态仍为 `PENDING_GOVERNANCE_ACTIVATION`，而本次链上 defaultMarketVersion 已为 2。发布验收应以链上真实状态为依据，并同步清单，避免审核人员误判使用版本。

主网必须重新验证：chainId、结算币地址/实现/小数位/升级权限/冻结行为、Registry 绑定、所有实现代码哈希、多签 owner 独立性、阈值、modules、guard、Timelock 角色及延迟、部署者角色撤销。测试网 permissionless mint 的 USDC 无法作为主网经济安全或真实资产支持的证据。

### N-02：编译器公开缺陷复核

根据本轮查询的 [Solidity 官方已知缺陷清单](https://docs.soliditylang.org/en/latest/bugs.html)，0.8.30 处于以下公开缺陷影响版本区间。必须继续检查触发条件，不能仅凭版本号判定当前合约可被攻击：

| 官方编号 | 本轮匹配检查 |
| --- | --- |
| SOL-2026-1 | 要求 viaIR 与特定 transient 清理组合；当前 viaIR=false，未见对应源码构造 |
| SOL-2026-2 | 要求 viaIR 和特定相互递归；当前 viaIR=false |
| SOL-2026-3 | 要求接近存储末端的自定义布局警告；当前未使用该布局构造或出现此警告 |
| SOL-2025-1 | 涉及跨越存储末端的数组；未发现源码主动布置这种静态存储结构 |

因此本轮未将这些条目列为已确认资金漏洞。主网发布前应评估升级到修复相关缺陷的编译器，并重跑代码哈希、字节码大小、存储布局和全部回归；不能直接更换编译器后沿用旧审计结果。

依赖核查参考了 [OpenZeppelin 官方安全公告](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories) 和本地锁定源码。这不是对所有传递依赖、所有历史公告或未公开漏洞的完整排除证明。

## 8. 验证与复现记录

执行目录：`/Users/kering/Documents/ChatGPT/xbidlive/contracts-solidity-foundry`

```sh
# 原有测试及本机已有 V2 invariant
forge test --summary

# 本轮 9 个定向测试；其中两个 fuzz 各 10,000 次
FOUNDRY_PROFILE=ci forge test --match-path 'test/audit/*.t.sol' -vv

# 完整 CI 配置回归
FOUNDRY_PROFILE=ci forge test --summary

# Factory ERC-7201 与布局隔离
bash scripts/check-storage-layout.sh

# 编译/代码大小；核对 V2 本地 runtime hash
forge build --sizes
forge inspect MarketVaultV2 deployedBytecode | cast keccak
```

已完成结果：

- 原有基线：130 个 Foundry 测试项通过，0 失败；包含 6 个聚合状态不变量测试组，每组默认 256 runs × 500 depth，即每组 128,000 次 handler 调用。
- 新增定向测试：9/9 通过，其中两个 fuzz 各 10,000 次。测试名称包含 `KnownIssue` 的三项为缺陷复现，非修复通过证明。
- 完整 CI 配置回归：21 个测试套件、139 个 Foundry 测试项通过，0 失败、0 跳过；各 fuzz 使用 10,000 runs，6 个状态不变量组各 1,000 runs × 100 depth，总计 600,000 次 handler 调用。完成时间为 2026-09-05 13:29:42 UTC。
- Factory 存储布局检查：2/2 通过。
- 生产运行时代码大小：MarketVault/V2 各 17,136 bytes；Factory 12,715；Registry 9,891；FeeVault 7,080；SideToken 4,017；RiskController 2,450。均未超过 EIP-170 的 24,576 bytes 限制。
- 本地 V2 编译字节码与当前测试网实现 runtime hash 一致。

所有统计包含本机已有但尚未跟踪的 V2 invariant；不能当作当前远端 CI 已运行了相同文件的证明。基线与完整 CI 输出分别保存在本机 `/tmp/xbid-contract-audit-20260905-baseline.log`、`/tmp/xbid-contract-audit-20260905-ci.log`，临时目录日志不保证长期保留；上述命令及仓库测试可用于复现。

工具限制：本机没有安装 Slither/Semgrep，本轮没有声称运行它们或完成形式化验证。Foundry 输出过签名缓存写入权限警告，以及旧式 invariant target 接口探测警告；实际各 handler 调用表和断言均有执行，不能将缓存警告误报成合约漏洞。handler 内部捕获失败的覆盖限制已在 L-01 说明。

## 9. 修复优先级与验收标准

1. **先修 M-01**：保持既定 b、费率和储备规则，修正逆函数数值域。所有已知故障输入都应在真实容量内成功，或在明确超容量时返回正确业务错误，而不是数学内部错误。
2. **交付测试覆盖**：正式纳入 V2 invariant；增加边界差异向量、实际成功计数及高 q 路径；已知缺陷用例转成修复回归。
3. **治理授权风险控制**：核对创建费精确授权、残余授权、升级可见性和主网 Timelock/Safe 配置，修正文档中的绝对表述。
4. **新版本发布复审**：注册新市场实现前对确定的最终提交及部署参数重新复审，不通过 UUPS 假设既有 V2 市场已获修复。
5. **主网独立验收**：结算币、全部代码哈希、角色、全局/市场风控和正常退出路径在主网候选部署上验证；进行独立审计/复核后再决定真实资金开放范围。

最终判断：当前可继续进行受控测试网验证；本轮未提供主网放行结论。确认问题修复和部署验收仍有工作待完成。
