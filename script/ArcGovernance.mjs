// Local, fixed-purpose Safe signing coordinator. RPC is READ ONLY.
// Only the browser's explicit user action can request signing or broadcasting.
// node script/ArcGovernance.mjs /absolute/review.json /absolute/deployment-receipts.json /absolute/governance-journal.json
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, renameSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { randomBytes } from 'node:crypto';
import { isAbsolute } from 'node:path';
const require = createRequire(new URL('../../frontend-nextjs/package.json', import.meta.url));
const v = require('viem');
const { parseAbi, encodeFunctionData, decodeFunctionResult, keccak256, toHex, zeroAddress,
  hashTypedData, recoverTypedDataAddress, formatUnits, parseUnits } = v;
const [manifestPath, receiptsPath, journalPath] = process.argv.slice(2);
assert.ok([manifestPath, receiptsPath, journalPath].every(p => p && isAbsolute(p)));
assert.equal(new Set([manifestPath, receiptsPath, journalPath]).size, 3);
const draft = JSON.parse(readFileSync(manifestPath));
const isV4Upgrade = draft.purpose === 'ARC_MARKET_V4_15000';
const targetVersion = isV4Upgrade ? 4 : 3;
const port = Number(process.argv[5] ?? (isV4Upgrade ? 3195 : 3197));
assert.ok([3195, 3197].includes(port));
if (isV4Upgrade) assert.equal(draft.crownActivationReserveUnits, '15000000000');
const deployments = JSON.parse(readFileSync(receiptsPath));
const a = draft.addresses;
const safe = '0x7A5B3A1741fe4731C3a85134d308c528451B70e0';
const owners = ['0xA0b8f23f879457872109B5B20C9545B5281b28F6', '0xbcD4C253231Ce239A9b073987B54C48a561009A2', '0xa860aCdE31615461C0936511E1DcF81801CE7751'];
const manifestHash = keccak256(toHex(JSON.stringify(draft)));
assert.equal(draft.chainId, 5042); assert.equal(draft.sourceDirty, false);
assert.equal(deployments.manifestHash, manifestHash);
assert.equal(deployments.chainId, 5042); assert.equal(deployments.receipts.length, isV4Upgrade ? 1 : 10); assert.equal(deployments.pendingHash, null);
assert.equal(draft.deployer.toLowerCase(), owners[0].toLowerCase());
const abi = n => JSON.parse(readFileSync(new URL(`../out/${n}.sol/${n}.json`, import.meta.url))).abi;
const safeAbi = parseAbi([
  'function getOwners() view returns (address[])', 'function getThreshold() view returns (uint256)',
  'function VERSION() view returns (string)', 'function masterCopy() view returns (address)', 'function nonce() view returns (uint256)',
  'function getModulesPaginated(address,uint256) view returns (address[],address)',
  'function getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256) view returns (bytes32)',
  'function checkNSignatures(address,bytes32,bytes,uint256) view',
  'function execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes) payable returns (bool)',
]);
const activation = draft.governanceActivation;
const encode = (name, functionName, args) => encodeFunctionData({ abi: abi(name), functionName, args });
// Rebuild the fixed scope; do not trust opaque manifest payloads as arbitrary calls.
assert.equal(activation.registrations.length, isV4Upgrade ? 1 : 3);
for (const [i, r] of activation.registrations.entries()) {
  assert.equal(r.versionId, isV4Upgrade ? 4 : i + 1);
  assert.equal(r.marketImplementation, a[isV4Upgrade ? 'MarketVaultV4' : ['MarketVault', 'MarketVaultV2', 'MarketVaultV3'][i]]);
  assert.equal(r.sideTokenImplementation, a.SideToken);
  assert.equal(r.settlementToken.toLowerCase(), '0x3600000000000000000000000000000000000000');
  assert.equal(r.feeVault, a.FeeVault); assert.equal(r.riskController, a.RiskControllerV2);
  assert.equal(r.feeVaultVersion, 1); assert.equal(r.riskControllerVersion, 2); assert.equal(r.abiVersion, !isV4Upgrade && i === 0 ? 1 : 2);
}
const targets = isV4Upgrade ? [a.ERC1967Proxy, a.ERC1967Proxy] : [a.MarketRegistry, a.ERC1967Proxy, a.ERC1967Proxy, a.ERC1967Proxy, a.ERC1967Proxy];
const payloads = [...(isV4Upgrade ? [] : [encode('MarketRegistry', 'setRegistrar', [a.ERC1967Proxy])]),
  ...activation.registrations.map(r => encode('XBIDFactory', 'registerMarketVersion', [r])),
  encode('XBIDFactory', 'setDefaultMarketVersion', [targetVersion])];
