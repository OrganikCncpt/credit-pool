import {
  createPublicClient, createWalletClient, custom, http, parseAbi, formatEther, parseEther, defineChain,
} from "https://cdn.jsdelivr.net/npm/viem@2.56.8/+esm";
import { DEPLOYMENTS, DEFAULT_CHAIN } from "./config.js";

// ───────────────────────── ABIs ─────────────────────────
const POOL_ABI = parseAbi([
  "function assemblyOpensAt() view returns (uint256)",
  "function statements() view returns (address)",
  "function credits() view returns (address)",
  "function openBatchId() view returns (uint256)",
  "function accruedFees() view returns (uint256)",
  "function depositFee() view returns (uint256)",
  "function batchInfo(uint256) view returns (uint8 state, uint256 filled, uint256 depositorCount, uint256 statementId, uint256 proceeds, uint64 fullAt)",
  "function batchCredits(uint256) view returns (uint256[])",
  "function batchDepositors(uint256) view returns (address[])",
  "function slots(uint256, address) view returns (uint256)",
  "function reservePref(uint256, address) view returns (uint256)",
  "function claimed(uint256, address) view returns (bool)",
  "function depositorOf(uint256) view returns (address)",
  "function auctions(uint256) view returns (address highBidder, uint256 highBid, uint256 reserve, uint64 endsAt)",
  "function currentReserve(uint256) view returns (uint256)",
  "function escapeOpen(uint256) view returns (bool)",
  "function noReserveOpen(uint256) view returns (bool)",
  "function assembledAt(uint256) view returns (uint64)",
  "function pendingReturns(address) view returns (uint256)",
  "function deposit(uint256[] creditIds) payable",
  "function depositAt(uint256[] creditIds, uint256 expectedBatch, uint256 expectedFilled) payable",
  "function withdraw(uint256[] creditIds)",
  "function assemble(uint256 batchId)",
  "function redeem(uint256 batchId)",
  "function setReserve(uint256 batchId, uint256 reserveWei)",
  "function startAuction(uint256 batchId)",
  "function startAuctionAt(uint256 batchId, uint256 expectedReserve)",
  "function auctionReserve(uint256) view returns (uint256)",
  "function lowestVote(uint256) view returns (uint256)",
  "function batchOf(uint256) view returns (uint256)",
  "function bid(uint256 batchId) payable",
  "function settle(uint256 batchId)",
  "function claim(uint256 batchId)",
  "function withdrawRefund()",
  "function sweepFees()",
  "event Deposited(address indexed who, uint256 indexed batchId, uint256 creditId)",
  "event Bid(uint256 indexed batchId, address indexed bidder, uint256 amount, uint256 endsAt)",
  "error WrongBatchState()", "error NotDepositor()", "error InsufficientFee()", "error StaleOracle()",
  "error ReserveQuorumNotMet()", "error BidTooLow()", "error AuctionLive()", "error NothingToClaim()",
  "error TransferFailed()", "error UnexpectedToken()", "error StatementNotReceived()",
  "error CreditsNotBurned()", "error BatchMoved()", "error ZeroAddress()", "error ReserveChanged()",
]);
const CREDITS_ABI = parseAbi([
  "function tokensOf(address) view returns (uint256[])",
  "function tokenURI(uint256) view returns (string)",
  "function art() view returns (address)",
  "function seedOf(uint256) view returns (bytes21)",
  "function timestampOf(uint256) view returns (uint64)",
  "function isApprovedForAll(address, address) view returns (bool)",
  "function setApprovalForAll(address, bool)",
]);

// Jack's on-chain renderer. Seeds and payment times survive the burn, so burned Credits still draw.
const ART_ABI = parseAbi([
  "function svg(bytes21 seed, uint64 paidAt) view returns (string)",
  "function describe(bytes21 seed, uint64 paidAt) view returns ((bytes32 hash, uint256 marks, uint256 capacity, uint256 plates, string colors, uint256 eights, string tier, string weight, string register, string eightsLabel))",
]);
const STATEMENTS_ABI = parseAbi(["function tokenURI(uint256) view returns (string)"]);

const STATES = ["Filling", "Full", "Assembled", "Auction", "Settled", "Redeemed", "Dissolved"];
const PER = 80n;
const PAGE = 9n;
// ~100k gas per Credit; Ethereum caps a tx at 2^24 (16.7M) gas. 100 per tx leaves headroom.
const MAX_PER_TX = 100;
const NO_RESERVE_AFTER = 30n * 86400n;
// Well-known anvil keys, used only with ?dev=N on chain 31337.
const ANVIL_KEYS = [
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
];

// ───────────────────────── tooltips ─────────────────────────
// Every action explains itself on hover/focus. Keep these short and plain.
const TIPS = {
  approve: "Step 1 of 2: approve the pool, then deposit. " +
    "It's a one-time permission, and the pool only ever moves Credits you deposit yourself. You can revoke it any time.",
  selectAll: "Select every Credit in this wallet. Click a Credit to toggle it.",
  deposit: "Step 2 of 2: moves the selected Credits into the open batch. Fee: $1 per Credit, paid in ETH. " +
    "You can withdraw any time until the batch reaches 80.",
  depositNeedsApproval: "Approve the pool first (one time), then pick Credits.",
  depositNeedsPick: "Click the Credits you want to deposit first.",
  depositViewOnly: "View-only: connect this wallet to deposit.",
  withdraw: "Take your Credits back to your wallet. Possible while the batch is still filling, " +
    "or if a full batch can't be assembled for 14 days. The $1 fee isn't refunded.",
  assemble: "Burns this batch's 80 Credits into one Statement, held by the pool for its depositors. " +
    "Anyone can press this. It's permanent.",
  redeem: "You hold all 80 slots, so the Statement is yours: sends it straight to your wallet. No auction, no fee.",
  vote: "The lowest price you'd accept for this Statement. The auction minimum is the lowest price that " +
    "more than 40 of the 80 slots accept, so a small group can't drag it below what most depositors agreed to. Enter 0 to clear your vote.",
  start: "Starts a 24-hour auction at the voted minimum. Opens once voters holding more than 40 of the 80 slots have voted. Anyone can press it.",
  startNoReserve: "This Statement has gone 30 days without selling, so quorum is no longer needed: anyone can start an auction whose minimum is the LOWEST price any depositor voted (none if nobody voted).",
  bid: "Your ETH is held by the pool. If you're outbid, you get it back (Withdraw refund at the top). " +
    "Each bid must beat the last by 5%. Bids in the final 15 minutes add 15 minutes.",
  settle: "Ends the auction: the Statement goes to the winner and depositors can claim. Anyone can press this.",
  claim: "Sends your share of the sale to your wallet: your slots ÷ 80 of the price, after the 1% fee.",
  refund: "ETH from bids where someone outbid you. Sends it back to your wallet.",
  collect: "Sends everything waiting for you to your wallet: your share of each sold Statement, plus any outbid refunds. One transaction per item.",
  viewStatement: "See what's being sold: the 80 Credits burned into this Statement, with their rarity breakdown.",
  viewBatch: "See the Credits in this batch so far, with their rarity breakdown.",
  sweep: "Sends collected platform fees ($1 per Credit deposited + 1% of sales) to the fee wallet. Anyone can trigger it; it can only go there.",
};

