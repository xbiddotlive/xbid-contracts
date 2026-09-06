# V3 内部资金安全验证与本地发布演练

日期：2026-09-06。性质：内部复核，不是独立审计认证，也不是主网上线许可。

## 范围与结论

本轮复核既有 V3 修复及资金路径，补充 V3 直接实例化的不变量测试、生产 Factory / Registry / FeeVault / RiskController / Timelock 组合演练。**没有修改 `src/` 合约生产源码**，未广播交易，未操作真实资金或 Safe。

当前合约源码基于 `50f4032`，部署记录基于 `be90de0`。本轮未发现可由新增测试复现的未授权资金提取或偿付不足；这不等于证明不存在漏洞，也未覆盖主网真实结算资产、实际 Safe 配置和所有经济攻击。

## 第一轮：源码与现有保护复核

- 买卖/flip：检查 deadline、minimum output、sellAll expectedBalance、msg.sender 资产归属、重入保护、精确余额差额。
- 数学：V3 继承稳定相对域反算；保持 b=150k、1% 交易费、舍入及储备规则。既有全域 fuzz、极端失衡、大额追加和无外部交易循环测试保留。
- FeeVault：credit 限已登记 market；claimFeesFor 只能把钱付给受益人；先减负债再转账；领取暂停不妨碍卖出费用入账；治理变更分配只影响后续 accrual。
- 治理：Factory 仅治理可升级；历史不可升级 Clone 不会被 Factory 升级替换；留给 Factory 的历史 ERC-20 allowance 仍受未来治理实现信任边界影响。
- 风险控制：Emergency 只能提高模式；恢复须治理。Risk-Off 阻止 buy/flip，允许 sell；Full Pause 阻止 sell。claim 暂停是独立开关。

## 第二轮：新增可执行证据

`test/invariant/MarketVaultV3Invariant.t.sol` 复用同一状态机，但直接部署 MarketVaultV3 Clone 并以版本 3 初始化，不再只靠 V2 测试推断 V3。

`test/integration/MarketV3ReleaseGate.t.sol` 使用真实生产合约与本地模拟结算资产，覆盖：

1. 新 Registry 连续登记 1→2→3，V2/V3 ABI 版本 2；最后才把默认版本从 0 切到 3。
2. 48 小时 Timelock 批操作；到期前 1 秒执行失败，到期后成功；无开放 executor、无临时治理 admin、Emergency 无 proposer。
3. Factory 创建 V3，验证 Registry、实现 hash、Clone hash 和精确 5 单位创建费授权耗尽。
4. 双方向随机 buy→flip→sellAll→claim：逐步验证 reserve、供应量、总余额、FeeVault 负债与领取收款人；即便计入全部费用也不能通过无外部交易循环盈利。
5. Risk-Off、Full Pause、claim pause 和经治理恢复；不冒充 Safe 签名测试。
6. 过期、滑点、sellAll 余额变化、转账税、恶意转账回调：失败原子回滚，不丢失测试资金。

结果：完整 Foundry CI 配置 **23 套件、155 测试项通过、0 失败、0 跳过**。新增 V3 状态机 1,000 runs / 100,000 handler calls；新增全栈随机循环 10,000 次。handler 捕获某些预期回滚，因此调用数不是成功成交数，不将其当成交量。格式化和 ABI 测试配置收敛后，新增 6 项专项再次通过。

存储布局测试 2/2；V3 runtime 17,149 bytes，低于 24,576 bytes 限制。构建会产生既有 lint 提示；Foundry 签名缓存写入受沙箱限制的警告不代表测试失败。

## 字节码复核

本轮只读 RPC 返回 chainId=46630。以下三者 hash 一致：当前源码编译的 V3 runtime、仓库 V3 manifest、测试网实现 `0xe0aB88f7Ed432Cc93c975E09A8BFa305d6fA4abc` 的 `eth_getCode`。

```text
0x8b62c6d3624e2d7f3b99808f112ca864d92843daa75537d34aee4d64aef38556
```

这只验证测试网 V3 implementation，不是所有历史市场或未来主网地址的证明。主网仍需固定区块、独立 RPC、proxy slot、治理和逐市场绑定验证。

## 未关闭的主网门槛

- 主网结算资产及其冻结、升级、桥接和转账行为未锁定；6 decimals 并不足以证明兼容。
- 实际主网 Safe owners/threshold/modules/guard、Timelock、Treasury 地址及权限未验收。
- 本地模拟不是主网分叉：真实资产、真实钱包、跨服务索引及完整 UI 交易仍需验收。
- 新 Registry 连续版本策略仅作本地验证，未据此生成或签署主网治理交易。注册历史版本会保留治理未来切换默认版本的能力，须在主网版本策略中明确接受或重新设计；本轮不擅自改业务模型。
- Permissionless 合约没有本轮新增的硬 TVL 上限。前端限制和“只邀请少量用户”不能防止链上大额直接调用。
- 服务器实时告警、值班响应、恢复时间和资金预算未验收。
- 用户选择不做独立审计：记录为风险接受，不记录为独立审计通过。

## 重跑命令

```sh
FOUNDRY_PROFILE=ci forge test --summary
FOUNDRY_PROFILE=ci forge test --match-contract MarketV3ReleaseGateTest --summary
bash scripts/check-storage-layout.sh
forge build --sizes
forge inspect MarketVaultV3 deployedBytecode | cast keccak
```

以上本地命令不含广播；线上只读比较仍需单独提供并核实目标网络和地址。
