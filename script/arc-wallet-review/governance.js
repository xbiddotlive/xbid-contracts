const el = id => document.getElementById(id);
const providers = new Map();
let provider, state, proposal, quote, busy = false, pending;
function add(id, name, p) {
  if (!p?.request || [...providers.values()].some(x => x.provider === p)) return;
  providers.set(id, { provider: p, name }); el('wallet').append(new Option(name, id)); update();
}
function clear() { proposal = null; quote = null; el('signConsent').checked = false; el('sendConsent').checked = false; update(); }
function update() {
  el('connect').disabled = busy || !state || !providers.size;
  el('prepare').disabled = busy || !provider || !!pending;
  el('sign').disabled = busy || !!pending || !proposal || !el('signConsent').checked;
  el('quote').disabled = busy || !!pending || !provider || !proposal || proposal.signedOwners.length < 2;
  el('send').disabled = busy || !!pending || !quote || !el('sendConsent').checked;
  el('refresh').disabled = busy;
}
async function post(path, body = {}) {
  const r = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-xbid-token': state.token }, body: JSON.stringify(body) });
  const result = await r.json(); if (!r.ok) throw new Error(result.error || '检查失败'); return result;
}
async function wallet() {
  if (!provider) throw new Error('请连接治理钱包。');
  const accounts = await provider.request({ method: 'eth_accounts' });
  if (BigInt(await provider.request({ method: 'eth_chainId' })) !== 5042n) throw new Error('请在钱包切换到 Arc 主网 (5042)。');
  if (!state.owners.some(x => x.toLowerCase() === accounts[0]?.toLowerCase())) throw new Error('当前账户不是三位治理签名人之一。');
  return accounts[0];
}
async function action(fn) {
  if (busy) return; busy = true; update(); el('status').textContent = '正在检查，请稍候…';
  try { await fn(); } catch (e) { el('status').textContent = e.message; quote = null; }
  finally { busy = false; update(); }
}
function showProposal(p) {
  proposal = p; quote = null; el('signConsent').checked = false; el('sendConsent').checked = false;
  el('proposal').textContent = `阶段：${p.stage === 'schedule' ? '提交排队提案（等待 10 分钟）' : '执行激活（默认 V3）'}\nSafe nonce：${p.nonce}\nSafe 交易哈希：${p.hash}\n转账金额：0 USDC · Safe gas 退款：0\n目标：${p.typedData.message.to}`;
  el('typed').textContent = JSON.stringify(p.typedData, null, 2);
  el('signatures').textContent = `已验证签名 ${p.signedOwners.length}/2\n${p.signedOwners.join('\n')}`;
}
async function refresh() {
  state = await (await fetch('/state')).json();
  pending = state.pending || JSON.parse(sessionStorage.getItem('xbid-arc-governance-pending') || 'null');
  el('summary').textContent = `治理 Safe：${state.safe}\n累计已花：${state.spentUsdc} USDC\n操作 ID：${state.operationId}\n治理签名人：\n${state.owners.join('\n')}`;
  if (pending) {
    const r = await post('/receipt', pending); el('status').textContent = JSON.stringify(r, null, 2);
    if (r.pending) return;
    sessionStorage.removeItem('xbid-arc-governance-pending'); pending = null; clear();
    state = await (await fetch('/state')).json();
  }
  const live = await post('/inspect');
  const labels = { schedule: '等待两位签名人提交排队提案', waiting: `提案已排队，还需 ${live.secondsRemaining} 秒`, execute: '等待期已结束，可单独签名并执行激活', done: '治理激活完成，默认版本 V3' };
  el('status').textContent = `${labels[live.stage]}\n链上注册版本：${live.versionCount} · 默认版本：${live.defaultVersion}\n累计 gas：${state.spentUsdc} USDC${live.readyAt ? '\n可执行时间：' + new Date(live.readyAt).toLocaleString() : ''}${state.halted ? '\n停止：' + state.halted : ''}`;
  if (proposal && proposal.stage !== live.stage) clear();
}
window.addEventListener('eip6963:announceProvider', e => { if (e.detail?.info?.uuid) add(e.detail.info.uuid, e.detail.info.name || '钱包', e.detail.provider); });
window.dispatchEvent(new Event('eip6963:requestProvider'));
el('wallet').addEventListener('change', () => { provider = null; clear(); el('account').textContent = '钱包已更换，请重新连接。'; });
el('connect').addEventListener('click', () => action(async () => {
  provider = providers.get(el('wallet').value)?.provider;
  await provider.request({ method: 'eth_requestAccounts' });
  provider.on?.('accountsChanged', () => { clear(); el('account').textContent = '账户已切换，请重新连接并检查提案。'; });
  provider.on?.('chainChanged', () => { clear(); el('account').textContent = '网络已更换，请重新连接。'; });
  clear(); el('account').textContent = `治理签名人：${await wallet()}\n网络：Arc 主网 (5042)`;
  el('status').textContent = '已连接。点击「检查当前提案」。';
}));
el('prepare').addEventListener('click', () => action(async () => { await wallet(); showProposal(await post('/prepare')); el('status').textContent = '链上状态和提案已核对。请阅读并自行决定是否签名。'; }));
el('signConsent').addEventListener('change', update); el('sendConsent').addEventListener('change', update);
el('sign').addEventListener('click', () => action(async () => {
  const owner = await wallet(); const fresh = await post('/prepare');
  if (!proposal || fresh.hash !== proposal.hash || !el('signConsent').checked) throw new Error('提案变化，请重新核对。');
  if (fresh.signedOwners.includes(owner.toLowerCase())) throw new Error('此账户已签名，请切换另一位治理签名人。');
  el('status').textContent = '请在钱包中亲自核对并确认治理签名。';
  // Only explicit user click invokes this financial authorization request.
  const signature = await provider.request({ method: 'eth_signTypedData_v4', params: [owner, JSON.stringify(fresh.typedData)] });
  const result = await post('/signature', { hash: fresh.hash, owner, signature });
  showProposal({ ...fresh, signedOwners: result.signedOwners });
  el('status').textContent = result.signedOwners.length >= 2 ? '已收齐两份签名。切回部署钱包后检查上链费用。' : '第一份签名已验证。请切换另一位治理签名人，重新连接并检查同一提案。';
}));
el('quote').addEventListener('click', () => action(async () => {
  const account = await wallet(); quote = await post('/quote', { account }); el('sendConsent').checked = false;
  el('fee').textContent = `阶段：${quote.stage}\nSafe 哈希：${quote.hash}\n本笔 gas 费用上限：${quote.maxCostUsdc} USDC\n累计已花 + 本笔上限：${quote.cumulativeCeilingUsdc} USDC\n支付账户：${quote.transaction.from}\nSafe 执行模拟：成功${quote.stage === 'schedule' ? '\n尚未包含等待期后执行交易的 gas。' : ''}`;
  el('status').textContent = '两份签名已通过链上验证，完整 Safe 执行模拟通过；请亲自确认是否发送。';
}));
el('send').addEventListener('click', () => action(async () => {
  if (!quote || !el('sendConsent').checked || pending) throw new Error('先检查费用并确认。');
  const account = await wallet(); const fresh = await post('/quote', { account });
  if (fresh.hash !== quote.hash || fresh.transaction.data !== quote.transaction.data || fresh.transaction.nonce !== quote.transaction.nonce || BigInt(fresh.transaction.gas) > BigInt(quote.transaction.gas) || BigInt(fresh.transaction.maxFeePerGas) > BigInt(quote.transaction.maxFeePerGas)) throw new Error('参数或费用变化，请重新检查并确认。');
  el('status').textContent = '请在钱包中亲自确认发送。';
  const hash = await provider.request({ method: 'eth_sendTransaction', params: [fresh.transaction] });
  pending = { hash, stage: fresh.stage }; sessionStorage.setItem('xbid-arc-governance-pending', JSON.stringify(pending));
  clear(); const result = await post('/receipt', pending); el('status').textContent = JSON.stringify(result, null, 2);
  if (!result.pending) { sessionStorage.removeItem('xbid-arc-governance-pending'); pending = null; }
}));
el('refresh').addEventListener('click', () => action(refresh));
action(async () => {
  await refresh();
  if (window.okxwallet) add('okx', 'OKX Wallet', window.okxwallet);
  for (const [i, p] of (window.ethereum?.providers || (window.ethereum ? [window.ethereum] : [])).entries()) add(`injected-${i}`, p.isRabby ? 'Rabby' : p.isBraveWallet ? 'Brave Wallet' : '浏览器钱包', p);
});