const tipEl = () => document.getElementById("tip");
function showTip(target) {
  const text = TIPS[target.dataset.tip] ?? target.dataset.tip;
  if (!text) return;
  const t = tipEl();
  t.textContent = text; t.hidden = false;
  target.setAttribute("aria-describedby", "tip");
  // Place below the control, flip above if there's no room, and keep it inside the viewport.
  const r = target.getBoundingClientRect(), w = t.offsetWidth, h = t.offsetHeight, pad = 8;
  let top = r.bottom + pad;
  if (top + h > innerHeight - pad) top = r.top - h - pad;
  const left = Math.min(Math.max(pad, r.left + r.width / 2 - w / 2), innerWidth - w - pad);
  t.style.top = `${Math.max(pad, top)}px`; t.style.left = `${left}px`;
}
function hideTip(target) {
  tipEl().hidden = true;
  target?.removeAttribute("aria-describedby");
}
for (const [on, off] of [["mouseover", "mouseout"], ["focusin", "focusout"]]) {
  document.addEventListener(on, (e) => { const n = e.target.closest?.("[data-tip]"); if (n) showTip(n); });
  document.addEventListener(off, (e) => { const n = e.target.closest?.("[data-tip]"); if (n && !n.contains(e.relatedTarget)) hideTip(n); });
}
addEventListener("scroll", () => hideTip(), { passive: true });
addEventListener("keydown", (e) => { if (e.key === "Escape") hideTip(); });

// ───────────────────────── state ─────────────────────────
const S = {
  chainId: DEFAULT_CHAIN, dep: null, chain: null, pub: null, wallet: null, account: null,
  pool: null, credits: null, selected: new Set(), cursor: null, clockSkew: 0, approved: false, openBatch: 0n, openFilled: 0n,
  openWho: new Set(), lastBlock: null, refreshing: false,
};
const $ = (id) => document.getElementById(id);
const el = (tag, attrs = {}, ...kids) => {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") n.className = v;
    else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) n.setAttribute(k, v === true ? "" : v);
  }
  for (const k of kids.flat()) if (k != null && k !== false) n.append(k);
  return n;
};
const eth = (wei, dp = 4) => {
  if (wei > 0n && wei < 10n ** BigInt(18 - dp)) return `<0.${"0".repeat(dp - 1)}1 ETH`;
  const [i, f = ""] = formatEther(wei).split(".");
  const t = f.slice(0, dp).replace(/0+$/, "");
  return `${i}${t ? "." + t : ""} ETH`;
};
// Number inputs → wei, or null for anything that isn't a plain non-negative amount.
const toWei = (v) => {
  v = String(v).trim();
  if (!/^(\d+\.?\d{0,18}|\.\d{1,18})$/.test(v)) return null; // ETH has 18 decimals; more would round silently
  try { return parseEther(v); } catch { return null; }
};
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const now = () => BigInt(Math.floor(Date.now() / 1000) + S.clockSkew);
const dur = (s) => {
  s = Number(s); if (s <= 0) return "ended";
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m ${x}s`;
};
const read = (functionName, args = [], address = S.pool, abi = POOL_ABI) =>
  S.pub.readContract({ address, abi, functionName, args });
const tryRead = (...a) => read(...a).catch(() => null);

function toast(msg, err = false, ms = 4000) {
  const t = $("toast");
  t.textContent = msg; t.className = "toast" + (err ? " err" : ""); t.hidden = false;
  clearTimeout(toast.t);
  if (ms) toast.t = setTimeout(() => (t.hidden = true), ms);
}

// ───────────────────────── setup ─────────────────────────
function chainFor(id, dep) {
  return defineChain({
    id, name: dep.name, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [dep.rpc] } },
  });
}

async function init() {
  const params = new URLSearchParams(location.search);
  const dev = params.get("dev");
  // ?view=0x… shows any wallet read-only (no signing; send() refuses without a wallet).
  const view = params.get("view");
  const viewOnly = /^0x[0-9a-fA-F]{40}$/.test(view || "");
  // ?as=0x… (local anvil only): act as any address via anvil impersonation. Demo use only.
  const as = params.get("as");
  const actAs = /^0x[0-9a-fA-F]{40}$/.test(as || "");

  if (window.ethereum && dev == null && !viewOnly && !actAs) {
    const [accts, cid] = await Promise.all([
      window.ethereum.request({ method: "eth_accounts" }),
      window.ethereum.request({ method: "eth_chainId" }),
    ]);
    if (accts[0]) { S.account = accts[0]; S.chainId = Number(cid); }
    window.ethereum.on?.("accountsChanged", () => location.reload());
    window.ethereum.on?.("chainChanged", () => location.reload());
  }

  S.dep = DEPLOYMENTS[S.chainId];
  if (!S.dep) return notice(`Unsupported network (chain ${S.chainId}). Switch to ${Object.values(DEPLOYMENTS).map((d) => d.name).join(" or ")}.`);
  S.chain = chainFor(S.chainId, S.dep);
  S.pub = createPublicClient({ chain: S.chain, transport: http(S.dep.rpc) });
  $("chain").textContent = S.dep.name;
  if (!S.dep.pool) return notice(`credit.pool isn't deployed on ${S.dep.name} yet. It goes live once the Statements contract is published.`);
  S.pool = S.dep.pool;
  if (S.chainId !== 31337 && !S.dep.deployBlock) console.warn("config.js: set deployBlock, or 'Your batches' may fail on public RPCs");

  if (actAs && S.chainId === 31337) {
    await S.pub.request({ method: "anvil_impersonateAccount", params: [as] });
    if ((await S.pub.getBalance({ address: as })) < 10n ** 17n) {
      await S.pub.request({ method: "anvil_setBalance", params: [as, "0xde0b6b3a7640000"] }); // 1 ETH for gas + fees
    }
    S.account = as;
    S.demoAs = true;
    S.wallet = createWalletClient({ account: as, chain: S.chain, transport: http(S.dep.rpc) });
  } else if (viewOnly) {
    S.account = view;
    S.viewOnly = true;
  } else if (dev != null && S.chainId === 31337) {
    const { privateKeyToAccount } = await import("https://cdn.jsdelivr.net/npm/viem@2.56.8/accounts/+esm");
    const acct = privateKeyToAccount(ANVIL_KEYS[Number(dev) || 0]);
    S.account = acct.address;
    S.wallet = createWalletClient({ account: acct, chain: S.chain, transport: http(S.dep.rpc) });
  } else if (S.account) {
    S.wallet = createWalletClient({ account: S.account, chain: S.chain, transport: custom(window.ethereum) });
  }

  try {
    S.credits = await read("credits");
    [S.art, S.statements] = await Promise.all([tryRead("art", [], S.credits, CREDITS_ABI), tryRead("statements")]);
  } catch {
    return notice(`Can't reach the pool at ${S.pool} on ${S.dep.name}. Is the RPC up?`);
  }
  const blk = await S.pub.getBlock();
  S.clockSkew = Number(blk.timestamp) - Math.floor(Date.now() / 1000);

  $("pool-addr").textContent = `pool ${short(S.pool)}`;
  if (S.chainId === 31337) {
    const who = S.demoAs ? `You're acting as ${short(S.account)}.` : S.viewOnly ? `Viewing ${short(S.account)} read-only.` : "";
    $("demo").textContent = `Local demo on a copy of Ethereum mainnet: test ETH only, nothing here touches real Credits or real money. ${who}`;
    $("demo").hidden = false;
  }
  renderConnect();
  await refresh();
  setInterval(tick, 1000);
  S.lastBlock = await S.pub.getBlockNumber();
  setInterval(poll, S.chainId === 31337 ? 3000 : 12000); // ~ block time
}

