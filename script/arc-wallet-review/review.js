/* global ethereum, okxwallet */
// Deliberately no eth_sendTransaction, personal_sign, or typed-data signing.
const wallets = new Map();
const select = document.querySelector("#wallet");
const state = document.querySelector("#wallet-state");
const connect = document.querySelector("#connect");
const switchNetwork = document.querySelector("#switch");
let connected;
let draft;
select.addEventListener("change", () => {
  connected = undefined;
  switchNetwork.disabled = true;
  state.textContent = "已更换钱包，请重新连接并核对部署账户。";
});
function addWallet(id, name, provider) {
  if (!provider?.request || wallets.has(id) || [...wallets.values()].some((w) => w.provider === provider)) return;
  wallets.set(id, { name, provider });
  const selected = select.value;
  select.replaceChildren(...[...wallets].map(([key, wallet]) => {
    const option = document.createElement("option"); option.value = key; option.textContent = wallet.name; return option;
  }));
  if (wallets.has(selected)) select.value = selected;
  connect.disabled = !draft;
}
window.addEventListener("eip6963:announceProvider", (event) => {
  if (event.detail?.info?.uuid) addWallet(event.detail.info.uuid, event.detail.info.name || "浏览器钱包", event.detail.provider);
});
window.dispatchEvent(new Event("eip6963:requestProvider"));
function legacyProviders() {
  if (window.okxwallet) addWallet("okx", "OKX Wallet", window.okxwallet);
  for (const [i, provider] of (window.ethereum?.providers || (window.ethereum ? [window.ethereum] : [])).entries()) {
    addWallet(`injected-${i}`, provider.isRabby ? "Rabby" : provider.isOkxWallet ? "OKX Wallet" : provider.isBraveWallet ? "Brave Wallet" : provider.isMetaMask ? "MetaMask / injected wallet" : "浏览器钱包", provider);
  }
  if (!wallets.size) {
    select.replaceChildren(new Option("未检测到钱包，请解锁扩展后刷新", ""));
    connect.disabled = true;
  }
}
async function checkWallet(provider) {
  const accounts = await provider.request({ method: "eth_accounts" });
  const chain = await provider.request({ method: "eth_chainId" });
  const matches = accounts[0]?.toLowerCase() === draft.deployer.toLowerCase();
  state.textContent = `账户：${accounts[0] || "未连接"}\n账户核对：${matches ? "与部署地址一致" : "不匹配，请在钱包中切换至下方部署地址"}\n网络：${Number(BigInt(chain)) === 5042 ? "Arc 主网 (5042)" : `当前 ${Number(BigInt(chain))}，需要 Arc 主网 (5042)`}\n此步骤没有签名或发送交易。`;
  switchNetwork.disabled = !matches || Number(BigInt(chain)) === 5042;
}
connect.addEventListener("click", async () => {
  connect.disabled = true;
  try {
    const wallet = wallets.get(select.value);
    if (!wallet) throw new Error("未检测到所选钱包。");
    connected = wallet.provider;
    state.textContent = "请在钱包弹窗中确认连接，仅请求公开账户地址。";
    await connected.request({ method: "eth_requestAccounts" });
    await checkWallet(connected);
  } catch (error) { state.textContent = String(error.message || error); }
  finally { connect.disabled = false; }
});
switchNetwork.addEventListener("click", async () => {
  if (!connected) return;
  try {
    await connected.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x13b2" }] });
    await checkWallet(connected);
  } catch (error) { state.textContent = `未切换网络：${error.message || error}。请在钱包中手动选择 Arc 主网 (5042)。`; }
});
async function load() {
  const response = await fetch("/review.json");
  if (!response.ok) throw new Error("无法读取审阅草案。");
  draft = await response.json();
  if (draft.chainId !== 5042 || draft.status !== "UNSIGNED_DRAFT_NOT_DEPLOYED") throw new Error("草案网络或状态不匹配。");
  const args = draft.transactions.find((tx) => tx.name === "FeeVault").constructorArgs;
  const factoryArgs = draft.transactions.find((tx) => tx.name === "ERC1967Proxy");
  if (!factoryArgs) throw new Error("缺少 Factory 代理交易。");
  const items = [
    ["部署账户", draft.deployer], ["治理多签 · 2/3", draft.safeChecks[0].safe], ["应急多签 · 2/3", draft.safeChecks[1].safe],
    ["普通治理延迟", "10 分钟（600 秒）"], ["交易恢复延迟", "5 分钟（300 秒），暂停立即生效"],
    ["平台交易费收款", args[5]], ["交易费分账", "平台 50% / 创建者 40% / 推荐人 10%"],
    ["总交易费率", "1%（分账比例不是总交易费率）"], ["创建竞赛费", `5 USDC；收款：${draft.reviewParameters.creationTreasury}`],
    ["草案时间", draft.generatedAt], ["草案源码状态", draft.sourceDirty ? "未提交，禁止直接签名" : "已提交；仍须完成最终复核"],
  ];
  for (const [label, value] of items) {
    const dt = document.createElement("dt"); dt.textContent = label;
    const dd = document.createElement("dd"); dd.textContent = value;
    document.querySelector("#parameters").append(dt, dd);
  }
  document.querySelector("#cost").textContent = `合约部分估算 ${Number(draft.cost.contractsEstimatedUsdc).toFixed(4)} USDC；包含 gas 余量与价格缓冲：${Number(draft.cost.contractsFeeCeilingUsdc).toFixed(4)} USDC。快照区块 ${draft.blockNumber}。`;
  for (const tx of draft.transactions) {
    const tr = document.createElement("tr");
    for (const value of [tx.order, tx.name, tx.predictedAddress, tx.estimatedGas]) {
      const td = document.createElement("td"); td.textContent = String(value); tr.append(td);
    }
    document.querySelector("#transactions").append(tr);
  }
  legacyProviders();
  connect.disabled = !wallets.size;
}
load().catch((error) => { state.textContent = error.message; connect.disabled = true; switchNetwork.disabled = true; });
