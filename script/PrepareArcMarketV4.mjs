// READ ONLY: produce unsigned browser-wallet transactions; never sign or broadcast.
// Build: FOUNDRY_DYNAMIC_TEST_LINKING=false forge build --offline --skip-lint
// Run: node script/PrepareArcMarketV4.mjs /absolute/path/to/review.json
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
let nextRpcAt = 0;
async function request(method, params) {
  await new Promise(resolve => setTimeout(resolve, Math.max(0, nextRpcAt - Date.now())));
  nextRpcAt = Date.now() + 1000;
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

const deployed = JSON.parse(readFileSync(new URL("deployments/arc-mainnet/deployed-2026-09-28.json", root), "utf8"));
const a = { ...deployed.addresses };
assert.equal(deployed.chainId, 5042);
assert.equal(deployed.deployer.toLowerCase(), plan.deployer.toLowerCase());
for (const receipt of deployed.contractReceipts) {
  assert.equal(keccak256(await request("eth_getCode", [receipt.address, block])), receipt.runtimeHash, receipt.name + ": deployed code changed");
}
assert.equal(await read(a.MarketRegistry, artifact("MarketRegistry").abi, "versionCount"), 3n);
assert.equal(await read(a.ERC1967Proxy, artifact("XBIDFactory").abi, "defaultMarketVersion"), 3);
assert.equal((await read(a.MarketRegistry, artifact("MarketRegistry").abi, "registrar")).toLowerCase(), a.ERC1967Proxy.toLowerCase());
assert.equal(await read(a.TimelockController, artifact("TimelockController").abi, "getMinDelay"), 600n);
assert.equal(await read(a.MarketVaultV3, artifact("MarketVaultV3").abi, "CROWN_ACTIVATION_RESERVE_UNITS"), 70_000_000_000n);
const legacy = await read(a.MarketRegistry, artifact("MarketRegistry").abi, "getVersion", [3]);
assert.equal(legacy.marketImplementation.toLowerCase(), a.MarketVaultV3.toLowerCase());
assert.equal(legacy.sideTokenImplementation.toLowerCase(), a.SideToken.toLowerCase());
assert.equal(legacy.feeVault.toLowerCase(), a.FeeVault.toLowerCase());
assert.equal(legacy.riskController.toLowerCase(), a.RiskControllerV2.toLowerCase());
assert.equal(legacy.settlementToken.toLowerCase(), plan.settlementToken.toLowerCase());
const startNonce = BigInt(await request("eth_getTransactionCount", [plan.deployer, "pending"]));
assert.equal(startNonce, BigInt(await request("eth_getTransactionCount", [plan.deployer, "latest"])), "Wait for pending wallet transactions.");
a.MarketVaultV4 = getContractAddress({ from: plan.deployer, nonce: startNonce });
assert.equal(await request("eth_getCode", [a.MarketVaultV4, block]), "0x");
const contract = artifact("MarketVaultV4");
assert.ok(!contract.bytecode.object.toLowerCase().includes("7109709ecfa91a80626ff3989d68f67f5b1dd12d"), "Disable dynamic test linking before build.");
const data = encodeDeployData({ abi: contract.abi, bytecode: contract.bytecode.object, args: [] });
const tx = { from: plan.deployer, data, value: "0x0", nonce: toHex(startNonce) };
const runtime = await request("eth_call", [tx, block]);
assert.ok(runtime.length > 2);
const overrides = { [a.MarketVaultV4]: { code: runtime } };
assert.equal(await read(a.MarketVaultV4, contract.abi, "CROWN_ACTIVATION_RESERVE_UNITS", [], overrides), 15_000_000_000n);
assert.equal(await read(a.MarketVaultV4, contract.abi, "CROWN_HOLD_SECONDS", [], overrides), 60n);
assert.equal(await read(a.MarketVaultV4, contract.abi, "bWad", [], overrides), 150_000n * 10n ** 18n);
const estimatedGas = BigInt(await request("eth_estimateGas", [tx, block]));
const gasLimit = (estimatedGas * 125n + 99n) / 100n;
const gasPrice = BigInt(await request("eth_gasPrice", []));
assert.ok(gasPrice > 0n);
const balance = BigInt(await request("eth_getBalance", [plan.deployer, block]));
const priorSpentUsdc = deployed.cumulativeGasUsdc;
const transactions = [{ order: 1, name: "MarketVaultV4", chainId: 5042, from: plan.deployer, to: null, value: "0x0",
  nonce: tx.nonce, data, predictedAddress: a.MarketVaultV4, constructorArgs: [], dataHash: keccak256(data),
  simulatedRuntimeHash: keccak256(runtime), estimatedGas, gasLimit, feeCeilingAtSnapshotWei: gasLimit * gasPrice * 2n }];
const registration = { versionId: 4, ...Object.fromEntries(Object.entries(legacy).filter(([key]) => key !== "versionId")),
  marketImplementation: a.MarketVaultV4, marketImplementationCodeHash: keccak256(runtime),
  marketCloneRuntimeCodeHash: await read(a.MarketRegistry, artifact("MarketRegistry").abi, "expectedCloneRuntimeCodeHash", [a.MarketVaultV4]) };
const targets = [a.ERC1967Proxy, a.ERC1967Proxy], values = [0n, 0n];
const payloads = [
  encodeFunctionData({ abi: artifact("XBIDFactory").abi, functionName: "registerMarketVersion", args: [registration] }),
  encodeFunctionData({ abi: artifact("XBIDFactory").abi, functionName: "setDefaultMarketVersion", args: [4] }),
];
const predecessor = "0x" + "00".repeat(32);
const salt = keccak256(toHex("xbid:arc:5042:v4:15000:" + a.MarketVaultV4));
const batch = [targets, values, payloads, predecessor, salt];
const governanceTransactions = [
  { stage: "schedule", safe: plan.governance.safe, to: a.TimelockController, value: "0", operation: 0,
    data: encodeFunctionData({ abi: artifact("TimelockController").abi, functionName: "scheduleBatch", args: [...batch, 600n] }) },
  { stage: "execute_after_600_seconds", safe: plan.governance.safe, to: a.TimelockController, value: "0", operation: 0,
    data: encodeFunctionData({ abi: artifact("TimelockController").abi, functionName: "executeBatch", args: batch }) },
];
const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
const sourceCommit = git("rev-parse", "HEAD");
assert.equal(git("status", "--porcelain", "--untracked-files=normal"), "", "Commit the reviewed source first.");
assert.equal(git("rev-parse", "origin/main"), sourceCommit, "Push reviewed source before preparing wallet transactions.");
const report = { status: "UNSIGNED_DRAFT_NOT_DEPLOYED", purpose: "ARC_MARKET_V4_15000", generatedAt: new Date().toISOString(),
  chainId: 5042, domain: "xbid.live", blockNumber: Number(BigInt(block)), sourceCommit, sourceDirty: false,
  deployer: plan.deployer, startNonce, crownActivationReserveUnits: "15000000000",
  safeChecks, safeProxyRuntimeOfficialHashVerified: true, signaturesVerified: false,
  cost: { priorSpentUsdc, approvalThresholdUsdc: plan.deploymentBudget.approvalThresholdUsdc,
    nativeBalanceUsdc: formatUnits(balance, 18), contractsEstimatedUsdc: formatUnits(estimatedGas * gasPrice, 18),
    contractsFeeCeilingUsdc: formatUnits(gasLimit * gasPrice * 2n, 18),
    governanceSafeExecutionCost: "ADDITIONAL; estimate after the deployment receipt is verified" },
  addresses: a, transactions,
  governanceActivation: { targets, values, payloads, predecessor, salt, registrations: [registration], governanceTransactions },
  notes: ["Only V4 is new. All existing implementation runtime hashes were rechecked; no proxy upgrade or fee/role changes.",
    "V4 activation requires separate 2/3 governance signatures and 600-second timelock. Existing contests are immutable.",
    "The server never signs or broadcasts; all real mainnet transactions require explicit user wallet confirmation."] };
writeFileSync(output, JSON.stringify(report, (_, value) => typeof value === "bigint" ? value.toString() : value, 2) + "\n", { flag: "wx", mode: 0o600 });
console.log(JSON.stringify({ output, sourceCommit, address: a.MarketVaultV4, cost: report.cost }, null, 2));