function notice(msg) {
  const n = $("notice"); n.textContent = msg; n.hidden = false;
}

function renderConnect() {
  const b = $("connect");
  if (S.viewOnly) { b.textContent = `Viewing ${short(S.account)}`; b.classList.add("ghost"); b.disabled = true; }
  else if (S.demoAs) { b.textContent = `Demo as ${short(S.account)}`; b.classList.add("ghost"); b.disabled = true; }
  else if (S.account) { b.textContent = short(S.account); b.classList.add("ghost"); }
  else if (!window.ethereum) { b.textContent = "No wallet found"; b.disabled = true; }
}

$("connect").onclick = async () => {
  if (S.account || !window.ethereum) return;
  try {
    await window.ethereum.request({ method: "eth_requestAccounts" });
    location.reload();
  } catch (e) { toast(e.message, true); }
};

// ───────────────────────── confirm ─────────────────────────
// For steps that can't be undone. Resolves true only on an explicit "Confirm".
function confirmStep(title, lines, okLabel = "Confirm") {
  const dlg = $("confirm");
  $("confirm-title").textContent = title;
  $("confirm-body").replaceChildren(...lines.map((l) => el("li", {}, l)));
  $("confirm-ok").textContent = okLabel;
  dlg.returnValue = "";
  dlg.showModal();
  return new Promise((ok) => dlg.addEventListener("close", () => ok(dlg.returnValue === "ok"), { once: true }));
}

// ───────────────────────── tx helper ─────────────────────────
async function send(label, functionName, args = [], value, address = S.pool, abi = POOL_ABI) {
  if (!S.wallet) return toast(S.viewOnly ? "View-only: connect this wallet to act" : "Connect a wallet first", true);
  // One transaction at a time: a double-click must not send twice.
  if (S.sending) return toast("Wait for the current transaction to finish", true), false;
  S.sending = true;
  document.body.classList.add("sending");
  try {
    toast(`${label}: confirm in wallet…`, false, 0);
    const { request } = await S.pub.simulateContract({ address, abi, functionName, args, value, account: S.account });
    const hash = await S.wallet.writeContract(request);
    toast(`${label}: pending…`, false, 0);
    const r = await S.pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success") throw new Error("transaction reverted");
    toast(`${label}: done`);
    await refresh();
    return true;
  } catch (e) {
    toast(`${label} failed: ${e.shortMessage || e.message}`, true, 8000);
    return false;
  } finally {
    S.sending = false;
    document.body.classList.remove("sending");
  }
}

// ───────────────────────── render ─────────────────────────
async function refresh() {
  if (S.refreshing) return;
  S.refreshing = true;
  try {
    await Promise.all([renderStats(), renderMine(), renderMyBatches()]);
    await renderAllPage(true);
    hideTip();
  } finally {
    S.refreshing = false;
  }
}

// Live updates: re-render when a new block lands, unless the user is mid-typing.
async function poll() {
  try {
    const bn = await S.pub.getBlockNumber();
    if (S.lastBlock !== null && bn !== S.lastBlock && !document.activeElement?.matches("input")) {
      const blk = await S.pub.getBlock();
      S.clockSkew = Number(blk.timestamp) - Math.floor(Date.now() / 1000);
      await refresh();
    }
    S.lastBlock = bn;
  } catch (e) { console.warn("poll", e); }
}

