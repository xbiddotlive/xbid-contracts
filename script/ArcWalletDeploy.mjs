// Local browser-wallet deployment gate. Server can READ RPC, never sign/broadcast.
// node script/ArcWalletDeploy.mjs /absolute/unsigned-review.json /absolute/receipts.json
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { randomBytes } from "node:crypto";
import { isAbsolute } from "node:path";
const require = createRequire(new URL("../../frontend-nextjs/package.json", import.meta.url));
const { keccak256, toHex, formatUnits, parseUnits } = require("viem");
const root = new URL("../", import.meta.url);
const draft = JSON.parse(readFileSync(process.argv[2], "utf8"));
const receiptPath = process.argv[3];
assert.ok(receiptPath && isAbsolute(receiptPath) && receiptPath !== process.argv[2]);
assert.equal(draft.chainId, 5042);
assert.equal(draft.status, "UNSIGNED_DRAFT_NOT_DEPLOYED");
assert.equal(draft.sourceDirty, false, "Regenerate from a clean committed source tree.");
assert.equal(draft.safeProxyRuntimeOfficialHashVerified, true);
const isV4Upgrade = draft.purpose === "ARC_MARKET_V4_15000";
assert.equal(draft.transactions.length, isV4Upgrade ? 1 : 10);
if (isV4Upgrade) {
  assert.equal(draft.transactions[0].name, "MarketVaultV4");
  assert.equal(draft.crownActivationReserveUnits, "15000000000");
}
const port = Number(process.argv[4] ?? 3198);
assert.ok([3196, 3198].includes(port));
const base = `http://127.0.0.1:${port}`;
const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
function verifySource() {
  assert.equal(git("rev-parse", "HEAD"), draft.sourceCommit, "Source commit changed.");
  assert.equal(git("rev-parse", "origin/main"), draft.sourceCommit, "Source must match fetched/pushed origin/main.");
  assert.equal(git("status", "--porcelain", "--untracked-files=normal"), "", "Contract working tree must remain clean.");
}
verifySource();
const manifestHash = keccak256(toHex(JSON.stringify(draft)));
const journal = existsSync(receiptPath) ? JSON.parse(readFileSync(receiptPath, "utf8")) : { chainId: 5042, manifestHash, receipts: [], pendingHash: null };
assert.equal(journal.manifestHash, manifestHash, "Receipt journal belongs to another draft.");
assert.equal(journal.chainId, 5042);
const save = () => writeFileSync(receiptPath, JSON.stringify(journal, null, 2) + "\n", { mode: 0o600 });
if (!existsSync(receiptPath)) save();
const token = randomBytes(24).toString("hex");
const rpc = "https://rpc.mainnet.arc.io";
const allowed = new Set(["eth_chainId", "eth_getBalance", "eth_getTransactionCount", "eth_getCode", "eth_estimateGas", "eth_gasPrice", "eth_getTransactionByHash", "eth_getTransactionReceipt"]);
let nextRpcAt = 0;
async function read(method, params) {
  await new Promise(resolve => setTimeout(resolve, Math.max(0, nextRpcAt - Date.now())));
  nextRpcAt = Date.now() + 1000;
  assert.ok(allowed.has(method));
  const response = await fetch(rpc, { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal: AbortSignal.timeout(20000) });
  assert.ok(response.ok, `RPC HTTP ${response.status}`);
  const result = await response.json();
  if (result.error) throw new Error(`${method}: ${JSON.stringify(result.error)}`);
  return result.result;
}
const spentWei = () => journal.receipts.reduce((sum, item) => sum + BigInt(item.gasUsed) * BigInt(item.effectiveGasPrice), parseUnits(draft.cost.priorSpentUsdc ?? "0", 18));
async function quoteNext() {
  verifySource();
  assert.equal(await read("eth_chainId", []), "0x13b2");
  assert.equal(journal.pendingHash, null, "Wait for the pending transaction receipt; do not send again.");
  const index = journal.receipts.length;
  const tx = draft.transactions[index];
  assert.ok(tx, "All contracts deployed. Governance activation is a separate step.");
  for (let i = 0; i < index; i++) {
    const previous = draft.transactions[i];
    assert.equal(keccak256(await read("eth_getCode", [previous.predictedAddress, "latest"])), previous.simulatedRuntimeHash, `Runtime mismatch: ${previous.name}`);
  }
  assert.equal(await read("eth_getCode", [tx.predictedAddress, "latest"]), "0x", "Predicted address already contains code.");
  const pendingNonce = BigInt(await read("eth_getTransactionCount", [draft.deployer, "pending"]));
  assert.equal(pendingNonce, BigInt(tx.nonce), "Deployer nonce changed; do not use this draft.");
  assert.equal(BigInt(await read("eth_getTransactionCount", [draft.deployer, "latest"])), pendingNonce, "Another transaction is pending.");
  assert.equal(keccak256(tx.data), tx.dataHash);
  const call = { from: draft.deployer, data: tx.data, value: "0x0", nonce: tx.nonce };
  const gas = (BigInt(await read("eth_estimateGas", [call])) * 125n + 99n) / 100n;
  const gasPrice = BigInt(await read("eth_gasPrice", []));
  const maxFeePerGas = gasPrice * 2n;
  assert.ok(gasPrice > 0n);
  const currentCeiling = gas * maxFeePerGas;
  const remainingGas = draft.transactions.slice(index + 1).reduce((sum, next) => sum + BigInt(next.gasLimit), 0n);
  const contractTotalCeiling = spentWei() + currentCeiling + remainingGas * maxFeePerGas;
  assert.ok(contractTotalCeiling <= parseUnits(draft.cost.approvalThresholdUsdc, 18), "Contract fee ceiling now exceeds approval threshold. Obtain user approval before proceeding.");
  assert.ok(BigInt(await read("eth_getBalance", [draft.deployer, "latest"])) >= currentCeiling + remainingGas * maxFeePerGas, "Insufficient USDC for the remaining contract deployment buffer.");
  return { order: tx.order, name: tx.name, address: tx.predictedAddress, dataHash: tx.dataHash,
    maxCostUsdc: formatUnits(currentCeiling, 18), remainingContractCeilingUsdc: formatUnits(contractTotalCeiling, 18),
    transaction: { ...call, chainId: "0x13b2", gas: toHex(gas), maxFeePerGas: toHex(maxFeePerGas), maxPriorityFeePerGas: "0x0" } };
}
async function recordHash(hash) {
  assert.match(hash, /^0x[0-9a-fA-F]{64}$/);
  if (journal.pendingHash) assert.equal(hash, journal.pendingHash, "Another deployment transaction is pending.");
  const expected = draft.transactions[journal.receipts.length];
  assert.ok(expected);
  const transaction = await read("eth_getTransactionByHash", [hash]);
  if (!transaction) return { pending: true, message: "RPC has not observed this hash yet. Do not resubmit the transaction." };
  assert.equal(transaction.from.toLowerCase(), draft.deployer.toLowerCase());
  assert.equal(transaction.to, null);
  assert.equal(BigInt(transaction.value), 0n);
  assert.equal(BigInt(transaction.nonce), BigInt(expected.nonce));
  assert.equal(keccak256(transaction.input), expected.dataHash);
  journal.pendingHash = hash; save();
  const receipt = await read("eth_getTransactionReceipt", [hash]);
  if (!receipt) return { pending: true, message: "Transaction pending. Do not resubmit." };
  assert.equal(receipt.status, "0x1", "Deployment reverted. Stop and inspect; nonce is consumed.");
  assert.equal(receipt.contractAddress.toLowerCase(), expected.predictedAddress.toLowerCase());
  const actualCodeHash = keccak256(await read("eth_getCode", [receipt.contractAddress, "latest"]));
  assert.equal(actualCodeHash, expected.simulatedRuntimeHash, "Deployed runtime hash mismatch. Stop before the next transaction.");
  journal.receipts.push({ order: expected.order, name: expected.name, hash, address: receipt.contractAddress, blockNumber: Number(BigInt(receipt.blockNumber)),
    gasUsed: BigInt(receipt.gasUsed).toString(), effectiveGasPrice: BigInt(receipt.effectiveGasPrice).toString(), runtimeHash: actualCodeHash });
  journal.pendingHash = null; save();
  return { pending: false, receipt: journal.receipts.at(-1), completed: journal.receipts.length, spentUsdc: formatUnits(spentWei(), 18) };
}
const html = readFileSync(new URL("arc-wallet-review/deploy.html", import.meta.url));
const js = readFileSync(new URL("arc-wallet-review/deploy.js", import.meta.url));
let busy = false;
const server = createServer(async (req, res) => {
  const reply = (code, value, type = "application/json; charset=utf-8") => {
    res.writeHead(code, { "Content-Type": type, "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer", "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'" });
    res.end(Buffer.isBuffer(value) ? value : JSON.stringify(value));
  };
  if (req.headers.host !== `127.0.0.1:${port}`) return reply(404, {});
  if (req.method === "GET" && req.url === "/") return reply(200, html, "text/html; charset=utf-8");
  if (req.method === "GET" && req.url === "/deploy.js") return reply(200, js, "text/javascript; charset=utf-8");
  if (req.method === "GET" && req.url === "/state") return reply(200, { token, deployer: draft.deployer, sourceCommit: draft.sourceCommit,
    purpose: draft.purpose, crownActivationReserveUnits: draft.crownActivationReserveUnits,
    completed: journal.receipts.length, pendingHash: journal.pendingHash, spentUsdc: formatUnits(spentWei(), 18), transactions: draft.transactions.map(({ order, name, predictedAddress }) => ({ order, name, predictedAddress })) });
  if (req.method !== "POST" || !["/quote", "/receipt"].includes(req.url)) return reply(404, {});
  if (req.headers.origin !== base || req.headers["x-xbid-token"] !== token) return reply(403, { error: "Same-origin authorization required." });
  if (busy) return reply(409, { error: "A check is already running." });
  busy = true;
  try {
    let body = "";
    for await (const chunk of req) { body += chunk; if (body.length > 1024) throw new Error("Request too large."); }
    const result = req.url === "/quote" ? await quoteNext() : await recordHash(JSON.parse(body).hash);
    reply(200, result);
  } catch (error) { reply(400, { error: error.message }); }
  finally { busy = false; }
});
server.listen(port, "127.0.0.1", () => console.log(`Browser-wallet deployment: ${base}/ — USER must initiate and confirm each wallet transaction. Server has no signing/broadcast capability.`));
