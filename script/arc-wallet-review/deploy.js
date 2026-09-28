const el = (id) => document.getElementById(id);
const providers = new Map();
let provider, state, quote, pending, sending = false;
function add(id, name, candidate) {
  if (!candidate?.request || providers.has(id) || [...providers.values()].some((x) => x.provider === candidate)) return;
  providers.set(id, { name, provider: candidate });
  const option = new Option(name, id); el("wallet").append(option); el("connect").disabled = !state;
}
window.addEventListener("eip6963:announceProvider", (event) => { if (event.detail?.info?.uuid) add(event.detail.info.uuid, event.detail.info.name || "钱包", event.detail.provider); });
window.dispatchEvent(new Event("eip6963:requestProvider"));
async function post(path, body = {}) {
  const response = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json", "x-xbid-token": state.token }, body: JSON.stringify(body) });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || "检查失败");
  return result;
}
function clearQuote() { quote = null; el("send").disabled = true; el("consent").checked = false; }
async function verifyWallet() {
  if (!provider) throw new Error("请先连接钱包。");
  const accounts = await provider.request({ method: "eth_accounts" });
  const chain = await provider.request({ method: "eth_chainId" });
  if (accounts[0]?.toLowerCase() !== state.deployer.toLowerCase()) throw new Error(`账户必须为 ${state.deployer}`);
  if (BigInt(chain) !== 5042n) throw new Error("请在钱包中切换到 Arc 主网 (5042)。");
  return accounts[0];
}
async function refresh() {
  state = await (await fetch("/state")).json();
  pending = pending || state.pendingHash || sessionStorage.getItem(`xbid-pending-${state.sourceCommit}`);
  el("source").textContent = `合约源码 ${state.sourceCommit} · 已验证 ${state.completed}/10 笔 · 已花 gas ${state.spentUsdc} USDC`;
  el("connect").disabled = !providers.size;
  if (pending) {
    el("check").disabled = true; el("send").disabled = true;
    const result = await post("/receipt", { hash: pending });
    el("receipt").textContent = JSON.stringify(result, null, 2);
    if (!result.pending) {
      sessionStorage.removeItem(`xbid-pending-${state.sourceCommit}`); pending = null; clearQuote();
      state = await (await fetch("/state")).json();
      el("source").textContent = `合约源码 ${state.sourceCommit} · 已验证 ${state.completed}/10 笔 · 已花 gas ${state.spentUsdc} USDC`;
      el("check").disabled = !provider || state.completed >= 10;
    }
  }
}
el("wallet").addEventListener("change", () => { provider = null; clearQuote(); el("check").disabled = true; el("account").textContent = "钱包已更换，请重新连接。"; });
el("connect").addEventListener("click", async () => {
  try {
    provider = providers.get(el("wallet").value)?.provider;
    if (!provider) throw new Error("未找到钱包。");
    await provider.request({ method: "eth_requestAccounts" });
    el("account").textContent = `账户：${await verifyWallet()}\nArc 主网 (5042)，匹配。`;
    clearQuote(); el("check").disabled = Boolean(pending) || state.completed >= 10;
  } catch (error) { el("account").textContent = error.message; clearQuote(); el("check").disabled = true; }
});
el("check").addEventListener("click", async () => {
  clearQuote(); el("check").disabled = true; el("quote").textContent = "正在核对链、nonce、余额、已部署代码和费用…";
  try {
    await verifyWallet(); quote = await post("/quote");
    el("quote").textContent = `第 ${quote.order}/10 笔：${quote.name}\n预计合约：${quote.address}\n本笔最大 gas 费用：${quote.maxCostUsdc} USDC\n已花 + 剩余合约缓冲：${quote.remainingContractCeilingUsdc} USDC\n调用数据哈希：${quote.dataHash}\n转账 value：0 USDC（仅支付 gas）`;
  } catch (error) { el("quote").textContent = error.message; }
  finally { el("check").disabled = Boolean(pending); }
});
el("consent").addEventListener("change", () => { el("send").disabled = !quote || !el("consent").checked || sending || Boolean(pending); });
el("send").addEventListener("click", async () => {
  if (sending || pending || !quote || !el("consent").checked) return;
  sending = true; el("send").disabled = true; el("check").disabled = true;
  try {
    await verifyWallet();
    const fresh = await post("/quote");
    if (fresh.dataHash !== quote.dataHash || fresh.transaction.nonce !== quote.transaction.nonce || BigInt(fresh.transaction.gas) > BigInt(quote.transaction.gas) || BigInt(fresh.transaction.maxFeePerGas) > BigInt(quote.transaction.maxFeePerGas)) {
      throw new Error("参数或费用上升，请重新检查并确认。");
    }
    el("receipt").textContent = "请在钱包弹窗中核对并亲自确认。不想发送时可在钱包拒绝。";
    // ONLY this explicit user click can request a signed/broadcast transaction.
    pending = await provider.request({ method: "eth_sendTransaction", params: [fresh.transaction] });
    sessionStorage.setItem(`xbid-pending-${state.sourceCommit}`, pending);
    el("receipt").textContent = `已提交 ${pending}。点击刷新检查回执，勿重复发送。`;
    await refresh();
  } catch (error) { el("receipt").textContent = error.message; }
  finally { sending = false; clearQuote(); el("check").disabled = Boolean(pending) || state.completed >= 10; }
});
el("refresh").addEventListener("click", () => refresh().catch((error) => { el("receipt").textContent = error.message; }));
refresh().then(() => {
  if (window.okxwallet) add("okx", "OKX Wallet", window.okxwallet);
  for (const [i, candidate] of (window.ethereum?.providers || (window.ethereum ? [window.ethereum] : [])).entries()) add(`injected-${i}`, candidate.isRabby ? "Rabby" : candidate.isBraveWallet ? "Brave Wallet" : "浏览器钱包", candidate);
}).catch((error) => { el("receipt").textContent = error.message; });