async function renderStats() {
  const [open, fees, fee, opensAt] = await Promise.all([
    read("openBatchId"), read("accruedFees"), tryRead("depositFee"), read("assemblyOpensAt"),
  ]);
  const [, filled] = await read("batchInfo", [open]);
  S.openBatch = open; S.openFilled = filled;
  const stat = (v, k) => el("div", { class: "stat" }, el("b", {}, v), el("span", {}, k));
  $("stats").replaceChildren(
    stat(`#${open}`, `open batch · ${filled}/80`),
    stat(String(open), "batches filled"),
    stat(fee == null ? "oracle stale" : eth(fee, 5), "fee per Credit ($1)"),
    stat(opensAt <= now() ? "open" : dur(opensAt - now()), "Statement assembly"),
  );
  $("fees").textContent = eth(fees);
  S.fee = fee;
}

async function renderMine() {
  if (!S.account) return;
  $("mine").hidden = false;
  const [ids, approved] = await Promise.all([
    read("tokensOf", [S.account], S.credits, CREDITS_ABI),
    read("isApprovedForAll", [S.account, S.pool], S.credits, CREDITS_ABI),
  ]);
  S.approved = approved;
  for (const id of [...S.selected]) if (!ids.includes(id)) S.selected.delete(id);
  $("mine-count").textContent = `(${ids.length})`;
  $("approve").hidden = approved || !ids.length;

  const grid = $("credits");
  grid.replaceChildren(...ids.map((id) => {
    const tile = el("div", { class: "credit" + (S.selected.has(id) ? " sel" : ""), title: `Credit #${id}` },
      el("span", { class: "id" }, `#${id}`));
    tile.onclick = () => {
      S.selected.has(id) ? S.selected.delete(id) : S.selected.add(id);
      tile.classList.toggle("sel");
      updateDepositHint();
    };
    tile.dataset.id = id;
    return tile;
  }));
  if (!ids.length) grid.append(el("p", { class: "muted", style: "grid-column: 1 / -1" }, "No Credits in this wallet."));
  updateDepositHint();
  loadArt([...grid.querySelectorAll(".credit")]);
}

// Credits render fully on-chain; fetch a few at a time so public RPCs don't throttle.
const artCache = new Map();
async function loadArt(tiles) {
  const queue = [...tiles];
  const worker = async () => {
    for (let t; (t = queue.shift());) {
      const id = BigInt(t.dataset.id);
      if (!artCache.has(id)) {
        const uri = await tryRead("tokenURI", [id], S.credits, CREDITS_ABI);
        let img = null, tier = null, print = null;
        try {
          const json = JSON.parse(atob(uri.split(",")[1]));
          img = json.image;
          const attr = Object.fromEntries((json.attributes ?? []).map((a) => [a.trait_type, a.value]));
          tier = tierOf(attr.Eights);
          print = attr.Print;
        } catch {}
        artCache.set(id, { img, tier, print });
      }
      const { img, tier, print } = artCache.get(id);
      if (img && !t.querySelector("img")) t.prepend(el("img", { src: img, alt: `Credit #${id}` }));
      if (tier) {
        t.dataset.rank = TIERS.indexOf(tier);
        t.title = `Credit #${id} · ${tier}${print && print !== "Registered" ? ` · misprint: ${print}` : ""}`;
        if (tier !== "Common" && !t.querySelector(".badge")) t.append(el("span", { class: "badge" }, tier));
      }
    }
  };
  await Promise.all([worker(), worker(), worker(), worker()]);
  // Rarest first, so it's easy to decide what to keep and what to pool.
  const grid = tiles[0]?.parentElement;
  if (grid && tiles.every((t) => t.isConnected)) {
    grid.append(...[...tiles].sort((a, b) => (b.dataset.rank ?? 0) - (a.dataset.rank ?? 0)));
  }
}

// Jack's tiers come from the count of 8s in the payment id.
const TIERS = ["Common", "Uncommon", "Rare", "Ultra", "Hyper"];
const WORDS = ["none", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];
function tierOf(eightsLabel) {
  if (!eightsLabel) return null;
  const n = WORDS.indexOf(String(eightsLabel).toLowerCase());
  return TIERS[Math.min(n < 0 ? 4 : n, 4)];
}

function updateDepositHint() {
  const n = BigInt(S.selected.size);
  $("deposit").disabled = !n || !S.approved;
  $("deposit").textContent = n ? `Deposit ${n}` : "Deposit";
  $("deposit-wrap").dataset.tip = S.viewOnly ? "depositViewOnly" : !S.approved ? "depositNeedsApproval" : !n ? "depositNeedsPick" : "deposit";
  if (S.viewOnly) return ($("deposit-hint").textContent = "View-only: you can look, not deposit. Connect this wallet to act.");
  if (!S.approved) return ($("deposit-hint").textContent = "Approve the pool once, then pick Credits to deposit.");
  if (!n) return ($("deposit-hint").textContent = "Pick Credits to deposit (rarest shown first). Every Credit counts as one slot, whatever its rarity. You can withdraw until the batch fills.");
  const txs = Math.ceil(Number(n) / MAX_PER_TX);
  if (txs > 1) return ($("deposit-hint").textContent = `${n} Credits → ${txs} transactions of up to ${MAX_PER_TX} (gas limit). $1 per Credit, $${n} total.`);
  const room = PER - S.openFilled;
  $("deposit-hint").textContent = n <= room
    ? `Goes into batch #${S.openBatch} (${S.openFilled + n}/80 after). Fee: $1 per Credit, $${n} total.`
    : `Fills batch #${S.openBatch} with ${room}, the other ${n - room} spill into the next batch${n - room > PER ? "es" : ""}. Fee: $${n} ($1 per Credit).`;
}

