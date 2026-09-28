// READ ONLY: produce unsigned browser-wallet transactions; never sign or broadcast.
// Build: FOUNDRY_DYNAMIC_TEST_LINKING=false forge build --offline --skip-lint
// Run: node script/PrepareArcDeployment.mjs /absolute/path/to/review.json
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { isAbsolute } from "node:path";
const require = createRequire(new URL("../../frontend-nextjs/package.json", import.meta.url));
const { encodeDeployData, encodeFunctionData, encodeAbiParameters, decodeFunctionResult, getContractAddress, keccak256, toHex, parseAbi, formatUnits, zeroAddress } = require("viem");
const root = new URL("../", import.meta.url);
const plan = JSON.parse(readFileSync(new URL("deployments/arc-mainnet/plan.json", root), "utf8"));
const output = process.argv[2];
assert.ok(output && isAbsolute(output), "Provide an absolute output path for the unsigned review file.");
const rpc = process.env.ARC_PREFLIGHT_RPC_URL ?? plan.rpcUrl;
assert.equal(new URL(rpc).protocol, "https:");
const allowed = new Set(["eth_chainId", "eth_blockNumber", "eth_getTransactionCount", "eth_getBalance", "eth_getCode", "eth_getStorageAt", "eth_gasPrice", "eth_call", "eth_estimateGas"]);
async function request(method, params) {
  assert.ok(allowed.has(method), "Signing and broadcast methods are forbidden.");
  const response = await fetch(rpc, { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal: AbortSignal.timeout(30000) });
  assert.ok(response.ok, `HTTP ${response.status}`);
  const body = await response.json();
  if (body.error) throw new Error(`${method}: ${JSON.stringify(body.error)}`);
  return body.result;
}
const artifact = (name) => JSON.parse(readFileSync(new URL(`out/${name}.sol/${name}.json`, root), "utf8"));
assert.equal(Number(BigInt(await request("eth_chainId", []))), 5042);
assert.equal(plan.chainId, 5042);
assert.equal(plan.governance.plannedDelaySeconds, 600);
assert.equal(plan.emergency.tradingRecoveryPolicy.recoveryDelaySeconds, 300);
assert.deepEqual([plan.feeSplit.protocolBps, plan.feeSplit.creatorBps, plan.feeSplit.referrerBps], [5000, 4000, 1000]);
assert.equal(plan.settlementToken.toLowerCase(), "0x3600000000000000000000000000000000000000");
const block = await request("eth_blockNumber", []);
const read = async (address, abi, functionName, args = [], overrides = {}) => decodeFunctionResult({ abi, functionName,
  data: await request("eth_call", [{ to: address, data: encodeFunctionData({ abi, functionName, args }) }, block, overrides]) });
assert.equal(await read(plan.settlementToken, parseAbi(["function decimals() view returns (uint8)"]), "decimals"), 6);
const safeAbi = parseAbi(["function getOwners() view returns (address[])", "function getThreshold() view returns (uint256)",
  "function VERSION() view returns (string)", "function masterCopy() view returns (address)",
  "function getModulesPaginated(address,uint256) view returns (address[],address)"]);
const safeChecks = [];
const singleton = "0xedd160febbd92e350d4d398fb636302fccd67c7e";
const fallback = "0x3efcbb83a4a7afcb4f68d501e2c2203a38be77f4";
const proxyFactory = "0x14f2982d601c9458f93bd70b218933a6f8165e7b";
// Safe official v1.5.0 safe_l2.json and compatibility_fallback_handler.json.
for (const [address, expectedHash] of [[singleton, "0x180193227186ccb85316c94db1f0d156ed932b14712cfaac78901899178572dc"],
  [fallback, "0x3c6a85bcf7b563daa624b884b4e9a1b9fa5371edde7be945d998071a48f28bbc"],
  [proxyFactory, "0x967dae4cda22b0c9ef7f31b010bdc1ceb0af9904b0c3dc060b5302e4c18a4529"]]) {
  assert.equal(keccak256(await request("eth_getCode", [address, block])), expectedHash);
}
const proxyCreationCode = await read(proxyFactory, parseAbi(["function proxyCreationCode() pure returns (bytes)"]), "proxyCreationCode");
const proxyRuntime = await request("eth_call", [{ from: plan.deployer,
  data: proxyCreationCode + encodeAbiParameters([{ type: "address" }], [singleton]).slice(2) }, block]);
