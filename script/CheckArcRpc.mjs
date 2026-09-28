// Read-only. Run from the xbid workspace with frontend dependencies installed:
// node contracts-solidity-foundry/script/CheckArcRpc.mjs
// Build with FOUNDRY_DYNAMIC_TEST_LINKING=false forge build --skip-lint first.
// No signer, private key, or broadcast methods.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(new URL("../../frontend-nextjs/package.json", import.meta.url));
const { encodeFunctionData, decodeFunctionResult, decodeErrorResult, toHex } = require("viem");
const plan = JSON.parse(readFileSync(new URL("../deployments/arc-mainnet/plan.json", import.meta.url), "utf8"));
const rpc = process.env.ARC_PREFLIGHT_RPC_URL ?? plan.rpcUrl;
assert.equal(new URL(rpc).protocol, "https:");
async function request(method, params) {
  assert.ok(["eth_chainId", "eth_blockNumber", "eth_call"].includes(method));
  const response = await fetch(rpc, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal: AbortSignal.timeout(30000),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}
assert.equal((await request("eth_chainId", [])).result, toHex(plan.chainId));
const block = (await request("eth_blockNumber", [])).result;
assert.match(block, /^0x[0-9a-f]+$/);
console.log(JSON.stringify({ chainId: plan.chainId, blockNumber: Number(BigInt(block)), mode: "eth_call_only_no_broadcast" }));
for (const [name, address, funding] of [
  ["ArcUsdcCompatibilityProbe", "0x00000000000000000000000000000000a7c05042", 100n],
  ["ArcMarketCompatibilityProbe", "0x00000000000000000000000000000000a7c05043", 1000n],
]) {
  const artifact = JSON.parse(readFileSync(new URL(`../out/${name}.sol/${name}.json`, import.meta.url), "utf8"));
  assert.ok(!artifact.deployedBytecode.object.toLowerCase().includes("7109709ecfa91a80626ff3989d68f67f5b1dd12d"), "Rebuild probes with FOUNDRY_DYNAMIC_TEST_LINKING=false; Foundry cheatcodes cannot run on Arc RPC.");
  const result = await request("eth_call", [
    { from: plan.deployer, to: address, data: encodeFunctionData({ abi: artifact.abi, functionName: "probe" }), gas: "0x1c9c380" },
    block,
    { [address]: { code: artifact.deployedBytecode.object, balance: toHex(funding * 10n ** 18n) } },
  ]);
  if (result.error) {
    let decoded;
    try { decoded = decodeErrorResult({ abi: artifact.abi, data: result.error.data }); } catch { /* RPC may omit revert bytes. */ }
    console.error(JSON.stringify({ probe: name, error: result.error, decoded }, (_, v) => typeof v === "bigint" ? String(v) : v));
    process.exitCode = 1;
  } else {
    console.log(JSON.stringify({ probe: name, returnedUnits: decodeFunctionResult({ abi: artifact.abi, functionName: "probe", data: result.result }) }, (_, v) => typeof v === "bigint" ? String(v) : v));
  }
}