$("select-all").onclick = () => {
  const tiles = [...$("credits").querySelectorAll(".credit")];
  const all = tiles.every((t) => t.classList.contains("sel"));
  for (const t of tiles) {
    const id = BigInt(t.dataset.id);
    all ? S.selected.delete(id) : S.selected.add(id);
    t.classList.toggle("sel", !all);
  }
  updateDepositHint();
};
$("approve").onclick = () => send("Approve", "setApprovalForAll", [S.pool, true], undefined, S.credits, CREDITS_ABI);
$("deposit").onclick = async () => {
  const fee = await read("depositFee").catch(() => null);
  if (fee == null) return toast("Price oracle is stale, try again shortly", true);
  const ids = [...S.selected];
  const txs = Math.ceil(ids.length / MAX_PER_TX);
  // Snapshot what the user is about to confirm. The live poll can update S.* while the dialog is
  // open; the first transaction must be pinned to THIS state, not whatever is current later.
  const shownBatch = S.openBatch, shownFilled = S.openFilled;
  const room = PER - shownFilled;
  const ok = await confirmStep(`Deposit ${ids.length} Credit${ids.length > 1 ? "s" : ""}?`, [
    ids.length <= room
      ? `They go into batch #${shownBatch}, taking it to ${shownFilled + BigInt(ids.length)}/80.`
      : `${room} fill batch #${shownBatch}; the rest start the next batch.`,
    `Fee: $1 per Credit, so $${ids.length} total (≈ ${eth(fee * BigInt(ids.length), 5)})${txs > 1 ? `, across ${txs} transactions` : ""}. Not refunded if you withdraw.`,
    "You can withdraw them any time until their batch reaches 80. After that they're locked in.",
  ], "Deposit");
  if (!ok) return;
  // The first tx is pinned to the batch state the user just confirmed; later chunks follow our own deposits.
  let expect = [shownBatch, shownFilled];
  S.selected.clear();
  // Split big deposits under the per-tx gas cap. Each tx pays the $1 fee.
  const chunks = [];
  for (let i = 0; i < ids.length; i += MAX_PER_TX) chunks.push(ids.slice(i, i + MAX_PER_TX));
  for (const [i, chunk] of chunks.entries()) {
    const label = chunks.length > 1 ? `Deposit ${i + 1}/${chunks.length} (${chunk.length})` : `Deposit ${chunk.length}`;
    // Pin the batch we showed the user: if someone deposits first, the tx reverts instead of
    // landing somewhere unexpected. 5% fee buffer against price moves; the pool refunds the excess.
    const due = fee * BigInt(chunk.length); // $1 per Credit
    if (!(await send(label, "depositAt", [chunk, ...expect], due + due / 20n))) break;
    const openNow = await read("openBatchId");
    expect = [openNow, (await read("batchInfo", [openNow]))[1]];
  }
};

// Everything waiting for this wallet: sale shares from settled batches + outbid refunds.
async function renderClaims(myBatchIds) {
  if (!S.account) return;
  const [refund, rows] = await Promise.all([
    read("pendingReturns", [S.account]),
    Promise.all(myBatchIds.map(async (b) => {
      const [info, slots, claimed] = await Promise.all([read("batchInfo", [b]), read("slots", [b, S.account]), read("claimed", [b, S.account])]);
      return STATES[info[0]] === "Settled" && slots && !claimed ? { b, amt: (info[4] * slots) / PER, slots } : null;
    })),
  ]);
  const items = rows.filter(Boolean);
  S.claimItems = items; S.refundAmt = refund;
  const total = items.reduce((t, x) => t + x.amt, refund);
  $("claims").hidden = total === 0n;
  $("claims-total").textContent = `· ${eth(total)}`;
  const list = $("claims-list");
  list.replaceChildren();
  for (const x of items) list.append(el("dt", {}, `Batch #${x.b} sale · your ${x.slots}/80`), el("dd", {}, eth(x.amt)));
  if (refund) list.append(el("dt", {}, "Outbid refund"), el("dd", {}, eth(refund)));
}
$("collect-all").onclick = async () => {
  for (const x of S.claimItems ?? []) if (!(await send(`Claim batch #${x.b}`, "claim", [x.b]))) return;
  if (S.refundAmt) await send("Refund", "withdrawRefund");
};
$("sweep").onclick = () => send("Sweep fees", "sweepFees");

async function renderMyBatches() {
  const box = $("my-batches");
  if (!S.account) return;
  const logs = await S.pub.getLogs({
    address: S.pool,
    event: POOL_ABI.find((x) => x.type === "event" && x.name === "Deposited"),
    args: { who: S.account },
    fromBlock: S.dep.deployBlock,
  }).catch((e) => { console.error(e); return null; });
  if (logs == null) return box.replaceChildren(el("p", { class: "muted" }, "Couldn't load your batches from this RPC. Search by batch # below."));
  const ids = [...new Set(logs.map((l) => l.args.batchId))].sort((a, b) => (a < b ? 1 : -1));
  renderClaims(ids);
  const cards = (await Promise.all(ids.map((b) => batchCard(b, true)))).filter(Boolean);
  box.replaceChildren(...(cards.length ? cards : [el("p", { class: "muted" }, "You haven't deposited yet.")]));
}

// Filter tabs. "voting" covers batches waiting on a price; "sold" covers every finished batch.
const FILTERS = [
  ["all", "All", () => true],
  ["filling", "Filling", (s) => s === "Filling"],
  ["ready", "Ready to assemble", (s) => s === "Full"],
  ["voting", "Voting", (s) => s === "Assembled"],
  ["auction", "Live auctions", (s) => s === "Auction"],
  ["sold", "Sold", (s) => s === "Settled" || s === "Redeemed"],
];
S.filter = "all";

async function renderAllPage(replace = false) {
  if (replace) {
    // One cheap read per batch to know every batch's state (for tab counts and filtering).
    const ids = [];
    for (let b = S.openBatch; b >= 0n; b--) ids.push(b);
    const states = await Promise.all(ids.map((b) => limit(() => read("batchInfo", [b])).then((x) => STATES[x[0]])));
    S.byState = ids.map((b, i) => [b, states[i]]);
    S.shown = 0;
    renderFilters();
  }
  const test = FILTERS.find((f) => f[0] === S.filter)[2];
  const list = S.byState.filter(([, st]) => test(st)).map(([b]) => b);
  const page = list.slice(S.shown, S.shown + Number(PAGE));
  const cards = await Promise.all(page.map((b) => batchCard(b)));
  if (replace) $("all-batches").replaceChildren(...(cards.length ? cards : [el("p", { class: "muted" }, "No batches here yet.")]));
  else $("all-batches").append(...cards);
  S.shown += page.length;
  $("more").hidden = S.shown >= list.length;
}
function renderFilters() {
  $("filters").replaceChildren(...FILTERS.map(([key, label, test]) => {
    const n = S.byState.filter(([, st]) => test(st)).length;
    return el("button", {
      class: "filter" + (S.filter === key ? " on" : ""), role: "tab", "aria-selected": String(S.filter === key),
      disabled: key !== "all" && !n,
      onclick: () => { S.filter = key; renderAllPage(true); },
    }, `${label} `, el("span", { class: "muted" }, String(n)));
  }));
}
$("more").onclick = () => renderAllPage();
$("jump").onsubmit = async (e) => {
  e.preventDefault();
  const v = $("jump-id").value;
  if (v === "") return;
  const b = BigInt(v);
  if (b > S.openBatch) return toast(`Batch #${b} doesn't exist yet`, true);
  const card = await batchCard(b);
  $("all-batches").replaceChildren(card);
  $("more").hidden = true;
};