assert.ok(proxyRuntime.length > 2);
for (const config of [plan.governance, plan.emergency]) {
  assert.equal(await request("eth_getCode", [config.safe, block]), proxyRuntime, "Safe proxy differs from official factory creation code.");
  const owners = await read(config.safe, safeAbi, "getOwners");
  assert.deepEqual(owners.map((a) => a.toLowerCase()).sort(), config.owners.map((a) => a.toLowerCase()).sort());
  assert.equal(await read(config.safe, safeAbi, "getThreshold"), 2n);
  assert.equal(await read(config.safe, safeAbi, "VERSION"), "1.5.0");
  assert.equal((await read(config.safe, safeAbi, "masterCopy")).toLowerCase(), singleton);
  const [modules, cursor] = await read(config.safe, safeAbi, "getModulesPaginated", ["0x0000000000000000000000000000000000000001", 20n]);
  assert.equal(modules.length, 0);
  assert.equal(cursor, "0x0000000000000000000000000000000000000001");
  for (const key of ["guard_manager.guard.address", "module_manager.module_guard.address"]) {
    assert.equal(BigInt(await request("eth_getStorageAt", [config.safe, keccak256(toHex(key)), block])), 0n);
  }
  const handler = await request("eth_getStorageAt", [config.safe, keccak256(toHex("fallback_manager.handler.address")), block]);
  assert.equal(`0x${handler.slice(-40)}`.toLowerCase(), fallback);
  safeChecks.push({ safe: config.safe, owners, threshold: 2, version: "1.5.0", modules: [], guard: zeroAddress, moduleGuard: zeroAddress, fallback, singleton, proxyRuntimeHash: keccak256(proxyRuntime) });
}
const startNonce = BigInt(await request("eth_getTransactionCount", [plan.deployer, "pending"]));
assert.equal(startNonce, BigInt(await request("eth_getTransactionCount", [plan.deployer, "latest"])), "Pending deployer transaction; wait before preparing addresses.");
const balanceWei = BigInt(await request("eth_getBalance", [plan.deployer, block]));
const gasPrice = BigInt(await request("eth_gasPrice", []));
assert.ok(gasPrice > 0n);
const names = ["TimelockController", "MarketRegistry", "RiskControllerV2", "FeeVault", "XBIDFactory", "ERC1967Proxy", "SideToken", "MarketVault", "MarketVaultV2", "MarketVaultV3"];
const addresses = Object.fromEntries(names.map((name, i) => [name, getContractAddress({ from: plan.deployer, nonce: startNonce + BigInt(i) })]));
const a = addresses;
const initialize = encodeFunctionData({ abi: artifact("XBIDFactory").abi, functionName: "initialize", args: [a.TimelockController, plan.settlementToken, a.MarketRegistry, plan.teamTreasury] });
const args = [
  [600n, [plan.governance.safe], [plan.governance.safe], zeroAddress],
  [a.TimelockController, a.TimelockController], [a.TimelockController, plan.emergency.safe],
  [1, plan.settlementToken, a.MarketRegistry, a.TimelockController, plan.emergency.safe, plan.protocolTreasury, 5000, 4000, 1000],
  [], [a.XBIDFactory, initialize], [], [], [], [],
];
const overrides = {};
const transactions = [];
for (let i = 0; i < names.length; i++) {
  const name = names[i];
  const contract = artifact(name);
  assert.ok(!contract.bytecode.object.toLowerCase().includes("7109709ecfa91a80626ff3989d68f67f5b1dd12d"), "Rebuild without Foundry dynamic test linking.");
  assert.equal(await request("eth_getCode", [a[name], block]), "0x", `Predicted address occupied: ${name}`);
  const data = encodeDeployData({ abi: contract.abi, bytecode: contract.bytecode.object, args: args[i] });
  const nonce = startNonce + BigInt(i);
  // Only the current eth_call sees prior constructor runtime and funded caller.
  // This is not a sequential state rehearsal: storage from earlier creates is not retained.
  overrides[plan.deployer] = { nonce: toHex(nonce), balance: toHex(1000n * 10n ** 18n) };
  const tx = { from: plan.deployer, data, value: "0x0", nonce: toHex(nonce) };
  const runtime = await request("eth_call", [{ ...tx, gas: "0x1c9c380" }, block, overrides]);
  assert.ok(runtime.length > 2, `${name}: empty runtime`);
  const estimatedGas = BigInt(await request("eth_estimateGas", [tx, block, overrides]));
  const gasLimit = (estimatedGas * 125n + 99n) / 100n;
  overrides[a[name]] = { code: runtime };
  transactions.push({ order: i + 1, name, chainId: 5042, from: plan.deployer, to: null, value: "0x0", nonce: toHex(nonce), data,
    predictedAddress: a[name], constructorArgs: args[i], dataHash: keccak256(data), simulatedRuntimeHash: keccak256(runtime),
    estimatedGas, gasLimit, feeCeilingAtSnapshotWei: gasLimit * gasPrice * 2n });
  console.log(`${i + 1}/10 ${name} ${a[name]} estimatedGas=${estimatedGas}`);
}
const totalGas = transactions.reduce((sum, tx) => sum + tx.estimatedGas, 0n);
const feeCeilingWei = transactions.reduce((sum, tx) => sum + tx.feeCeilingAtSnapshotWei, 0n);
const registrations = [];
for (const [index, name] of ["MarketVault", "MarketVaultV2", "MarketVaultV3"].entries()) {
  const cloneHash = async (implementation) => read(a.MarketRegistry, artifact("MarketRegistry").abi, "expectedCloneRuntimeCodeHash", [implementation], overrides);
  registrations.push({ versionId: index + 1, marketImplementation: a[name], marketImplementationCodeHash: keccak256(overrides[a[name]].code),
    marketCloneRuntimeCodeHash: await cloneHash(a[name]), sideTokenImplementation: a.SideToken,
    sideTokenImplementationCodeHash: keccak256(overrides[a.SideToken].code), sideTokenCloneRuntimeCodeHash: await cloneHash(a.SideToken),
    settlementToken: plan.settlementToken, feeVault: a.FeeVault, feeVaultVersion: 1,
    riskController: a.RiskControllerV2, riskControllerVersion: 2, abiVersion: index === 0 ? 1 : 2 });
}
const targets = [a.MarketRegistry, a.ERC1967Proxy, a.ERC1967Proxy, a.ERC1967Proxy, a.ERC1967Proxy];
const values = targets.map(() => 0n);
const payloads = [encodeFunctionData({ abi: artifact("MarketRegistry").abi, functionName: "setRegistrar", args: [a.ERC1967Proxy] }),
  ...registrations.map((registration) => encodeFunctionData({ abi: artifact("XBIDFactory").abi, functionName: "registerMarketVersion", args: [registration] })),
  encodeFunctionData({ abi: artifact("XBIDFactory").abi, functionName: "setDefaultMarketVersion", args: [3] })];
