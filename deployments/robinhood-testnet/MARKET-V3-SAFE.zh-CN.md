# Market V3 测试网多签操作

当前状态：实现合约已部署；登记和默认版本切换等待 Safe 批准执行。不要把分叉模拟成功当作链上激活。

- 网络：Robinhood Chain Testnet，chainId 46630。禁止用于主网。
- Safe：`0xf72028a7f304e0585bdF7cd8BB0E0cB91fF2fBe1`，2/3 签名。
- Timelock：`0xDD935c94d8433CF959d12Dd915bb3Cd0a245876B`。
- V3 实现：`0xe0aB88f7Ed432Cc93c975E09A8BFa305d6fA4abc`。
- 部署交易：`0xa359142d63b8e969934ffcecc3b5477b5ac1c0d261bd0a9cb1522130c9d245b6`。
- 实现源码提交：`50f40328c2c68346cab999f9b334dea02d63057a`。
- 运行时代码哈希：`0x8b62c6d3624e2d7f3b99808f112ca864d92843daa75537d34aee4d64aef38556`。
- Timelock operationId：`0x62a73aa8d788459330e0ddcd369fa7cadfc48744f04f60d48857a87ab2ed932d`。
- b = 150,000；marketVersion = 3；abiVersion = 2（接口兼容，非错误）。

## 操作顺序

1. 在上述 Safe 的 Transaction Builder 导入 `market-v3-schedule.safe.json`。检查目标是 Timelock、value 为 0、方法是 scheduleBatch。两个内部调用依次为 Factory.registerMarketVersion(V3) 和 Factory.setDefaultMarketVersion(3)。完成 2/3 签名并执行 Safe 交易。
2. 从 schedule 链上成功时间起等待至少 300 秒。读取 Timelock.isOperationReady(operationId)，确认 true。收集签名本身不等于 schedule 已执行。
3. 导入 `market-v3-execute.safe.json`，完成 2/3 签名并执行。不要在 Timelock 未就绪时强行执行，或忽略模拟失败。
4. 验证 Factory.defaultMarketVersion() = 3，Registry.versionCount() = 3，Registry.getVersion(3) 的实现与代码哈希匹配，Timelock.isOperationDone(operationId) = true。
5. 验证新建 Contest 的 marketVersion = 3、bWad = 150000e18，且前后端识别正常。既有 V1/V2 市场地址、资金和版本不会自动迁移。

JSON 不固定 Safe nonce；由 Safe 使用当时的正确 nonce。两份文件是顺序操作，不要合并成一个 Safe 批次。若版本或 operation 状态发生变化，应重新检查，避免重复排队或执行。

本次只更新前后端对 V3 的兼容识别。合约源码公开浏览器验证需要另行批准上传，目前未完成。

## 本次验证结果（2026-09-06）

- 全量 Solidity 测试：148 通过，0 失败；存储布局检查通过。
- 已部署实现的链上 codehash 与 manifest 一致。
- 分叉模拟 schedule → 等待 300 秒 → execute 成功；默认版本变为 3，V1/V2 登记记录不变。
- 分叉新建 V3 市场，21,000,000 Test USDC 买入 → flip → sellAll 成功，剩余储备满足偿付约束。这仅发生在本地分叉，没有向公开测试市场注入交易量。
- Safe JSON 解码校验通过；两份文件的 operationId 一致。
- 实际链上默认版本仍为 2，Safe nonce 为 4；未提交或执行 Safe 治理交易。
- 前端兼容发布：`85ec5d2ff708ee6161897dc638940b9564b1539e`；后端：`c8c9642eab81e0bdb33c6bc0541f6651d1edf82b`。两个部署均 rollout 成功，站点 HTTP 200。