// ───────────────────────── batch card ─────────────────────────
async function batchCard(b, mineOnly = false) {
  const me = S.account;
  const [info, auction, escape, noReserve, assembledAt, slots, pref, claimed, reserve] = await Promise.all([
    read("batchInfo", [b]),
    read("auctions", [b]),
    read("escapeOpen", [b]),
    read("noReserveOpen", [b]),
    read("assembledAt", [b]),
    me ? read("slots", [b, me]) : 0n,
    me ? read("reservePref", [b, me]) : 0n,
    me ? read("claimed", [b, me]) : false,
    tryRead("auctionReserve", [b]), // what an auction started now would use (30-day fallback aware)
  ]);
  if (mineOnly && slots === 0n) return null;
  const [st, filled, depositors, statementId, proceeds] = info;
  const state = STATES[st];
  const [highBidder, highBid, auctionReserve, endsAt] = auction;

  const kv = el("dl", { class: "kv" });
  let bids = null;
  const row = (k, v) => kv.append(el("dt", {}, k), el("dd", {}, v));
  row("Depositors", String(depositors));
  if (me) row("Your slots", `${slots}/80`);
  if (st >= 2 && st <= 5) row("Statement", `#${statementId}`);
  if (state === "Assembled") {
    // Tally votes client-side (≤ 80 depositors) so everyone can see how close the vote is.
    const addrs = await read("batchDepositors", [b]);
    const [counts, prefs] = await Promise.all([
      Promise.all(addrs.map((a) => read("slots", [b, a]))),
      Promise.all(addrs.map((a) => read("reservePref", [b, a]))),
    ]);
    const voted = counts.reduce((sum, n, i) => (prefs[i] ? sum + n : sum), 0n);
    row("Votes", `${voted}/80 slots${voted * 2n > PER ? " · quorum reached" : ` · needs ${PER / 2n + 1n}`}`);
    row("Reserve", noReserve ? (reserve ? `${eth(reserve)} (lowest vote, unsold 30d)` : "none (unsold 30d, no votes)")
      : reserve == null ? "set once >40 slots vote" : eth(reserve));
    if (!noReserve) row("Reserve drops", el("span", { "data-ends": String(assembledAt + NO_RESERVE_AFTER) }, dur(assembledAt + NO_RESERVE_AFTER - now())));
    if (me && slots) row("Your vote", pref ? eth(pref) : "—");
  }
  if (state === "Auction") {
    row("Reserve", auctionReserve ? eth(auctionReserve) : "none");
    row("High bid", highBid ? `${eth(highBid)} · ${short(highBidder)}` : "no bids");
    row("Ends", el("span", { "data-ends": String(endsAt) }, dur(endsAt - now())));
    bids = await bidHistory(b);
  }
  if (state === "Settled") {
    bids = await bidHistory(b);
    row("Sold for", eth(highBid));
    row("After 1% fee", eth(proceeds));
    if (me && slots) row("Your share", `${eth((proceeds * slots) / PER)}${claimed ? " · claimed" : ""}`);
  }

  const actions = el("div", { class: "actions" });
  const btn = (label, fn, cls = "", tip) => el("button", { class: cls, onclick: fn, "data-tip": tip }, label);
  const input = (ph, val = "") => el("input", { type: "number", step: "any", min: "0", placeholder: ph, value: val });

  if (me && slots) {
    const canWithdraw = state === "Filling" || state === "Dissolved" || (state === "Full" && escape);
    if (canWithdraw) {
      actions.append(btn(`Withdraw my ${slots}`, async () => {
        // A dissolved batch keeps its old id list; a Credit withdrawn from it and re-deposited
        // elsewhere must not be pulled from its new batch, so check both depositor AND batch.
        const all = await read("batchCredits", [b]);
        const [owners, homes] = await Promise.all([
          Promise.all(all.map((id) => read("depositorOf", [id]))),
          Promise.all(all.map((id) => read("batchOf", [id]))),
        ]);
        const mine = all.filter((_, i) => owners[i].toLowerCase() === me.toLowerCase() && homes[i] === b);
        send(`Withdraw ${mine.length}`, "withdraw", [mine]);
      }, "ghost", "withdraw"));
    }
  }
  if (state === "Full") actions.append(btn("Assemble Statement", async () => {
    if (await confirmStep(`Assemble batch #${b}?`, [
      "Burns these 80 Credits for good and mints one Statement, held by the pool for the depositors.",
      "This can't be undone. Credits in this batch can no longer be withdrawn.",
      "Anyone can press this; you pay the gas.",
    ], "Burn & assemble")) send(`Assemble #${b}`, "assemble", [b]);
  }, "", "assemble"));
  if (state === "Assembled") {
    if (slots === PER) actions.append(btn("Redeem Statement", () => send(`Redeem #${b}`, "redeem", [b]), "", "redeem"));
    if (me && slots) {
      const i = input("Min price (ETH)", pref ? formatEther(pref) : "");
      actions.append(el("div", { class: "row" }, i, btn("Vote reserve", () => {
        const v = toWei(i.value);
        if (v == null) return toast("Enter a price in ETH, or 0 to clear your vote", true);
        send("Vote", "setReserve", [b, v]);
      }, "ghost", "vote")));
    }
    if (!(me && slots)) actions.append(el("span", { class: "muted small" },
      "Only this batch's depositors vote on the minimum price. Anyone can start the auction once more than 40 slots have voted, and anyone can bid."));
    // Both buttons use startAuctionAt: the CONTRACT refuses if the minimum changed after the
    // user confirmed it (votes moved, or the 30-day fallback kicked in).
    const start = (lines) => async () => {
      if (!(await confirmStep(`Start the auction for Statement #${statementId}?`, lines, "Start auction"))) return;
      const ok = await send(`Start auction #${b}`, "startAuctionAt", [b, reserve]);
      if (!ok) refresh();
    };
    if (noReserve && reserve != null) actions.append(btn(reserve ? `Start auction @ ${eth(reserve)}` : "Start no-reserve auction", start([
      reserve
        ? `It went 30 days without selling, so the minimum is now the lowest price any depositor voted: ${eth(reserve)}.`
        : "It went 30 days without selling and nobody voted, so there's no minimum: the highest bid wins.",
      "Runs 24 hours and can't be cancelled.",
    ]), "", "startNoReserve"));
    else if (reserve != null) actions.append(btn(`Start auction @ ${eth(reserve)}`, start([
      `Minimum bid: ${eth(reserve)}, the depositors' voted price.`,
      "Runs 24 hours. Once started, it can't be cancelled or repriced.",
      "If the price changes before your transaction lands, it's refused and nothing happens.",
      "If nobody bids, it goes back to voting.",
    ]), "", "start"));
  }
  if (state === "Auction") {
    if (now() < endsAt) {
      let min = highBidder === "0x0000000000000000000000000000000000000000" ? auctionReserve : highBid + (highBid * 500n) / 10000n;
      if (min === 0n) min = 1n;
      const i = input("Bid (ETH)", formatEther(min));
      actions.append(el("div", { class: "row" }, i, btn("Bid", () => {
        const v = toWei(i.value);
        if (v == null) return toast("Enter a bid in ETH", true);
        if (v < min) return toast(`Minimum bid is ${formatEther(min)} ETH`, true);
        confirmStep(`Bid ${eth(v, 6)} on Statement #${statementId}?`, [
          "Your ETH is held by the pool until the auction ends. You can't cancel a bid.",
          "If someone outbids you, it's returned: collect it under \"Ready to collect\".",
          "If you win, the Statement goes to your wallet when the auction is settled.",
        ], "Place bid").then((ok) => ok && send(`Bid on #${b}`, "bid", [b], v));
      }, "", "bid")));
      actions.append(el("span", { class: "muted small" }, `min ${eth(min, 6)} · bids in the last 15m extend it`));
      if (me && slots) actions.append(el("span", { class: "muted small" },
        `Price too low? Outbid. If you win, ${slots}/80 of what you pay (after the 1% fee) comes back to you.`));
    } else {
      actions.append(btn("Settle auction", () => send(`Settle #${b}`, "settle", [b]), "", "settle"));
    }
  }
  if (state === "Settled" && me && slots && !claimed) {
    actions.append(btn(`Claim ${eth((proceeds * slots) / PER)}`, () => send(`Claim #${b}`, "claim", [b]), "", "claim"));
  }

  // Who's in the batch: loaded on first open so long lists don't cost RPC calls up front.
  let who = null;
  if (depositors > 0n) {
    who = el("details", { class: "who" }, el("summary", {}, `Who's in this batch (${depositors})`));
    who.addEventListener("toggle", async () => {
      who.open ? S.openWho.add(b) : S.openWho.delete(b);
      if (!who.open || who.dataset.loaded) return;
      who.dataset.loaded = "1";
      const addrs = await read("batchDepositors", [b]);
      const counts = await Promise.all(addrs.map((a) => read("slots", [b, a])));
      const rows = addrs.map((a, i) => [a, counts[i]]).sort((x, y) => (y[1] > x[1] ? 1 : y[1] < x[1] ? -1 : 0));
      const list = el("dl", { class: "kv" });
      for (const [a, n] of rows) {
        const isMe = me && a.toLowerCase() === me.toLowerCase();
        list.append(
          el("dt", {}, isMe ? `${short(a)} (you)` : short(a)),
          el("dd", {}, `${n} · ${((Number(n) / 80) * 100).toFixed(1)}%`),
        );
      }
      who.append(list);
    });
    if (S.openWho.has(b)) who.open = true; // stay open across live refreshes
  }

  // What's being sold: the batch's 80 Credits (they still render after the burn).
  const showArt = S.art && (["Full", "Assembled", "Auction", "Settled", "Redeemed"].includes(state) || (state === "Filling" && filled > 0n));
  const mosaic = showArt ? mosaicButton(b, statementId, state) : null;

  const tagText = state === "Full" && escape ? "Full · escape open" : state;
  return el("div", { class: "batch" },
    el("div", { class: "batch-top" }, el("b", {}, `Batch #${b}`), el("span", { class: `tag ${state}` }, tagText)),
    el("div", { class: "bar", title: `${filled}/80` }, el("i", { style: `width:${(Number(filled) / 80) * 100}%` })),
    el("span", { class: "muted small" }, `${filled}/80 Credits`),
    mosaic,
    kv,
    bids?.length ? bidList(bids, highBidder, me) : null,
    who,
    actions.childElementCount ? actions : null,
  );
}