assert.deepEqual(activation.targets, targets); assert.deepEqual(activation.payloads, payloads);
assert.deepEqual(activation.values.map(BigInt), targets.map(() => 0n));
assert.equal(activation.predecessor, '0x' + '00'.repeat(32));
const batchArgs = [targets, targets.map(() => 0n), payloads, activation.predecessor, activation.salt];
const calldata = {
  schedule: encode('TimelockController', 'scheduleBatch', [...batchArgs, 600n]),
  execute: encode('TimelockController', 'executeBatch', batchArgs),
};
for (const [i, stage] of ['schedule', 'execute'].entries()) {
  const tx = activation.governanceTransactions[i];
  assert.equal(tx.safe.toLowerCase(), safe.toLowerCase()); assert.equal(tx.to, a.TimelockController);
  assert.equal(BigInt(tx.value), 0n); assert.equal(tx.operation, 0); assert.equal(tx.data, calldata[stage]);
}
const json = x => JSON.stringify(x, (_, value) => typeof value === 'bigint' ? value.toString() : value);
const journal = existsSync(journalPath) ? JSON.parse(readFileSync(journalPath)) : { manifestHash, stages: {}, receipts: [], pending: null, halted: null };
assert.equal(journal.manifestHash, manifestHash);
function save() { writeFileSync(journalPath + '.tmp', json(journal) + '\n', { mode: 0o600 }); renameSync(journalPath + '.tmp', journalPath); }
const allowed = new Set(['eth_chainId', 'eth_blockNumber', 'eth_getBlockByNumber', 'eth_getCode', 'eth_getStorageAt', 'eth_call',
  'eth_estimateGas', 'eth_gasPrice', 'eth_getBalance', 'eth_getTransactionCount', 'eth_getTransactionByHash', 'eth_getTransactionReceipt']);
