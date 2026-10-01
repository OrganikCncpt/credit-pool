import {
  createPublicClient, createWalletClient, custom, http, parseAbi, formatEther, parseEther, defineChain,
} from "./vendor/viem.js"; // viem 2.56.8, bundled locally: no third-party code at runtime
import { DEPLOYMENTS, DEFAULT_CHAIN } from "./config.js";
import { BACKED_ABI, BACKED_STATES, BACKED_FILTERS, BACKED_TIPS, TREASURY_ABI, backedCard, applyBackedCopy, renderInbox, refreshDrawer, renderTreasury } from "./backing.js";

// ───────────────────────── ABIs ─────────────────────────
const POOL_ABI = parseAbi([
  "function assemblyOpensAt() view returns (uint256)",
  "function statements() view returns (address)",
  "function vault() view returns (address)",
  "function credits() view returns (address)",
  "function openBatchId() view returns (uint256)",
  "function accruedFees() view returns (uint256)",
  "function usdWei() view returns (uint256)",
  "function depositFeeFor(uint256) view returns (uint256)",
  "function store() view returns (address)",
  "function unsoldAuctions(uint256) view returns (uint256)",
  "function feeUsesFallback() view returns (bool)",
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
// The store: SCREDIT points (non-transferable), the treasury, and the SCREDIT-only store auction.
const STORE_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function treasuryBalance() view returns (uint256)",
  "function bidFees() view returns (uint256)",
  "function bidFee() view returns (uint256)",
  "function listings(uint256) view returns (address highBidder, uint256 highBid, uint256 reserve, uint64 endsAt)",
  "function minBid(uint256) view returns (uint256)",
  "function bid(uint256 statementId, uint256 points) payable",
  "function settle(uint256 statementId)",
  "function sweepBidFees()",
  "event Listed(uint256 indexed statementId, uint256 reserve, uint64 endsAt)",
  "error NotListed()", "error AuctionLive()", "error AuctionOver()", "error BidTooLow()",
  "error InsufficientFee()", "error InsufficientPoints()", "error NonTransferable()",
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
const STATEMENTS_ABI = parseAbi([
  "function tokenURI(uint256) view returns (string)",
  "function ownerOf(uint256) view returns (address)",
]);

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
  deposit: "Step 2 of 2: moves the selected Credits into the open batch. Fee: {rule}, paid in ETH. Each Credit earns 2 SCREDIT once its batch is burned into a Statement. " +
    "You can withdraw any time until the batch reaches 80.",
  depositNeedsApproval: "Approve the pool first (one time), then pick Credits.",
  depositNeedsPick: "Click the Credits you want to deposit first.",
  depositViewOnly: "View-only: connect this wallet to deposit.",
  withdraw: "Take your Credits back to your wallet. Possible while the batch is still filling, " +
    "or if a full batch can't be assembled for 14 days. The deposit fee isn't refunded.",
  assemble: "Burns this batch's 80 Credits into one Statement, held by the pool for its depositors. " +
    "Anyone can press this. It's permanent.",
  redeem: "You hold all 80 slots, so the Statement is yours: sends it straight to your wallet. No auction, no fee.",
  vote: "Takes effect immediately: once voters holding more than 40 slots accept a price, anyone can start the auction at it, so decide before you vote rather than planning to raise it later. " +
    "The lowest price you'd accept for this Statement. The auction minimum is the lowest price that " +
    "more than 40 of the 80 slots accept, so a small group can't drag it below what most depositors agreed to. Enter 0 to clear your vote.",
  start: "Starts a 24-hour auction at the voted minimum. Opens once voters holding more than 40 of the 80 slots have voted. Anyone can press it.",
  startNoReserve: "This Statement has gone 30 days without selling, so quorum is no longer needed: anyone can start an auction whose minimum is the LOWEST price any depositor voted (none if nobody voted).",
  bid: "Your ETH is held by the pool. If you're outbid, you get it back (Withdraw refund at the top). " +
    "Each bid must beat the last by 5%. Bids in the final 15 minutes add 15 minutes.",
  settle: "Ends the auction: the Statement goes to the winner and depositors can claim. Anyone can press this.",
  claim: "Sends your share of the sale to your wallet: your slots ÷ 80 of the price. Sales carry no fee.",
  refund: "ETH from bids where someone outbid you. Sends it back to your wallet.",
  collect: "Sends everything waiting for you to your wallet: your share of each sold Statement, plus any outbid refunds. One transaction per item.",
  viewStatement: "See what's being sold: the 80 Credits burned into this Statement, with their rarity breakdown.",
  viewBatch: "See the Credits in this batch so far, with their rarity breakdown.",
  sweep: "Splits collected deposit fees: 25% to the platform, 75% to the store treasury (which only buys Statements that failed to sell). Anyone can trigger it; it can only go there.",
  storeBid: "Bid SCREDIT points, plus a {bidfee} platform fee in ETH per bid. Your points are held while you lead; if you're outbid they come straight back. If you win, they're spent.",
  storeSettle: "Ends this store auction: the Statement goes to the winner and their points are spent. Anyone can press this.",
  points: "Store Credit: 2 points for every Credit you have in a batch when it's burned into a Statement (withdrawn Credits and dissolved batches earn none). They can't be sent, sold or traded; you can only bid them on Statements in the store.",
};

const tipEl = () => document.getElementById("tip");
function showTip(target) {
  const text = (TIPS[target.dataset.tip] ?? target.dataset.tip)?.replaceAll("{fee}", feeUsd()).replaceAll("{rule}", feeRule()).replaceAll("{bidfee}", feeUsd(0.25));
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
  abi: POOL_ABI, states: STATES, backed: false,
  openWho: new Set(), lastBlock: null, refreshing: false, cards: new Map(), mineSig: null, tiles: new Map(), owners: new Map(), sidBatch: new Map(),
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
const eth = (wei, dp) => {
  dp ??= wei < 10n ** 17n ? 6 : 4; // payouts and test amounts under 0.1 ETH get more digits
  if (wei > 0n && wei < 10n ** BigInt(18 - dp) / 2n) return `<0.${"0".repeat(dp - 1)}1 ETH`;
  const unit = 10n ** BigInt(18 - dp);
  wei = ((wei + unit / 2n) / unit) * unit; // round to dp, don't cut off
  const [i, f = ""] = formatEther(wei).split(".");
  const t = f.slice(0, dp).replace(/0+$/, "");
  return `${i}${t ? "." + t : ""} ETH`;
};
// Fees can be tiny (a testnet cent is ~0.0000037 ETH): keep two significant digits.
const ethFee = (wei) => eth(wei, Math.min(18, Math.max(5, 20 - wei.toString().length)));
// Number inputs → wei, or null for anything that isn't a plain non-negative amount.
const toWei = (v) => {
  v = String(v).trim();
  if (!/^(\d+\.?\d{0,18}|\.\d{1,18})$/.test(v)) return null; // ETH has 18 decimals; more would round silently
  try { return parseEther(v); } catch { return null; }
};
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
// The deposit fee in USD: $1 on mainnet; a testnet can set feeUsd in config.js (its feed is scaled to match).
const FEE_USD = () => S.dep?.feeUsd ?? 1;
const dollars = (d) => `$${Number.isInteger(d) ? d.toLocaleString("en-US") : d < 0.01 ? String(+d.toPrecision(2)) : d.toFixed(2)}`;
const feeUsd = (n = 1) => dollars(FEE_USD() * Number(n)); // n may be a BigInt count
// Deposit fee: $2 per Credit, or $1 each for a deposit of 6+ in one transaction (CreditPool.depositFeeFor).
const BULK_MIN = 6;
const perCredit = (n) => (Number(n) >= BULK_MIN ? 1 : 2);
const feeRule = () => `${feeUsd(2)} per Credit, or ${feeUsd(1)} each when you deposit ${BULK_MIN}+ at once`;
// Big deposits are split into near-equal transactions under the gas cap, so none falls below the bulk rate.
const chunkSizes = (n) => {
  const k = Math.ceil(n / MAX_PER_TX), base = Math.floor(n / k);
  return Array.from({ length: k }, (_, i) => base + (i < n % k ? 1 : 0));
};
const depositUsd = (n) => chunkSizes(Number(n)).reduce((t, c) => t + c * perCredit(c), 0); // in pool dollars
// ≈ USD for an ETH amount. usdWei() is exactly FEE_USD in wei (Chainlink ETH/USD), so $ = wei ÷ fee × FEE_USD.
const usd = (wei) => {
  if (!S.fee || S.feeFallback || wei == null) return ""; // the fallback fee isn't exact
  const d = (Number(wei) / Number(S.fee)) * FEE_USD(); // S.fee = usdWei(): exactly $1 of pool pricing
  return ` (≈ $${d >= 100 ? Math.round(d).toLocaleString("en-US") : d.toFixed(2)})`;
};
const ethUsd = (wei, dp) => eth(wei, dp) + usd(wei);
const now = () => BigInt(Math.floor(Date.now() / 1000) + S.clockSkew);
const dur = (s) => {
  s = Number(s); if (s <= 0) return "ended";
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m ${x}s`;
};
const readFresh = (functionName, args = [], address = S.pool, abi = S.abi) =>
  S.pub.readContract({ address, abi, functionName, args });
// Rendering reads go through a cache that is cleared at the start of every refresh, so the
// batch cards, "Your batches" and the gallery never fetch the same value twice. Action
// handlers use readFresh so they never act on a value from a previous render.
const readCache = new Map();
const read = (functionName, args = [], address = S.pool, abi = S.abi) => {
  const key = `${address}:${functionName}:${args.map(String).join(",")}`;
  if (!readCache.has(key)) {
    const p = readFresh(functionName, args, address, abi);
    readCache.set(key, p);
    p.catch(() => readCache.delete(key)); // don't cache failures
  }
  return readCache.get(key);
};
const tryRead = (...a) => read(...a).catch(() => null);

function toast(msg, err = false, ms = 4000) {
  const t = $("toast");
  t.textContent = msg; t.className = "toast" + (err ? " err" : ""); t.hidden = false;
  clearTimeout(toast.t);
  if (ms) toast.t = setTimeout(() => (t.hidden = true), ms);
}

// ───────────────────────── setup ─────────────────────────
// Canonical Multicall3, same address on mainnet and every major chain (and on a mainnet fork).
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";
function chainFor(id, dep, withMulticall) {
  return defineChain({
    id, name: dep.name, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [dep.rpc] } },
    ...(withMulticall ? { contracts: { multicall3: { address: MULTICALL3 } } } : {}),
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
  if (!S.dep) return switchNotice(`Unsupported network (chain ${S.chainId}).`);
  S.chain = chainFor(S.chainId, S.dep);
  // Many small reads → a few requests: JSON-RPC batching always, plus Multicall3 if it exists here.
  const transport = http(S.dep.rpc, { batch: { batchSize: 100, wait: 10 } });
  const probe = createPublicClient({ chain: S.chain, transport });
  const hasMulticall = !!(await probe.getCode({ address: MULTICALL3 }).catch(() => null));
  S.chain = chainFor(S.chainId, S.dep, hasMulticall);
  S.pub = createPublicClient({ chain: S.chain, transport, batch: hasMulticall ? { multicall: { wait: 10 } } : undefined });
  $("chain").textContent = S.dep.name;
  for (const f of document.querySelectorAll(".fee-usd")) f.textContent = feeUsd(Number(f.dataset.mult ?? 1));
  if (!S.dep.pool) return switchNotice(`credit.pool isn't deployed on ${S.dep.name} yet. It goes live once the Statements contract is published.`);
  S.pool = S.dep.pool;
  // Backed auctions are a pluggable feature: a BackedPool answers bestBacking(), a CreditPool doesn't.
  S.backed = await readFresh("bestBacking", [0n], S.pool, BACKED_ABI).then(() => true, () => false);
  if (S.backed) {
    S.abi = BACKED_ABI; S.states = BACKED_STATES; S.filters = BACKED_FILTERS;
    Object.assign(TIPS, BACKED_TIPS);
    applyBackedCopy(el);
    document.body.classList.add("backed");
  }
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
    const { privateKeyToAccount } = await import("./vendor/viem-accounts.js");
    const acct = privateKeyToAccount(ANVIL_KEYS[Number(dev) || 0]);
    S.account = acct.address;
    S.wallet = createWalletClient({ account: acct, chain: S.chain, transport: http(S.dep.rpc) });
  } else if (S.account) {
    S.wallet = createWalletClient({ account: S.account, chain: S.chain, transport: custom(window.ethereum) });
  }

  try {
    S.credits = await read("credits");
    [S.art, S.statements, S.store] = await Promise.all([tryRead("art", [], S.credits, CREDITS_ABI), tryRead("statements"), tryRead("store")]);
  } catch {
    return notice(`Can't reach the pool at ${S.pool} on ${S.dep.name}. Is the RPC up?`);
  }
  // A wrong or tampered pool address must not get approval over your Credits: pin the real ones.
  if (S.dep.credits && S.credits.toLowerCase() !== S.dep.credits.toLowerCase()) {
    return notice(`The pool at ${S.pool} doesn't use the real Credits contract. Not loading it.`);
  }
  if (S.backed && S.store && S.account && !S.viewOnly) {
    const owner = await tryRead("owner", [], S.store, TREASURY_ABI);
    S.treasuryOwner = !!owner && owner.toLowerCase() === S.account.toLowerCase();
  }
  const blk = await S.pub.getBlock();
  S.clockSkew = Number(blk.timestamp) - Math.floor(Date.now() / 1000);

  $("pool-addr").textContent = `pool ${short(S.pool)}`;
  // Safety section: every contract the site talks to, linked to the explorer when there is one.
  const addr = (label, a) => a && el("span", {}, `${label} `, S.dep.explorer
    ? el("a", { href: `${S.dep.explorer}/address/${a}`, target: "_blank", rel: "noopener" }, short(a)) : short(a));
  $("addr-list").replaceChildren(...[
    addr("pool", S.pool), " · ", addr("assembly vault", await tryRead("vault")), " · ", addr("store", S.store), " · ",
    addr("Credits", S.credits), " · ", addr("Statements", S.statements),
  ].filter(Boolean));
  if (S.account && !S.viewOnly) $("revoke-link").href = `https://revoke.cash/address/${S.account}`;
  if (S.chainId === 31337) {
    const who = S.demoAs ? `You're acting as ${short(S.account)}.` : S.viewOnly ? `Viewing ${short(S.account)} read-only.` : "";
    $("demo").textContent = `Local demo ${S.dep.forkOf ? `on a copy of ${S.dep.forkOf}` : "on a local test chain"}: test ETH only, nothing here touches real Credits or real money. ${who}`;
    $("demo").hidden = false;
  } else if (S.dep.testnet) {
    $("demo").textContent = `Testnet (${S.dep.name}): test ETH and test copies of Credits only. Nothing here is real money or real Credits.`;
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

// Wallet on a chain without a live pool: one click to the chain that has one (adds it if missing).
function switchNotice(msg) {
  const target = Object.entries(DEPLOYMENTS).find(([id, d]) => d.pool && +id !== 31337 && +id !== S.chainId);
  notice(target ? `${msg} credit.pool is live on ${target[1].name}.` : msg);
  renderConnect();
  if (!target || !window.ethereum || !S.account) return;
  const [id, d] = target;
  const chainId = "0x" + Number(id).toString(16);
  const b = el("button", {}, `Switch to ${d.name}`);
  b.onclick = async () => {
    try {
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] });
    } catch (e) {
      if (e.code !== 4902) return toast(e.message, true);
      await window.ethereum.request({ method: "wallet_addEthereumChain", params: [{
        chainId, chainName: d.name, rpcUrls: [d.rpc], nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
        blockExplorerUrls: d.explorer ? [d.explorer] : undefined,
      }] }).catch((e2) => toast(e2.message, true));
    }
  }; // the wallet's chainChanged event reloads the page
  $("notice").append(" ", b);
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

// Contract errors → what a person should know and do. Anything unknown falls back to viem's summary.
const ERROR_TEXT = {
  WrongBatchState: "That batch has already moved to a different step. The page is refreshing.",
  NotDepositor: "Only this batch's depositors can do that.",
  InsufficientFee: "The fee (priced in ETH) went up a moment ago. Please try again.",
  StaleOracle: "The ETH price feed hasn't updated recently, so fees can't be priced. Try again shortly.",
  ReserveQuorumNotMet: "Not enough depositors have voted yet: more than 40 of 80 slots must vote.",
  BidTooLow: "Someone else bid first, or your bid is below the minimum. Check the new minimum and bid again.",
  AuctionLive: "The auction is still running (offers are binding until it's settled).",
  NothingToClaim: "There's nothing to collect for this wallet.",
  TransferFailed: "Your wallet couldn't receive the ETH.",
  BatchMoved: "Someone deposited just before you, so the batch changed. Review the new numbers and try again.",
  ReserveChanged: "The minimum price changed since you looked. Review it and try again.",
  StatementNotReceived: "The Statement wasn't minted as expected, so nothing was burned.",
  CreditsNotBurned: "The Credits weren't burned as expected, so nothing changed.",
  ZeroAddress: "That address isn't allowed.",
  InsufficientPoints: "You don't have enough SCREDIT for that bid.",
  AuctionOver: "That store auction has ended.",
  NotListed: "That Statement isn't up for auction in the store.",
  NonTransferable: "SCREDIT can't be transferred.",
  OverCap: "That's over the treasury's per-purchase cap or its balance.",
  PriceMoved: "The depositors' price changed since you looked. Review it and try again.",
  NotBacked: "This batch needs a backer before its auction can start.",
  BackingTooLow: "That backing is too low: at least 80 wei, and above the lowest of the 10 backers when the list is full.",
  BackingChanged: "The backing or the minimum changed since you looked. Review the new numbers and try again.",
  NoMinimum: "The depositors haven't set a price yet: more than 40 of the 80 slots must vote before an auction can start.",
  Cooldown: "This batch is resting after an unsold round: no new auction until the rest ends.",
  BidInstead: "During the auction an offer must be below the depositors' price. At or above it, place a bid instead.",
  OfferChanged: "The backer's offer changed since you looked, so your acceptance wasn't counted. Review it and try again.",
  NotUnsold: "That batch's last round didn't end unsold (or its Credits changed since).",
  PivotalMinority: "The price isn't the median of the votes cast, so the store won't buy at it.",
  NotYet: "Auctions haven't opened yet.",
  NeedMoreGas: "This sale needs more gas to run safely. Try again; your wallet should allow up to 14M gas.",
  TooMany: "Those Credits don't fit in that batch.",
};
function friendlyError(e) {
  if (e?.name === "UserRejectedRequestError" || e?.code === 4001 || /rejected|denied/i.test(e?.shortMessage ?? "")) {
    return "You cancelled it in your wallet. Nothing was sent.";
  }
  let name = null;
  e?.walk?.((x) => { if (x?.data?.errorName) { name = x.data.errorName; return true; } return false; });
  if (name && ERROR_TEXT[name]) { if (name === "WrongBatchState") refresh(); return ERROR_TEXT[name]; }
  if (/insufficient funds/i.test(e?.message ?? "")) return "Your wallet doesn't have enough ETH for this plus gas.";
  return e?.shortMessage || e?.message || "Unknown error.";
}

// ───────────────────────── tx helper ─────────────────────────
async function send(label, functionName, args = [], value, address = S.pool, abi = S.abi, gas) {
  if (!S.wallet) return toast(S.viewOnly ? "View-only: connect this wallet to act" : "Connect a wallet first", true);
  // One transaction at a time: a double-click must not send twice.
  if (S.sending) return toast("Wait for the current transaction to finish", true), false;
  S.sending = true;
  document.body.classList.add("sending");
  try {
    toast(`${label}: confirm in wallet…`, false, 0);
    const { request } = await S.pub.simulateContract({ address, abi, functionName, args, value, account: S.account, gas });
    // Headroom over the node's estimate: the estimate runs at the latest block's timestamp, and a
    // time-dependent branch (e.g. a late bid's anti-snipe extension) can need more gas by the time
    // it's mined. Only gas actually used is paid.
    if (!gas) {
      const est = await S.pub.estimateContractGas({ address, abi, functionName, args, value, account: S.account });
      request.gas = (est * 12n) / 10n + 30_000n;
    }
    const hash = await S.wallet.writeContract(request);
    toast(`${label}: pending…`, false, 0);
    const r = await S.pub.waitForTransactionReceipt({ hash });
    if (r.status !== "success") throw new Error("transaction reverted");
    toast(`${label}: done`);
    // The transaction is final: free the lock before redrawing, or a click on the next step
    // (Approve → Deposit) during the redraw is refused although nothing is pending.
    S.sending = false;
    document.body.classList.remove("sending");
    await refresh();
    return true;
  } catch (e) {
    toast(`${label} didn't go through. ${friendlyError(e)}`, true, 9000);
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
  readCache.clear();
  try {
    await Promise.all([renderStats(), renderMine(), renderMyBatches()]);
    await renderAllPage(true);
    await renderGallery();
    await renderStore();
    if (S.backed) await Promise.all([renderTreasury(backingCtx), refreshDrawer(backingCtx)]);
    hideTip();
    S.lastRefresh = Date.now();
  } finally {
    S.refreshing = false;
  }
}

// Live updates. Redraw when the POOL emits an event (a deposit, vote, bid...), not on every
// block: mainnet makes a block every 12s, and redrawing on each one made the page flash.
// A slow periodic refresh catches time-based changes (an auction ending, the 30-day fallback).
const SAFETY_REFRESH_MS = 60_000;
async function poll() {
  try {
    const bn = await S.pub.getBlockNumber();
    if (S.lastBlock === null || bn === S.lastBlock) return;
    const logs = await S.pub.getLogs({ address: [S.pool, S.store].filter(Boolean), fromBlock: S.lastBlock + 1n, toBlock: bn }).catch(() => [1]);
    const stale = Date.now() - (S.lastRefresh ?? 0) > SAFETY_REFRESH_MS;
    if ((logs.length || stale) && !document.activeElement?.matches("input")) {
      const blk = await S.pub.getBlock();
      S.clockSkew = Number(blk.timestamp) - Math.floor(Date.now() / 1000);
      await refresh();
    }
    S.lastBlock = bn;
  } catch (e) { console.warn("poll", e); }
}

async function renderStats() {
  const [open, fees, fee, opensAt] = await Promise.all([
    read("openBatchId"), read("accruedFees"), tryRead("usdWei"), read("assemblyOpensAt"),
  ]);
  const treasury = S.store ? await tryRead("treasuryBalance", [], S.store, STORE_ABI) : null;
  const fallback = await tryRead("feeUsesFallback");
  S.feeFallback = !!fallback;
  const [, filled] = await read("batchInfo", [open]);
  S.openBatch = open; S.openFilled = filled;
  const stat = (v, k) => el("div", { class: "stat" }, el("b", {}, v), el("span", {}, k));
  $("stats").replaceChildren(
    stat(`${filled} / 80`, `Credits in the open batch (#${open})`),
    stat(String(open), "batches filled so far"),
    el("div", { class: "stat" }, el("b", { id: "stat-statements" }, "…"), el("span", {}, "Statements made")),
    stat(fee == null ? "unavailable" : ethFee(fee * 2n), fallback ? "fee per Credit (fixed fallback: price feed offline)" : `fee per Credit (${feeUsd(2)}; ${feeUsd(1)} each for ${BULK_MIN}+)`),
    ...(treasury == null ? [] : [stat(eth(treasury, 4), S.backed ? "store treasury (75% of fees; buys unsold batches)" : "store treasury (buys unsold Statements)")]),
    stat(opensAt <= now() ? "Open" : `in ${dur(opensAt - now())}`, S.backed ? "auctions" : "Statement assembly"),
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
  const mineSig = ids.join(",");
  if (mineSig === S.mineSig && grid.childElementCount) { updateDepositHint(); return; }
  S.mineSig = mineSig;
  grid.replaceChildren(...ids.map((id) => {
    const art = artCache.get(id);
    const tile = el("div", { class: "credit" + (S.selected.has(id) ? " sel" : ""), title: `Credit #${id}` },
      art?.img ? el("img", { src: art.img, alt: `Credit #${id}` }) : null,
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

// Tiny IndexedDB store for Credit artwork. Art is fixed on-chain (seed + payment time), so it
// can be kept forever. Every call is best-effort: private windows or blocked storage just
// fall back to fetching from the chain.
const artDb = (() => {
  let dbp = null;
  const open = () => (dbp ??= new Promise((ok) => {
    try {
      const req = indexedDB.open("creditpool-art", 1);
      req.onupgradeneeded = () => req.result.createObjectStore("art");
      req.onsuccess = () => ok(req.result);
      req.onerror = () => ok(null);
    } catch { ok(null); }
  }));
  const tx = async (mode, fn) => {
    const db = await open();
    if (!db) return null;
    return new Promise((ok) => {
      try {
        const r = fn(db.transaction("art", mode).objectStore("art"));
        r.onsuccess = () => ok(r.result ?? null);
        r.onerror = () => ok(null);
      } catch { ok(null); }
    });
  };
  return { get: (k) => tx("readonly", (st) => st.get(k)), put: (k, v) => tx("readwrite", (st) => st.put(v, k)) };
})();
async function loadArt(tiles) {
  const queue = [...tiles];
  const worker = async () => {
    for (let t; (t = queue.shift());) {
      const id = BigInt(t.dataset.id);
      if (!artCache.has(id)) {
        const saved = await artDb.get(`uri:${S.credits}:${id}`);
        if (saved) { artCache.set(id, saved); }
      }
      if (!artCache.has(id)) {
        const uri = await tryRead("tokenURI", [id], S.credits, CREDITS_ABI);
        let img = null, tier = null, print = null;
        try {
          const json = JSON.parse(atob(uri.split(",")[1]));
          img = onchainImage(json.image);
          const attr = Object.fromEntries((json.attributes ?? []).map((a) => [a.trait_type, a.value]));
          tier = tierOf(attr.Eights);
          print = attr.Print;
        } catch {}
        artCache.set(id, { img, tier, print });
        if (img) artDb.put(`uri:${S.credits}:${id}`, { img, tier, print });
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
  if (!n) return ($("deposit-hint").textContent = "Pick Credits to deposit (rarest shown first). Every Credit counts as one slot, whatever its rarity. " +
    (S.backed ? "You can withdraw until an auction starts, and nothing burns unless a sale is locked in." : "You can withdraw until the batch fills."));
  const txs = chunkSizes(Number(n)).length;
  const fee = `Fee: ${feeUsd(depositUsd(n))} (${Number(n) >= BULK_MIN ? `bulk rate, ${feeUsd(1)}` : feeUsd(2)} per Credit). Earns ${2n * n} SCREDIT when the batch is burned into a Statement.`;
  const nudge = Number(n) < BULK_MIN ? ` Tip: ${BULK_MIN}+ Credits at once cost ${feeUsd(1)} each.` : "";
  if (txs > 1) return ($("deposit-hint").textContent = `${n} Credits → ${txs} transactions (gas limit). ${fee}`);
  const room = PER - S.openFilled;
  $("deposit-hint").textContent = (n <= room
    ? `Goes into batch #${S.openBatch} (${S.openFilled + n}/80 after). `
    : `Fills batch #${S.openBatch} with ${room}, the other ${n - room} spill into the next batch${n - room > PER ? "es" : ""}. `) + fee + nudge;
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
  const usdW = await readFresh("usdWei").catch(() => null);
  if (usdW == null) return toast("Price oracle is stale, try again shortly", true);
  const ids = [...S.selected];
  const sizes = chunkSizes(ids.length), txs = sizes.length;
  const totalWei = sizes.reduce((t, c) => t + usdW * BigInt(c * perCredit(c)), 0n);
  // Snapshot what the user is about to confirm, read fresh from the chain (the stats may not have
  // loaded yet, or may be a poll behind). The first transaction is pinned to THIS state.
  const shownBatch = await readFresh("openBatchId");
  const shownFilled = (await readFresh("batchInfo", [shownBatch]))[1];
  const room = PER - shownFilled;
  const ok = await confirmStep(`Deposit ${ids.length} Credit${ids.length > 1 ? "s" : ""}?`, [
    ids.length <= room
      ? `They go into batch #${shownBatch}, taking it to ${shownFilled + BigInt(ids.length)}/80.`
      : `${room} fill batch #${shownBatch}; the rest start the next batch.`,
    `Fee: ${feeUsd(depositUsd(ids.length))} total (≈ ${ethFee(totalWei)})${txs > 1 ? `, across ${txs} transactions` : ""}: ${feeRule()}. Not refunded if you withdraw.`,
    `You earn ${2 * ids.length} SCREDIT when their batch is burned into a Statement (store points; they can't be transferred). Withdrawn Credits earn none.`,
    S.backed ? "You can withdraw them any time until an auction starts. They burn only if their batch sells." : "You can withdraw them any time until their batch reaches 80. After that they're locked in.",
  ], "Deposit");
  if (!ok) return;
  // The first tx is pinned to the batch state the user just confirmed; later chunks follow our own deposits.
  let expect = [shownBatch, shownFilled];
  // Split big deposits under the per-tx gas cap. Each tx pays its own fee.
  const chunks = [];
  for (let i = 0, k = 0; k < sizes.length; i += sizes[k++]) chunks.push(ids.slice(i, i + sizes[k]));
  for (const [i, chunk] of chunks.entries()) {
    const label = chunks.length > 1 ? `Deposit ${i + 1}/${chunks.length} (${chunk.length})` : `Deposit ${chunk.length}`;
    // Pin the batch we showed the user: if someone deposits first, the tx reverts instead of
    // landing somewhere unexpected. 5% fee buffer against price moves; the pool refunds the excess.
    const due = usdW * BigInt(chunk.length * perCredit(chunk.length)); // = depositFeeFor(chunk.length)
    if (!(await send(label, "depositAt", [chunk, ...expect], due + due / 20n))) break; // selection kept on failure
    for (const id of chunk) S.selected.delete(id);
    const openNow = await readFresh("openBatchId");
    expect = [openNow, (await readFresh("batchInfo", [openNow]))[1]];
  }
};

// Everything waiting for this wallet: sale shares from settled batches + outbid refunds.
async function renderClaims(myBatchIds) {
  if (!S.account) return;
  const [refund, rows] = await Promise.all([
    read("pendingReturns", [S.account]),
    Promise.all(myBatchIds.map(async (b) => {
      const [info, slots, claimed] = await Promise.all([read("batchInfo", [b]), read("slots", [b, S.account]), read("claimed", [b, S.account])]);
      return S.states[info[0]] === "Settled" && slots && !claimed ? { b, amt: (info[4] * slots) / PER, slots } : null;
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
  if (refund) list.append(el("dt", {}, S.backed ? "Refunds (outbid, backings, unsold)" : "Outbid refund"), el("dd", {}, eth(refund)));
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
  if (S.backed) {
    // Backers and bidders follow their batches too, not only depositors.
    const ev = (name) => S.abi.find((x) => x.type === "event" && x.name === name);
    const more = await Promise.all([
      S.pub.getLogs({ address: S.pool, event: ev("Backed"), args: { backer: S.account }, fromBlock: S.dep.deployBlock }),
      S.pub.getLogs({ address: S.pool, event: ev("Bid"), args: {}, fromBlock: S.dep.deployBlock })
        .then((ls) => ls.filter((l) => l.args.bidder.toLowerCase() === S.account.toLowerCase())),
    ]).catch(() => [[], []]);
    logs.push(...more.flat());
  }
  const ids = [...new Set(logs.map((l) => l.args.batchId))].sort((a, b) => (a < b ? 1 : -1));
  if (S.backed) await renderInbox(backingCtx, ids); // the inbox replaces "Ready to collect"
  else renderClaims(ids);
  const cards = (await Promise.all(ids.map((b) => batchCard(b, true)))).filter(Boolean);
  box.replaceChildren(...(cards.length ? cards : [el("p", { class: "muted" }, "You haven't deposited yet. Pick Credits above to join the open batch.")]));
}

// Filter tabs. "voting" covers batches waiting on a price; "sold" covers every finished batch.
const BURN_FIRST_FILTERS = [
  ["all", "All", () => true],
  ["filling", "Filling", (s) => s === "Filling"],
  ["ready", "Ready to assemble", (s) => s === "Full"],
  ["voting", "Voting", (s) => s === "Assembled"],
  ["auction", "Live auctions", (s) => s === "Auction"],
  ["sold", "Sold", (s) => s === "Settled" || s === "Redeemed"],
];
S.filters = BURN_FIRST_FILTERS;
S.filter = "all";

async function renderAllPage(replace = false) {
  if (replace) {
    // One cheap read per batch to know every batch's state (for tab counts and filtering).
    const ids = [];
    for (let b = S.openBatch; b >= 0n; b--) ids.push(b);
    const states = await Promise.all(ids.map((b) => limit(() => read("batchInfo", [b])).then((x) => S.states[x[0]])));
    S.byState = ids.map((b, i) => [b, states[i]]);
    S.shown = 0;
    renderFilters();
  }
  const test = (S.filters.find((f) => f[0] === S.filter) ?? S.filters[0])[2];
  const list = S.byState.filter(([, st]) => test(st)).map(([b]) => b);
  const page = list.slice(S.shown, S.shown + Number(PAGE));
  const cards = await Promise.all(page.map((b) => batchCard(b)));
  if (replace) $("all-batches").replaceChildren(...(cards.length ? cards : [el("p", { class: "muted" }, "No batches here yet.")]));
  else $("all-batches").append(...cards);
  S.shown += page.length;
  $("more").hidden = S.shown >= list.length;
}
function renderFilters() {
  $("filters").replaceChildren(...S.filters.map(([key, label, test]) => {
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
  const v = $("jump-id").value.trim();
  if (v === "") return;
  if (!/^\d+$/.test(v)) return toast("Enter a batch number", true);
  const b = BigInt(v);
  if (b > S.openBatch) return toast(`Batch #${b} doesn't exist yet`, true);
  const card = await batchCard(b);
  $("all-batches").replaceChildren(card);
  $("more").hidden = true;
};

// ───────────────────────── batch card ─────────────────────────
async function batchCard(b, mineOnly = false) {
  if (S.backed) return backedCard(backingCtx, b, mineOnly);
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
  let tally = null; // vote count: rendered, so it must be part of the reuse signature
  const row = (k, v) => kv.append(el("dt", {}, k), el("dd", {}, v));
  const pct = (n) => `${((Number(n) / 80) * 100).toFixed(n % 4n === 0n ? 0 : 1)}%`;
  row("Depositors", String(depositors));
  if (me && slots) row("Your share", `${slots} of 80 · ${pct(slots)}`);
  if (st >= 2 && st <= 5) row("Statement", `#${statementId}`);
  if (state === "Assembled") {
    // Tally votes client-side (≤ 80 depositors) so everyone can see how close the vote is.
    const addrs = await read("batchDepositors", [b]);
    const [counts, prefs] = await Promise.all([
      Promise.all(addrs.map((a) => read("slots", [b, a]))),
      Promise.all(addrs.map((a) => read("reservePref", [b, a]))),
    ]);
    const voted = counts.reduce((sum, n, i) => (prefs[i] ? sum + n : sum), 0n);
    tally = voted;
    row("Voted", `${voted} of 80${voted * 2n > PER ? " · enough to start" : ` · need 41`}`);
    row("Minimum price", noReserve ? (reserve ? `${ethUsd(reserve)} (lowest vote)` : "none")
      : reserve == null ? "decided once 41 vote" : ethUsd(reserve));
    if (me && slots) row("Your minimum", pref ? ethUsd(pref) : "not voted");
  }
  if (state === "Auction") {
    row("Minimum price", auctionReserve ? ethUsd(auctionReserve) : "none");
    row("High bid", highBid ? `${ethUsd(highBid)} · ${short(highBidder)}` : "no bids yet");
    row("Ends", el("span", { "data-ends": String(endsAt) }, dur(endsAt - now())));
    bids = await bidHistory(b);
  }
  if (state === "Settled") {
    bids = await bidHistory(b);
    row("Sold for", ethUsd(highBid));
    row("Split among depositors", `${eth(proceeds)} (no sale fee)`);
    if (me && slots) row("You get", `${ethUsd((proceeds * slots) / PER)}${claimed ? " · collected" : ""}`);
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
        const all = await readFresh("batchCredits", [b]);
        const [owners, homes] = await Promise.all([
          Promise.all(all.map((id) => readFresh("depositorOf", [id]))),
          Promise.all(all.map((id) => readFresh("batchOf", [id]))),
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
    // A batch with a single depositor belongs to them alone: only they can redeem or auction it.
    const sole = depositors === 1n;
    const soleMine = sole && slots === PER;
    if (sole && !soleMine) actions.append(el("span", { class: "muted small" },
      "One depositor holds all 80 slots, so only they can redeem this Statement or put it up for auction."));
    else if (!(me && slots)) actions.append(el("span", { class: "muted small" },
      "Only this batch's depositors vote on the minimum price. Anyone can start the auction once more than 40 slots have voted, and anyone can bid."));
    // Both buttons use startAuctionAt: the CONTRACT refuses if the minimum changed after the
    // user confirmed it (votes moved, or the 30-day fallback kicked in).
    const start = (lines) => async () => {
      if (!(await confirmStep(`Start the auction for Statement #${statementId}?`, lines, "Start auction"))) return;
      const ok = await send(`Start auction #${b}`, "startAuctionAt", [b, reserve]);
      if (!ok) refresh();
    };
    if (sole && !soleMine) { /* no start button for anyone but the sole holder */ }
    else if (noReserve && reserve != null) actions.append(btn(reserve ? `Start auction @ ${eth(reserve)}` : "Start no-reserve auction", start([
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
      // Mirrors CreditPool.bid: +5%, and at least +1 wei when 5% rounds to zero.
      const step = (highBid * 500n) / 10000n;
      let min = highBidder === "0x0000000000000000000000000000000000000000" ? auctionReserve : highBid + (step === 0n ? 1n : step);
      if (min === 0n) min = 1n;
      // What winning really costs a depositor: the bid minus their slots/80 share of it (no sale fee).
      const netCost = (v) => v - (v * slots) / PER;
      const i = input("Bid (ETH)", formatEther(min));
      actions.append(el("div", { class: "row" }, i, btn("Bid", () => {
        const v = toWei(i.value);
        if (v == null) return toast("Enter a bid in ETH", true);
        if (v < min) return toast(`Minimum bid is ${formatEther(min)} ETH`, true);
        confirmStep(`Bid ${eth(v, 6)} on Statement #${statementId}?`, [
          "Your ETH is held by the pool until the auction ends. You can't cancel a bid.",
          "If someone outbids you, it's returned: collect it under \"Ready to collect\".",
          "If you win, the Statement goes to your wallet when the auction is settled.",
          ...(me && slots ? [`You hold ${slots}/80 slots, so if you win, ${eth(v - netCost(v), 4)} of this comes back to you: the Statement really costs you ${eth(netCost(v), 4)}.`] : []),
        ], "Place bid").then((ok) => ok && send(`Bid on #${b}`, "bid", [b], v));
      }, "", "bid")));
      actions.append(el("span", { class: "muted small" }, `min ${eth(min, 6)} · bids in the last 15m extend it`));
      if (me && slots) {
        // Live: recompute from whatever is in the bid box.
        const hint = el("span", { class: "muted small" });
        const update = () => {
          const v = toWei(i.value) ?? min;
          hint.textContent = `You're a depositor. If you bid and win, ${slots}/80 of the sale comes back to you: ` +
            `winning at ${eth(v, 4)} really costs you about ${eth(netCost(v), 4)}. Bid if you think it's going too cheap.`;
        };
        i.addEventListener("input", update);
        update();
        actions.append(hint);
      }
    } else {
      actions.append(btn("Settle auction", () => send(`Settle #${b}`, "settle", [b]), "", "settle"));
    }
  }
  if (state === "Settled" && me && slots && !claimed) {
    actions.append(btn(`Claim ${eth((proceeds * slots) / PER)}`, () => send(`Claim #${b}`, "claim", [b]), "", "claim"));
  }

  const who = whoDetails(b, depositors);

  // What's being sold: the batch's 80 Credits (they still render after the burn).
  const showArt = S.art && (["Full", "Assembled", "Auction", "Settled", "Redeemed"].includes(state) || (state === "Filling" && filled > 0n));
  const mosaic = showArt ? mosaicButton(b, statementId, state) : null;

  // Same data as last render → return the existing element untouched.
  const sig = JSON.stringify([info, auction, escape, noReserve, assembledAt, slots, pref, claimed, reserve,
    bids?.length ?? 0, tally, state === "Auction" && now() < endsAt, me, S.viewOnly],
  (_, v) => (typeof v === "bigint" ? v.toString() : v));
  const cacheKey = `${mineOnly ? "mine" : "all"}:${b}`;
  const cached = S.cards.get(cacheKey);
  if (cached && cached.sig === sig) return cached.el;

  const tagText = state === "Full" && escape ? "Full · escape open" : state;
  const card = el("div", { class: "batch" },
    el("div", { class: "batch-top" }, el("b", {}, `Batch #${b}`), el("span", { class: `tag ${state}` }, tagText)),
    nextStep({ state, filled, escape, noReserve, tally, reserve, slots, me, pref, highBid, endsAt, claimed, proceeds, assembledAt, sole: depositors === 1n }),
    // The next thing to do sits right under the status line, not below the art and details.
    actions.childElementCount ? actions : null,
    el("div", { class: "bar", title: `${filled}/80` }, el("i", { style: `width:${(Number(filled) / 80) * 100}%` })),
    el("span", { class: "muted small" }, `${filled}/80 Credits`),
    mosaic,
    kv,
    bids?.length ? bidList(bids, highBidder, me) : null,
    who,
  );
  S.cards.set(cacheKey, { sig, el: card });
  return card;
}

// Who's in the batch: loaded on first open so long lists don't cost RPC calls up front.
function whoDetails(b, depositors) {
  if (depositors === 0n) return null;
  const me = S.account;
  const who = el("details", { class: "who" }, el("summary", {}, `Who's in this batch (${depositors})`));
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
  return who;
}

// Everything the backed-auction module needs from the app.
const backingCtx = {
  S, el, read, readFresh, send, eth, ethUsd, short, dur, now, toWei, confirmStep, toast, PER,
  mosaicButton: (...a) => mosaicButton(...a), bidHistory: (b) => bidHistory(b), bidList: (...a) => bidList(...a), whoDetails,
};

// ───────────────────────── Statement viewer ─────────────────────────
// A few RPC calls at a time, so 80-Credit mosaics don't flood public nodes.
const limit = (() => {
  let active = 0; const q = [];
  // Newest request first: art for whatever just scrolled into view jumps ahead of older, off-screen work.
  const next = () => { if (active >= 24 || !q.length) return; active++; const [fn, ok, no] = q.pop(); fn().then(ok, no).finally(() => { active--; next(); }); };
  return (fn) => new Promise((ok, no) => { q.push([fn, ok, no]); next(); });
})();
const memo = (fn) => { const m = new Map(); return (k) => (m.has(k) ? m.get(k) : (m.set(k, fn(k)), m.get(k))); };

const creditSeed = memo((id) => limit(() => Promise.all([
  read("seedOf", [id], S.credits, CREDITS_ABI), read("timestampOf", [id], S.credits, CREDITS_ABI),
])));
const creditImg = memo(async (id) => {
  const key = `svg:${S.credits}:${id}`;
  const hit = await artDb.get(key);
  if (hit) return hit;
  const [seed, ts] = await creditSeed(id);
  const svg = await limit(() => read("svg", [seed, ts], S.art, ART_ABI));
  const url = "data:image/svg+xml;utf8," + encodeURIComponent(svg);
  artDb.put(key, url);
  return url;
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
      address: S.pool, event: S.abi.find((x) => x.type === "event" && x.name === "Bid"),
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
// Only embedded images: a remote URL in tokenURI would let its host see who is viewing.
const onchainImage = (src) => (typeof src === "string" && src.startsWith("data:image/") ? src : null);
const statementImg = memo(async (sid) => {
  try {
    const uri = await read("tokenURI", [sid], S.statements, STATEMENTS_ABI);
    const json = uri.startsWith("data:") ? JSON.parse(atob(uri.split(",")[1])) : null;
    return onchainImage(json?.image);
  } catch { return null; }
});

function fillImgs(imgs, ids) {
  imgs.forEach((img, i) => creditImg(ids[i]).then((src) => {
    img.onload = () => img.classList.remove("ld");
    img.src = src;
  }).catch((e) => console.warn(`Credit #${ids[i]} art`, e)));
}

// The 80-Credit mosaic grid, loaded lazily when it scrolls into view.
function mosaicGrid(b, state) {
  // 80 shimmering cells right away (never an empty grey box), then each Credit fades in as it
  // arrives. Loading starts a screen ahead of the viewport so it's usually done by the time you look.
  const grid = el("span", { class: "mosaic-grid" }, ...Array.from({ length: 80 }, () => el("i", { class: "slot ld" })));
  const io = new IntersectionObserver(async ([e]) => {
    if (!e.isIntersecting) return;
    io.disconnect();
    const ids = await batchIds(b, state);
    const imgs = ids.map(() => el("img", { alt: "", class: "ld" }));
    const empty = Array.from({ length: 80 - ids.length }, () => el("i", { class: "slot" }));
    grid.replaceChildren(...imgs, ...empty);
    fillImgs(imgs, ids);
  }, { rootMargin: "250px 0px" });
  io.observe(grid);
  return grid;
}

// ───────────────────────── Statements gallery ─────────────────────────
const GALLERY_STATES = ["Assembled", "Auction", "Settled", "Redeemed"];
const GALLERY_LABEL = { Assembled: "Voting", Auction: "Live auction", Settled: "Sold", Redeemed: "Redeemed" };

async function renderGallery() {
  const made = (S.byState ?? []).filter(([, st]) => (S.backed ? st === "Settled" : GALLERY_STATES.includes(st))); // backed: a Statement exists only once sold
  $("stat-statements") && ($("stat-statements").textContent = String(made.length));
  $("gallery-section").hidden = made.length === 0;
  $("gallery-count").textContent = made.length ? `(${made.length})` : "";
  const tiles = await Promise.all(made.map(([b, st]) => galleryTile(b, st)));
  $("gallery").replaceChildren(...tiles);
}

async function galleryTile(b, state) {
  const [info, auction, reserve] = await Promise.all([
    read("batchInfo", [b]), read("auctions", [b]), tryRead("auctionReserve", [b]),
  ]);
  const sid = info[3];
  const [, highBid, , endsAt] = auction;
  const owner = await tryRead("ownerOf", [sid], S.statements, STATEMENTS_ABI);
  S.owners.set(sid, owner); S.sidBatch.set(sid, b); // the store section reuses these
  const sig = JSON.stringify([state, info, auction, reserve, owner, state === "Auction" && now() < endsAt, S.account],
    (_, v) => (typeof v === "bigint" ? v.toString() : v));
  const cached = S.tiles.get(b);
  if (cached && cached.sig === sig) return cached.el;

  const official = await statementImg(sid);
  const art = official ? el("img", { class: "official-thumb", src: official, alt: `Statement #${sid}` }) : mosaicGrid(b, state);
  const line = state === "Assembled" ? (reserve == null ? "Voting on a minimum price" : `Minimum ${eth(reserve)}, ready to auction`)
    : state === "Auction" ? (highBid ? `High bid ${eth(highBid)}` : `No bids yet · min ${eth(auction[2])}`)
    : state === "Settled" ? (info[4] ? `Sold for ${eth(info[4])}` : "Taken by its sole holder")
    : "Taken by its sole holder";
  const who = !owner ? "—"
    : owner.toLowerCase() === S.pool.toLowerCase() ? "Held by the pool for its depositors"
    : S.store && owner.toLowerCase() === S.store.toLowerCase() ? "In the store (bid with SCREDIT)"
    : S.account && owner.toLowerCase() === S.account.toLowerCase() ? "Owned by you"
    : `Owned by ${short(owner)}`;
  const tile = el("button", {
    class: "stile", "aria-label": `Statement #${sid}, ${GALLERY_LABEL[state]}`, "data-tip": "viewStatement",
    onclick: () => openViewer(b, sid, state),
  },
    el("span", { class: "stile-art" }, art),
    el("span", { class: "stile-top" }, el("b", {}, `Statement #${sid}`), el("span", { class: `tag ${state}` }, S.backed && !info[4] ? "Redeemed" : GALLERY_LABEL[state])),
    el("span", { class: "stile-line" }, line),
    state === "Auction" && now() < endsAt ? el("span", { class: "muted small" }, "Ends in ", el("span", { "data-ends": String(endsAt) }, dur(endsAt - now()))) : null,
    el("span", { class: "muted small" }, `${who} · batch #${b}`),
  );
  S.tiles.set(b, { sig, el: tile });
  return tile;
}

// ───────────────────────── store: SCREDIT-only auctions ─────────────────────────
// Statements the treasury bought (only ones whose pool auction ended with no bids) are auctioned
// here for SCREDIT points. Each bid also pays a $0.25 platform fee in ETH.
async function renderStore() {
  if (!S.store) return;
  $("store-section").hidden = false;
  const [treasury, fee, mine] = await Promise.all([
    read("treasuryBalance", [], S.store, STORE_ABI), tryRead("bidFee", [], S.store, STORE_ABI),
    S.account ? read("balanceOf", [S.account], S.store, STORE_ABI) : null,
  ]);
  S.points = mine ?? 0n;
  $("points").hidden = mine == null;
  $("points").textContent = `${mine ?? 0n} SCREDIT`;
  const owed = S.backed ? await tryRead("pendingReturns", [S.store]) : null;
  $("store-meta").replaceChildren();
  if (owed) $("store-meta").append(el("button", { class: "link", onclick: () => send("Collect treasury refunds", "collectRefund", [], undefined, S.store, TREASURY_ABI) },
    `collect ${eth(owed)} back into the treasury`), " · ");
  $("store-meta").append(`Treasury ${eth(treasury, 4)} · bid fee ${feeUsd(0.25)}${fee ? ` (≈ ${ethFee(fee)})` : ""}${mine != null ? ` · you have ${mine} SCREDIT` : ""}`);

  // Everything ever listed (Listed events, scanned incrementally) plus anything the store holds now.
  S.storeScan ??= { from: S.dep.deployBlock || 0n, sids: new Set() };
  const to = await S.pub.getBlockNumber();
  if (to >= S.storeScan.from) {
    const logs = await S.pub.getLogs({
      address: S.store, event: STORE_ABI.find((x) => x.type === "event" && x.name === "Listed"),
      fromBlock: S.storeScan.from, toBlock: to,
    }).catch(() => null);
    if (logs) { for (const l of logs) S.storeScan.sids.add(l.args.statementId); S.storeScan.from = to + 1n; }
  }
  const store = S.store.toLowerCase();
  for (const [sid, o] of S.owners) if (o && o.toLowerCase() === store) S.storeScan.sids.add(sid);

  const cards = (await Promise.all([...S.storeScan.sids].map((sid) => storeCard(sid, fee)))).filter(Boolean);
  $("store").replaceChildren(...(cards.length ? cards
    : [el("p", { class: "muted" }, S.backed ? "Nothing in the store yet. Statements arrive here when a treasury backing wins its auction."
      : "Nothing in the store yet. The treasury only buys Statements whose auction ended with no bids, at the minimum the depositors' majority voted.")]));
}

async function storeCard(sid, fee) {
  const [[highBidder, highBid, reserve, endsAt], owner] = await Promise.all([
    read("listings", [sid], S.store, STORE_ABI), tryRead("ownerOf", [sid], S.statements, STATEMENTS_ABI),
  ]);
  const inStore = owner && owner.toLowerCase() === S.store.toLowerCase();
  if (!endsAt && !inStore) return null; // sold and delivered: it shows in the gallery as owned
  const b = S.sidBatch.get(sid);
  // The Statement's own image when its contract provides one (one call), else the 80-Credit mosaic.
  const official = await statementImg(sid);
  const art = official ? el("img", { class: "official-thumb", src: official, alt: `Statement #${sid}` })
    : b != null ? mosaicGrid(b, "Settled") : el("span", { class: "muted" }, `#${sid}`);
  const noBids = highBidder === "0x0000000000000000000000000000000000000000";
  const live = endsAt && now() < endsAt;
  const card = el("div", { class: "stile store-card" },
    el("span", { class: "stile-art" }, art),
    el("span", { class: "stile-top" }, el("b", {}, `Statement #${sid}`),
      el("span", { class: `tag ${live ? "Auction" : "Assembled"}` }, live ? "Store auction" : endsAt ? "Ended" : "In the treasury")),
    el("span", { class: "stile-line" }, !endsAt ? "Not listed yet"
      : noBids ? `No bids yet · min ${reserve || 1n} SCREDIT` : `High bid ${highBid} SCREDIT · ${short(highBidder)}`),
    live ? el("span", { class: "muted small" }, "Ends in ", el("span", { "data-ends": String(endsAt) }, dur(endsAt - now()))) : null,
  );
  const canAct = S.account && !S.viewOnly;
  if (live && canAct) {
    const min = await readFresh("minBid", [sid], S.store, STORE_ABI);
    const i = el("input", { type: "number", min: String(min), step: "1", value: String(min), "aria-label": "Bid in SCREDIT" });
    card.append(el("div", { class: "row" }, i, el("button", { "data-tip": "storeBid", onclick: async () => {
      const pts = /^\d+$/.test(i.value) ? BigInt(i.value) : null;
      if (pts == null || pts < min) return toast(`Minimum bid is ${min} SCREDIT`, true);
      // A leader's held points come back before the new bid is taken, so they count toward a raise.
      const leading = S.account && highBidder.toLowerCase() === S.account.toLowerCase();
      const usable = S.points + (leading ? highBid : 0n);
      if (pts > usable) return toast(`You have ${usable} SCREDIT to bid with`, true);
      const ok = await confirmStep(`Bid ${pts} SCREDIT on Statement #${sid}?`, [
        `Your ${pts} SCREDIT are held while you lead. If someone outbids you, they come straight back.`,
        `Each bid costs a ${feeUsd(0.25)} platform fee in ETH${fee ? ` (≈ ${ethFee(fee)})` : ""}, win or lose.`,
        "If you win, your SCREDIT are spent and the Statement goes to your wallet when the auction is settled.",
      ], "Bid");
      if (!ok) return;
      const f = await readFresh("bidFee", [], S.store, STORE_ABI);
      await send(`Store bid #${sid}`, "bid", [sid, pts], f + f / 20n, S.store, STORE_ABI); // 5% buffer, excess refunded
    } }, `Bid (+${feeUsd(0.25)})`)));
  }
  if (endsAt && !live) {
    card.append(el("button", { "data-tip": "storeSettle", onclick: () => send(`Settle store #${sid}`, "settle", [sid], undefined, S.store, STORE_ABI) }, "Settle"));
  }
  return card;
}

function mosaicButton(b, sid, state) {
  const grid = mosaicGrid(b, state);
  const box = el("button", {
    class: "mosaic", "data-tip": state === "Filling" || state === "Full" ? "viewBatch" : "viewStatement", "aria-label": `View the 80 Credits in batch #${b}`,
    onclick: () => openViewer(b, sid, state),
  }, grid, el("span", { class: "mosaic-cap" },
    state === "Filling" ? "Credits in this batch so far · click to view"
    : state === "Full" ? "The 80 Credits in this batch · click to view"
    : S.backed && state !== "Settled" ? "The 80 Credits up for sale · nothing burns unless it sells · click to view"
    : `Statement #${sid} · made from these 80 Credits · click to view`));
  return box;
}

async function openViewer(b, sid, state) {
  const dlg = $("viewer");
  const body = $("viewer-body");
  const assembled = S.backed ? state === "Settled" : state !== "Full" && state !== "Filling";
  $("viewer-title").textContent = assembled ? `Statement #${sid} · Batch #${b}`
    : state === "Full" ? `Batch #${b} · ${S.backed ? "full" : "ready to assemble"}` : state === "Filling" ? `Batch #${b} · filling` : `Batch #${b} · for sale`;
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
        : S.backed && state !== "Filling" ? "These 80 Credits burn into one Statement only if the sale is locked in. Until then they stay in the pool, unburned."
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

// One plain sentence per card: what's happening and what anyone (or you) can do next.
function nextStep(x) {
  const mine = x.me && x.slots;
  const t = (s) => el("p", { class: "next" }, s);
  switch (x.state) {
    case "Filling":
      return t(`Filling: ${80n - x.filled} more Credits needed.${mine ? " You can withdraw yours until it's full." : " Deposit yours above to join."}`);
    case "Full":
      return t(x.escape
        ? "Full, but not assembled for 14 days: depositors can now take their Credits back, or anyone can still assemble it."
        : "Full. Anyone can press Assemble to burn these 80 Credits into a Statement.");
    case "Assembled": {
      if (x.sole) return t(x.slots === PER
        ? "You hold all 80 slots: redeem the Statement to your wallet (no fee), or set a minimum price and auction it."
        : "One depositor holds all 80 slots; only they can redeem or auction it.");
      if (x.noReserve) return t("Unsold for 30 days, so the minimum is now the lowest vote. Anyone can start the auction.");
      // Heads-up before the 30-day fallback (accepted residual AR-10): after it, the minimum is the
      // lowest single vote, so depositors who value the Statement more should be ready to bid.
      const left = x.assembledAt + NO_RESERVE_AFTER - now();
      if (left > 0n && left < 7n * 86400n) {
        return el("p", { class: "next warn" }, "Unsold for nearly 30 days. In ",
          el("span", { "data-ends": String(x.assembledAt + NO_RESERVE_AFTER) }, dur(left)),
          ", the minimum drops to the lowest price any depositor voted, and anyone can start the auction. Vote, and be ready to bid if you value it more.");
      }
      const started = x.tally * 2n > PER;
      if (!started) {
        const need = PER / 2n + 1n - x.tally;
        return t(`Waiting for depositors to vote a minimum price: ${need} more slots needed.${mine && !x.pref ? " Enter yours here." : ""}`);
      }
      return t(`Votes are in: minimum ${eth(x.reserve)}. Anyone can start the 24-hour auction.`);
    }
    case "Auction":
      return now() < x.endsAt
        ? el("p", { class: "next" }, `Auction live${x.highBid ? `: high bid ${eth(x.highBid)}` : ", no bids yet"}. Ends in `,
          el("span", { "data-ends": String(x.endsAt) }, dur(x.endsAt - now())), ". Anyone can bid.")
        : t("Auction over. Anyone can press Settle to send the Statement to the winner and pay the depositors.");
    case "Settled":
      return t(mine ? (x.claimed ? "Sold, and you've collected your share." : `Sold. Your share is ready: ${eth((x.proceeds * x.slots) / PER)}.`)
        : "Sold. Depositors can collect their share.");
    case "Redeemed": return t("Taken whole by the depositor who held all 80 slots.");
    case "Dissolved": return t(mine ? "Dissolved. Withdraw your Credits below." : "Dissolved: depositors took their Credits back.");
    default: return null;
  }
}

function tick() {
  for (const n of document.querySelectorAll("[data-ends]")) n.textContent = dur(BigInt(n.dataset.ends) - now());
}

init().catch((e) => { console.error(e); notice(e.message); });