// ───────────────────────── Statement viewer ─────────────────────────
// A few RPC calls at a time, so 80-Credit mosaics don't flood public nodes.
const limit = (() => {
  let active = 0; const q = [];
  const next = () => { if (active >= 6 || !q.length) return; active++; const [fn, ok, no] = q.shift(); fn().then(ok, no).finally(() => { active--; next(); }); };
  return (fn) => new Promise((ok, no) => { q.push([fn, ok, no]); next(); });
})();
const memo = (fn) => { const m = new Map(); return (k) => (m.has(k) ? m.get(k) : (m.set(k, fn(k)), m.get(k))); };

const creditSeed = memo((id) => limit(() => Promise.all([
  read("seedOf", [id], S.credits, CREDITS_ABI), read("timestampOf", [id], S.credits, CREDITS_ABI),
])));
const creditImg = memo(async (id) => {
  const [seed, ts] = await creditSeed(id);
  const svg = await limit(() => read("svg", [seed, ts], S.art, ART_ABI));
  return "data:image/svg+xml;utf8," + encodeURIComponent(svg);
});
const creditTraits = memo(async (id) => {
  const [seed, ts] = await creditSeed(id);
  return limit(() => read("describe", [seed, ts], S.art, ART_ABI));
});
const fixedIds = memo((b) => read("batchCredits", [b])); // fixed once a batch is full
const batchIds = (b, state) => (state === "Filling" ? read("batchCredits", [b]) : fixedIds(b));