const predecessor = `0x${"00".repeat(32)}`;
const salt = keccak256(toHex(`xbid:arc:5042:v3:${a.TimelockController}:${startNonce}`));
const timelockAbi = artifact("TimelockController").abi;
const governanceTransactions = [
  { stage: "schedule", safe: plan.governance.safe, to: a.TimelockController, value: "0", operation: 0,
    data: encodeFunctionData({ abi: timelockAbi, functionName: "scheduleBatch", args: [targets, values, payloads, predecessor, salt, 600n] }) },
  { stage: "execute_after_600_seconds", safe: plan.governance.safe, to: a.TimelockController, value: "0", operation: 0,
    data: encodeFunctionData({ abi: timelockAbi, functionName: "executeBatch", args: [targets, values, payloads, predecessor, salt] }) },
];
const sourceCommit = execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim();
const sourceDirty = Boolean(execFileSync("git", ["status", "--porcelain", "--untracked-files=normal"], { cwd: root, encoding: "utf8" }).trim());
const report = { status: "UNSIGNED_DRAFT_NOT_DEPLOYED", generatedAt: new Date().toISOString(), chainId: 5042, domain: "xbid.live",
  blockNumber: Number(BigInt(block)), sourceCommit, sourceDirty, deployer: plan.deployer, startNonce,
  safeChecks, signaturesVerified: false, safeProxyRuntimeOfficialHashVerified: true,
  notes: ["Safe singleton, fallback and proxy factory runtime hashes match official Safe v1.5.0 deployment assets. Both proxy runtimes match eth_call creation using the verified factory creation code. Owner signing ability still requires wallet signatures.",
    "Constructor eth_call / gas estimates use temporary runtime and balance overrides, not a complete sequential simulation.",
    "Addresses, nonce, runtime hashes and fees must be regenerated/reverified from a clean pushed commit before wallet signing.",
    "Governance calldata is draft until all ten receipts and deployed runtime hashes are verified.",
    "Do not reuse old nonce predictions after another deployer transaction or a partially completed run.",
    "No Safe deployment needed. Existing Safes must sign schedule and execute using 2/3 owners."],
  cost: { nativeBalanceUsdc: formatUnits(balanceWei, 18), totalEstimatedGas: totalGas, snapshotGasPriceWei: gasPrice,
    contractsEstimatedUsdc: formatUnits(totalGas * gasPrice, 18), contractsFeeCeilingUsdc: formatUnits(feeCeilingWei, 18),
    feeCeilingPolicy: "25% gas-limit headroom times 2x current gas price; snapshot only, not a wallet fee quote.",
    governanceSafeExecutionCost: "NOT_YET_ESTIMATED; two Safe execution transactions plus optional onchain owner approvals are additional.",
    approvalThresholdUsdc: plan.deploymentBudget.approvalThresholdUsdc,
    contractCeilingExceedsApprovalThreshold: feeCeilingWei > BigInt(Math.round(Number(plan.deploymentBudget.approvalThresholdUsdc) * 1e6)) * 10n ** 12n },
  addresses, transactions, governanceActivation: { targets, values, payloads, predecessor, salt, registrations, governanceTransactions } };
writeFileSync(output, `${JSON.stringify(report, (_, value) => typeof value === "bigint" ? value.toString() : value, 2)}\n`, { flag: "wx", mode: 0o600 });
console.log(JSON.stringify({ output, status: report.status, sourceDirty, cost: report.cost }, (_, value) => typeof value === "bigint" ? value.toString() : value, 2));