let rpcQueue = Promise.resolve(), nextRpcAt = 0;
function rpc(method, params) {
  const result = rpcQueue.then(async () => {
    await new Promise(resolve => setTimeout(resolve, Math.max(0, nextRpcAt - Date.now())));
    nextRpcAt = Date.now() + 1000;
    return request(method, params);
  });
  rpcQueue = result.catch(() => {});
  return result;
}
async function request(method, params) {
  assert.ok(allowed.has(method), 'Server cannot sign or broadcast.');
  const r = await fetch('https://rpc.mainnet.arc.io', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: json({ jsonrpc: '2.0', id: 1, method, params }), signal: AbortSignal.timeout(25000) });
  assert.ok(r.ok, `RPC HTTP ${r.status}`); const body = await r.json();
  if (body.error) throw new Error(`${method}: ${json(body.error)}`); return body.result;
}
async function read(address, contractAbi, functionName, args = [], block = 'latest') {
  return decodeFunctionResult({ abi: contractAbi, functionName, data: await rpc('eth_call', [{ to: address,
    data: encodeFunctionData({ abi: contractAbi, functionName, args }) }, block]) });
}
const timelock = (fn, args = [], block = 'latest') => read(a.TimelockController, abi('TimelockController'), fn, args, block);
const registry = (fn, args = [], block = 'latest') => read(a.MarketRegistry, abi('MarketRegistry'), fn, args, block);
const factory = (fn, args = [], block = 'latest') => read(a.ERC1967Proxy, abi('XBIDFactory'), fn, args, block);
const safeRead = (fn, args = [], block = 'latest') => read(safe, safeAbi, fn, args, block);
let operationId, deploymentSpent = 0n;
async function verifyDeployments() {
  assert.equal(BigInt(await rpc('eth_chainId', [])), 5042n);
  deploymentSpent = parseUnits(draft.cost.priorSpentUsdc ?? '0', 18);
  await Promise.all(draft.transactions.map(async (tx, i) => {
    const entry = deployments.receipts[i];
    const [receipt, transaction, code] = await Promise.all([rpc('eth_getTransactionReceipt', [entry.hash]), rpc('eth_getTransactionByHash', [entry.hash]), rpc('eth_getCode', [tx.predictedAddress, 'latest'])]);
    assert.equal(receipt.status, '0x1'); assert.equal(receipt.contractAddress.toLowerCase(), tx.predictedAddress.toLowerCase());
    assert.equal(transaction.from.toLowerCase(), draft.deployer.toLowerCase()); assert.equal(transaction.to, null);
    assert.equal(BigInt(transaction.value), 0n); assert.equal(BigInt(transaction.nonce), BigInt(tx.nonce));
    assert.equal(keccak256(transaction.input), tx.dataHash); assert.equal(keccak256(code), tx.simulatedRuntimeHash);
    assert.equal(a[tx.name], tx.predictedAddress);
    deploymentSpent += BigInt(receipt.gasUsed) * BigInt(receipt.effectiveGasPrice);
  }));
  for (const r of activation.registrations) {
    for (const type of ['market', 'sideToken']) {
      const implementation = r[`${type}Implementation`];
      assert.equal(keccak256(await rpc('eth_getCode', [implementation, 'latest'])), r[`${type}ImplementationCodeHash`]);
      assert.equal(await registry('expectedCloneRuntimeCodeHash', [implementation]), r[`${type}CloneRuntimeCodeHash`]);
    }
  }
  operationId = await timelock('hashOperationBatch', batchArgs);
}
async function verifyLive() {
  assert.equal(BigInt(await rpc('eth_chainId', [])), 5042n);
  const block = await rpc('eth_blockNumber', []);
  const [liveOwners, threshold, version, singleton, modules, delay, nonce, timestamp, blockInfo] = await Promise.all([
    safeRead('getOwners', [], block), safeRead('getThreshold', [], block), safeRead('VERSION', [], block), safeRead('masterCopy', [], block),
    safeRead('getModulesPaginated', ['0x0000000000000000000000000000000000000001', 20n], block),
    timelock('getMinDelay', [], block), safeRead('nonce', [], block), timelock('getTimestamp', [operationId], block), rpc('eth_getBlockByNumber', [block, false]),
  ]);
  assert.deepEqual(liveOwners.map(x => x.toLowerCase()).sort(), owners.map(x => x.toLowerCase()).sort());
  assert.equal(threshold, 2n); assert.equal(version, '1.5.0'); assert.equal(delay, 600n);
  assert.equal(singleton.toLowerCase(), '0xedd160febbd92e350d4d398fb636302fccd67c7e');
  assert.equal(modules[0].length, 0); assert.equal(modules[1], '0x0000000000000000000000000000000000000001');
  await Promise.all([
    ...draft.transactions.map(async tx => assert.equal(keccak256(await rpc('eth_getCode', [tx.predictedAddress, block])), tx.simulatedRuntimeHash)),
    ...['guard_manager.guard.address', 'module_manager.module_guard.address'].map(async key => assert.equal(BigInt(await rpc('eth_getStorageAt', [safe, keccak256(toHex(key)), block])), 0n)),
  ]);
  assert.equal(keccak256(await rpc('eth_getCode', [safe, block])), '0x4e381985ca68b3e5d27b4425fa581c19cf33146d3f887a3cfca96f55528ea46f');
  assert.equal(keccak256(await rpc('eth_getCode', [singleton, block])), '0x180193227186ccb85316c94db1f0d156ed932b14712cfaac78901899178572dc');
  const handler = await rpc('eth_getStorageAt', [safe, keccak256(toHex('fallback_manager.handler.address')), block]);
  assert.equal('0x' + handler.slice(-40).toLowerCase(), '0x3efcbb83a4a7afcb4f68d501e2c2203a38be77f4');
  const [versionCount, defaultVersion, registrar, implSlot] = await Promise.all([
    registry('versionCount', [], block), factory('defaultMarketVersion', [], block), registry('registrar', [], block),
    rpc('eth_getStorageAt', [a.ERC1967Proxy, '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc', block]),
  ]);
  assert.equal('0x' + implSlot.slice(-40).toLowerCase(), a.XBIDFactory.toLowerCase());
  assert.equal(await factory('governanceTimelock', [], block), a.TimelockController);
  if (timestamp === 1n) { assert.equal(versionCount, BigInt(targetVersion)); assert.equal(defaultVersion, targetVersion); assert.equal(registrar, a.ERC1967Proxy); }
  else { assert.equal(versionCount, isV4Upgrade ? 3n : 0n); assert.equal(defaultVersion, isV4Upgrade ? 3 : 0); assert.equal(registrar, isV4Upgrade ? a.ERC1967Proxy : a.TimelockController); }
  if (isV4Upgrade) {
    assert.equal(await read(a.MarketVaultV4, abi('MarketVaultV4'), 'CROWN_ACTIVATION_RESERVE_UNITS', [], block), 15_000_000_000n);
    const legacy = await registry('getVersion', [3], block);
    const upgraded = activation.registrations[0];
    for (const key of ['sideTokenImplementation', 'sideTokenImplementationCodeHash', 'sideTokenCloneRuntimeCodeHash', 'feeVault', 'feeVaultVersion', 'riskController', 'riskControllerVersion', 'settlementToken', 'abiVersion']) assert.equal(legacy[key], upgraded[key], key + ' changed');
  }
  const now = BigInt(blockInfo.timestamp);
  return { block: BigInt(block).toString(), nonce: nonce.toString(), timestamp: timestamp.toString(),
    stage: timestamp === 1n ? 'done' : timestamp === 0n ? 'schedule' : timestamp > now ? 'waiting' : 'execute',
    readyAt: timestamp > 1n ? new Date(Number(timestamp) * 1000).toISOString() : null,
    secondsRemaining: timestamp > now ? Number(timestamp - now) : 0, versionCount: versionCount.toString(), defaultVersion };
}
const fields = [
  ['to', 'address'], ['value', 'uint256'], ['data', 'bytes'], ['operation', 'uint8'], ['safeTxGas', 'uint256'],
  ['baseGas', 'uint256'], ['gasPrice', 'uint256'], ['gasToken', 'address'], ['refundReceiver', 'address'], ['nonce', 'uint256'],
].map(([name, type]) => ({ name, type }));
function typedData(stage, nonce) {
  return { domain: { chainId: 5042, verifyingContract: safe }, types: { EIP712Domain: [{ name: 'chainId', type: 'uint256' }, { name: 'verifyingContract', type: 'address' }], SafeTx: fields },
    primaryType: 'SafeTx', message: { to: a.TimelockController, value: '0', data: calldata[stage], operation: 0, safeTxGas: '0', baseGas: '0', gasPrice: '0', gasToken: zeroAddress, refundReceiver: zeroAddress, nonce } };
}
function safeArgs(data) { const m = data.message; return [m.to, BigInt(m.value), m.data, m.operation, BigInt(m.safeTxGas), BigInt(m.baseGas), BigInt(m.gasPrice), m.gasToken, m.refundReceiver]; }
const spent = () => deploymentSpent + journal.receipts.reduce((s, r) => s + BigInt(r.gasUsed) * BigInt(r.effectiveGasPrice), 0n);
function unlocked() { assert.equal(journal.pending, null, '已有待确认交易，先刷新回执，勿重复发送。'); assert.equal(journal.halted, null, '已停止：' + journal.halted); }
async function prepare() {
  unlocked(); const live = await verifyLive();
  assert.ok(['schedule', 'execute'].includes(live.stage), live.stage === 'waiting' ? `尚需等待 ${live.secondsRemaining} 秒。` : '治理激活已完成。');
  if (live.stage === 'execute') assert.ok(journal.receipts.some(r => r.stage === 'schedule' && r.success), '先记录排队交易回执及实际费用。');
  const data = typedData(live.stage, live.nonce); const hash = hashTypedData(data);
  assert.equal(await safeRead('getTransactionHash', [...safeArgs(data), BigInt(live.nonce)]), hash);
  const old = journal.stages[live.stage];
  if (old) assert.equal(old.hash, hash, 'Safe nonce 或提案发生变化，停止并重新审核。');
  else { journal.stages[live.stage] = { hash, typedData: data, signatures: {}, quoted: null }; save(); }
  // Real timelock permission and calldata simulation, no state override or broadcast.
  await rpc('eth_call', [{ from: safe, to: a.TimelockController, data: calldata[live.stage], value: '0x0' }, 'latest']);
  return { ...live, hash, typedData: data, signedOwners: Object.keys(journal.stages[live.stage].signatures) };
}
async function addSignature(body) {
  const p = await prepare(); assert.equal(body.hash, p.hash);
  assert.match(body.signature, /^0x[0-9a-fA-F]{130}$/);
  let signature = body.signature.toLowerCase(); let recovery = parseInt(signature.slice(-2), 16);
  if (recovery === 0 || recovery === 1) { recovery += 27; signature = signature.slice(0, -2) + recovery.toString(16); }
  assert.ok(recovery === 27 || recovery === 28, '仅接受 EIP-712 EOA 签名。');
  const owner = (await recoverTypedDataAddress({ ...p.typedData, signature })).toLowerCase();
  assert.equal(owner, body.owner.toLowerCase()); assert.ok(owners.some(o => o.toLowerCase() === owner), '不是治理签名人。');
  assert.equal(await rpc('eth_getCode', [owner, 'latest']), '0x', '当前流程仅支持普通 EOA 签名人。');
  journal.stages[p.stage].signatures[owner] = signature; save();
  return { stage: p.stage, hash: p.hash, signedOwners: Object.keys(journal.stages[p.stage].signatures) };
}
async function quote(body) {
  assert.equal(body.account?.toLowerCase(), draft.deployer.toLowerCase(), '请切换回部署钱包支付 gas。');
  const p = await prepare(); const entry = journal.stages[p.stage];
  const signed = Object.entries(entry.signatures).sort(([x], [y]) => x < y ? -1 : 1).slice(0, 2);
  assert.equal(signed.length, 2, '需要两位不同治理签名人。');
  for (const [owner, signature] of signed) assert.equal((await recoverTypedDataAddress({ ...p.typedData, signature })).toLowerCase(), owner);
  const signatures = '0x' + signed.map(([, s]) => s.slice(2)).join('');
  await safeRead('checkNSignatures', [draft.deployer, p.hash, signatures, 2n]);
  const data = encodeFunctionData({ abi: safeAbi, functionName: 'execTransaction', args: [...safeArgs(p.typedData), signatures] });
  const call = { from: draft.deployer, to: safe, data, value: '0x0' };
  const simulated = await rpc('eth_call', [call, 'latest']);
  assert.equal(decodeFunctionResult({ abi: safeAbi, functionName: 'execTransaction', data: simulated }), true, 'Safe 执行模拟未成功。');
  const gas = (BigInt(await rpc('eth_estimateGas', [call])) * 125n + 99n) / 100n;
  const maxFeePerGas = BigInt(await rpc('eth_gasPrice', [])) * 2n;
  const cost = gas * maxFeePerGas;
  assert.ok(spent() + cost <= parseUnits('1.5', 18), '累计费用上限超过 1.5 USDC，需要用户另行批准。');
  const nonce = await rpc('eth_getTransactionCount', [draft.deployer, 'pending']);
  assert.equal(nonce, await rpc('eth_getTransactionCount', [draft.deployer, 'latest']), '部署钱包存在待确认交易。');
  assert.ok(BigInt(await rpc('eth_getBalance', [draft.deployer, 'latest'])) >= cost, '支付 gas 的 USDC 不足。');
  const transaction = { ...call, nonce, chainId: '0x13b2', gas: toHex(gas), maxFeePerGas: toHex(maxFeePerGas), maxPriorityFeePerGas: '0x0' };
  entry.quoted = { dataHash: keccak256(data), nonce, transaction }; save();
  return { stage: p.stage, hash: p.hash, maxCostUsdc: formatUnits(cost, 18), spentUsdc: formatUnits(spent(), 18),
    cumulativeCeilingUsdc: formatUnits(spent() + cost, 18), transaction };
}
async function receipt(body) {
  assert.match(body.hash, /^0x[0-9a-fA-F]{64}$/);
  const known = journal.receipts.find(r => r.hash.toLowerCase() === body.hash.toLowerCase());
  if (known) return { pending: false, receipt: known, spentUsdc: formatUnits(spent(), 18) };
  if (journal.pending) assert.equal(journal.pending.hash.toLowerCase(), body.hash.toLowerCase(), '已有其他待确认交易。');
  assert.ok(['schedule', 'execute'].includes(body.stage));
  const entry = journal.stages[body.stage]; assert.ok(entry?.quoted, '必须先检查并模拟这笔交易。');
  if (!journal.pending) { journal.pending = { hash: body.hash, stage: body.stage }; save(); }
  const tx = await rpc('eth_getTransactionByHash', [body.hash]);
  if (!tx) return { pending: true, hash: body.hash };
  assert.equal(tx.from.toLowerCase(), draft.deployer.toLowerCase()); assert.equal(tx.to.toLowerCase(), safe.toLowerCase());
  assert.equal(BigInt(tx.value), 0n); assert.equal(BigInt(tx.nonce), BigInt(entry.quoted.nonce));
  assert.equal(keccak256(tx.input), entry.quoted.dataHash);
  const r = await rpc('eth_getTransactionReceipt', [body.hash]);
  if (!r) return { pending: true, hash: body.hash };
  const success = r.status === '0x1';
  const item = { hash: body.hash, stage: body.stage, safeTxHash: entry.hash, success, blockNumber: Number(BigInt(r.blockNumber)),
    gasUsed: BigInt(r.gasUsed).toString(), effectiveGasPrice: BigInt(r.effectiveGasPrice).toString() };
  journal.receipts.push(item); journal.pending = null;
  if (!success) journal.halted = '交易失败，已计入 gas 费用，需排查后继续。';
  save(); assert.ok(success, journal.halted);
  // A mined transaction alone is not sufficient: verify the intended timelock outcome.
  const timestamp = await timelock('getTimestamp', [operationId]);
  try {
    if (body.stage === 'schedule') assert.ok(timestamp > 1n);
    else { assert.equal(timestamp, 1n); assert.equal(await factory('defaultMarketVersion'), targetVersion); assert.equal(await registry('versionCount'), BigInt(targetVersion)); }
    assert.equal(await safeRead('nonce'), BigInt(entry.typedData.message.nonce) + 1n);
  } catch (e) { journal.halted = '回执后状态不符：' + e.message; save(); throw e; }
  return { pending: false, receipt: item, spentUsdc: formatUnits(spent(), 18), readyAt: timestamp > 1n ? new Date(Number(timestamp) * 1000).toISOString() : null };
}
await verifyDeployments(); const initial = await verifyLive();
const token = randomBytes(24).toString('hex');
const base = `http://127.0.0.1:${port}`;
const html = readFileSync(new URL('arc-wallet-review/governance.html', import.meta.url));
const js = readFileSync(new URL('arc-wallet-review/governance.js', import.meta.url));
let busy = false;
createServer(async (req, res) => {
  const reply = (status, data, type = 'application/json; charset=utf-8') => {
    res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'" });
    res.end(Buffer.isBuffer(data) ? data : json(data));
  };
  if (req.headers.host !== `127.0.0.1:${port}`) return reply(404, {});
  if (req.method === 'GET' && req.url === '/') return reply(200, html, 'text/html; charset=utf-8');
  if (req.method === 'GET' && req.url === '/governance.js') return reply(200, js, 'text/javascript; charset=utf-8');
  if (req.method === 'GET' && req.url === '/state') return reply(200, { token, safe, owners, deployer: draft.deployer, operationId,
    targetVersion, crownActivationReserveUnits: draft.crownActivationReserveUnits,
    spentUsdc: formatUnits(spent(), 18), pending: journal.pending, halted: journal.halted,
    signed: Object.fromEntries(Object.entries(journal.stages).map(([k, s]) => [k, Object.keys(s.signatures)])) });
  if (req.method !== 'POST' || !['/inspect', '/prepare', '/signature', '/quote', '/receipt'].includes(req.url)) return reply(404, {});
  if (req.headers.origin !== base || req.headers['x-xbid-token'] !== token) return reply(403, { error: 'Same-origin authorization required.' });
  if (busy) return reply(409, { error: '检查进行中，请稍后。' }); busy = true;
  try {
    let raw = ''; for await (const chunk of req) { raw += chunk; if (raw.length > 4096) throw new Error('Request too large.'); }
    const body = JSON.parse(raw || '{}');
    const result = await ({ '/inspect': verifyLive, '/prepare': prepare, '/signature': addSignature, '/quote': quote, '/receipt': receipt })[req.url](body);
    reply(200, result);
  } catch (e) { reply(400, { error: e.message }); } finally { busy = false; }
}).listen(port, '127.0.0.1', () => console.log(json({ url: base, stage: initial.stage, operationId, spentUsdc: formatUnits(spent(), 18), message: 'No signing or broadcasting on server. User must explicitly confirm each wallet action.' })));