// Bid history for one batch (newest first).
async function bidHistory(b) {
  try {
    const logs = await S.pub.getLogs({
      address: S.pool, event: POOL_ABI.find((x) => x.type === "event" && x.name === "Bid"),
      args: { batchId: b }, fromBlock: S.dep.deployBlock,
    });
    return logs.map((l) => ({ who: l.args.bidder, amt: l.args.amount })).reverse();
  } catch (e) { console.warn("bid history", e); return null; }
}
function bidList(bids, top, me) {
  const box = el("details", { class: "who bids" }, el("summary", {}, `Bid history (${bids.length})`));
  const list = el("dl", { class: "kv" });
  for (const x of bids) {
    const mine = me && x.who.toLowerCase() === me.toLowerCase();
    const lead = x.who.toLowerCase() === top.toLowerCase() && x === bids[0];
    list.append(el("dt", {}, `${short(x.who)}${mine ? " (you)" : ""}${lead ? " · leading" : ""}`), el("dd", {}, eth(x.amt)));
  }
  box.append(list);
  return box;
}
const statementImg = memo(async (sid) => {
  try {
    const uri = await read("tokenURI", [sid], S.statements, STATEMENTS_ABI);
    const json = uri.startsWith("data:") ? JSON.parse(atob(uri.split(",")[1])) : null;
    return json?.image ?? null;
  } catch { return null; }
});

function fillImgs(imgs, ids) {
  imgs.forEach((img, i) => creditImg(ids[i]).then((src) => (img.src = src)).catch((e) => console.warn(`Credit #${ids[i]} art`, e)));
}

function mosaicButton(b, sid, state) {
  const grid = el("span", { class: "mosaic-grid" });
  const box = el("button", {
    class: "mosaic", "data-tip": state === "Filling" || state === "Full" ? "viewBatch" : "viewStatement", "aria-label": `View the 80 Credits in batch #${b}`,
    onclick: () => openViewer(b, sid, state),
  }, grid, el("span", { class: "mosaic-cap" },
    state === "Filling" ? "Credits in this batch so far · click to view"
    : state === "Full" ? "The 80 Credits in this batch · click to view"
    : `Statement #${sid} · made from these 80 Credits · click to view`));
  // Load only when the card scrolls into view.
  const io = new IntersectionObserver(async ([e]) => {
    if (!e.isIntersecting) return;
    io.disconnect();
    const ids = await batchIds(b, state);
    const imgs = ids.map((id) => el("img", { alt: "", loading: "lazy" }));
    const empty = Array.from({ length: 80 - ids.length }, () => el("i", { class: "slot" }));
    grid.replaceChildren(...imgs, ...empty);
    fillImgs(imgs, ids);
  });
  io.observe(box);
  return box;
}

async function openViewer(b, sid, state) {
  const dlg = $("viewer");
  const body = $("viewer-body");
  const assembled = state !== "Full" && state !== "Filling";
  $("viewer-title").textContent = assembled ? `Statement #${sid} · Batch #${b}`
    : state === "Full" ? `Batch #${b} · ready to assemble` : `Batch #${b} · filling`;
  body.replaceChildren(el("p", { class: "muted" }, "Loading the 80 Credits…"));
  dlg.showModal();

  const ids = await batchIds(b, state);
  const official = assembled ? await statementImg(sid) : null;
  const tiles = ids.map((id) => el("figure", { class: "tile" }, el("img", { alt: `Credit #${id}` }), el("figcaption", {}, `#${id}`)));
  fillImgs(tiles.map((t) => t.querySelector("img")), ids);

  const summary = el("div", { class: "summary" }, el("p", { class: "muted small" }, "Reading traits…"));
  body.replaceChildren(
    official
      ? el("div", { class: "official" }, el("img", { src: official, alt: `Statement #${sid}` }))
      : el("p", { class: "muted small" }, assembled
        ? "The Statement's own artwork shows here once the Statements contract publishes it. Below are the 80 Credits burned to make it."
        : state === "Full" ? "These 80 Credits will be burned into one Statement when someone presses Assemble."
        : `${ids.length} of 80 Credits so far. The batch locks and can be assembled once it reaches 80.`),
    summary,
    el("div", { class: "tiles" }, tiles),
  );

  const traits = await Promise.all(ids.map((id) => creditTraits(id).catch(() => null)));
  tiles.forEach((t, i) => {
    const d = traits[i]; if (!d) return;
    t.title = `Credit #${ids[i]} · ${d.tier} · ${d.colors} · ${d.weight} · ${d.register}`;
    if (d.tier !== "Common") t.dataset.tier = d.tier;
  });
  const count = (key) => traits.reduce((m, d) => (d ? ((m[d[key]] = (m[d[key]] || 0) + 1), m) : m), {});
  const line = (label, obj, order) => el("div", { class: "sum-row" }, el("span", { class: "muted" }, label),
    el("span", {}, (order ?? Object.keys(obj)).filter((k) => obj[k]).map((k) => `${k} ${obj[k]}`).join(" · ")));
  const tiers = count("tier"), prints = count("register"), plates = count("plates");
  summary.replaceChildren(
    line("Rarity (8s in ID)", tiers, ["Hyper", "Ultra", "Rare", "Uncommon", "Common"]),
    line("Print", prints, ["Registered", "Nudge", "Slip", "Skew", "Drift", "Loose"]),
    line("Plates", Object.fromEntries(Object.entries(plates).map(([k, v]) => [`${k}-plate`, v]))),
  );
}

function tick() {
  for (const n of document.querySelectorAll("[data-ends]")) n.textContent = dur(BigInt(n.dataset.ends) - now());
}

init().catch((e) => { console.error(e); notice(e.message); });
