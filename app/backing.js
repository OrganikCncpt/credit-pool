// Backed auctions (BackedPool): sell first, burn second.
// A pluggable feature: app.js detects a BackedPool at load and hands batch cards, filters and
// page copy to this module. Nothing here runs against the burn-first CreditPool.
import { parseAbi, formatEther } from "./vendor/viem.js";

export const BACKED_ABI = parseAbi([
  "function assemblyOpensAt() view returns (uint256)",
  "function statements() view returns (address)",
  "function vault() view returns (address)",
  "function credits() view returns (address)",
  "function store() view returns (address)",
  "function openBatchId() view returns (uint256)",
  "function accruedFees() view returns (uint256)",
  "function usdWei() view returns (uint256)",
  "function depositFeeFor(uint256) view returns (uint256)",
  "function feeUsesFallback() view returns (bool)",
  "function batchInfo(uint256) view returns (uint8 state, uint256 filled, uint256 depositorCount, uint256 statementId, uint256 proceeds, uint64 round, uint64 nonce)",
  "function batchCredits(uint256) view returns (uint256[])",
  "function batchDepositors(uint256) view returns (address[])",
  "function slots(uint256, address) view returns (uint256)",
  "function reservePref(uint256, address) view returns (uint256)",
  "function claimed(uint256, address) view returns (bool)",
  "function depositorOf(uint256) view returns (address)",
  "function batchOf(uint256) view returns (uint256)",
  "function auctions(uint256) view returns (address highBidder, uint256 highBid, uint256 minimum, uint64 endsAt)",
  "function majorityMinimum(uint256) view returns (uint256)",
  "function bestBacking(uint256) view returns (address who, uint256 amount)",
  "function backings(uint256, address) view returns (uint256 amount, uint64 nonce)",
  "function backersOf(uint256) view returns (address[] who, uint256[] amount, bool[] current)",
  "function minNextBid(uint256) view returns (uint256)",
  "function pendingReturns(address) view returns (uint256)",
  "function MIN_BACKING() view returns (uint256)",
  "function deposit(uint256[] creditIds) payable",
  "function depositAt(uint256[] creditIds, uint256 expectedBatch, uint256 expectedFilled) payable",
  "function depositInto(uint256 batchId, uint256[] creditIds, uint256 expectedFilled) payable",
  "function withdraw(uint256[] creditIds)",
  "function setReserve(uint256 batchId, uint256 reserveWei)",
  "function back(uint256 batchId) payable",
  "function withdrawBacking(uint256 batchId)",
  "function reconfirm(uint256 batchId)",
  "function startAuction(uint256 batchId, uint256 minOpening)",
  "function bid(uint256 batchId) payable",
  "function settle(uint256 batchId)",
  "function redeem(uint256 batchId)",
  "function claim(uint256 batchId)",
  "function withdrawRefund()",
  "function sweepFees()",
  "event Deposited(address indexed who, uint256 indexed batchId, uint256 creditId)",
  "event Backed(uint256 indexed batchId, address indexed backer, uint256 total)",
  "event Bid(uint256 indexed batchId, address indexed bidder, uint256 amount, uint256 endsAt)",
  "event AuctionStarted(uint256 indexed batchId, uint64 round, address backer, uint256 opening, uint256 minimum, uint256 endsAt)",
  "error WrongBatchState()", "error NotDepositor()", "error InsufficientFee()", "error StaleOracle()",
  "error BidTooLow()", "error AuctionLive()", "error NothingToClaim()", "error TransferFailed()",
  "error UnexpectedToken()", "error StatementNotReceived()", "error CreditsNotBurned()", "error BatchMoved()",
  "error ZeroAddress()", "error NotBacked()", "error BackingTooLow()", "error BackingChanged()",
  "error NoMinimum()", "error BelowMinimum()", "error NotYet()", "error NeedMoreGas()", "error TooMany()",
]);

// Contract enum → the names the rest of the site uses ("Settled" = sold and delivered).
// The store's treasury side (BackedStore): owner-only backing within a per-batch cap.
export const TREASURY_ABI = parseAbi([
  "function owner() view returns (address)",
  "function treasuryBalance() view returns (uint256)",
  "function maxTreasuryBid() view returns (uint256)",
  "function backBatch(uint256 batchId, uint256 amount, uint256 expectedTotal)",
  "function unbackBatch(uint256 batchId)",
  "function reconfirmBatch(uint256 batchId)",
  "function collectRefund()",
  "error NotFull()", "error NotDepositor()", "error AboveMinimum()", "error NoMinimum()", "error OverCap()", "error PriceMoved()",
]);

export const BACKED_STATES = ["Filling", "Full", "Auction", "Settled"];
const LABEL = { Filling: "Filling", Auction: "Auction", Settled: "Sold" };
// A full batch's tag says what it's waiting for: a price, a backer at that price, or someone to press Start.
export const stateLabel = (s, minimum, bestAmt) => s !== "Full" ? LABEL[s] ?? s
  : !minimum ? "Needs a price" : bestAmt >= minimum ? "Ready to auction" : "Needs a backer";

export const BACKED_FILTERS = [
  ["all", "All", () => true],
  ["filling", "Filling", (s) => s === "Filling"],
  ["ready", "Pricing & backing", (s) => s === "Full"],
  ["auction", "Live auctions", (s) => s === "Auction"],
  ["sold", "Sold", (s) => s === "Settled"],
];

// A sale burns 80 Credits and awards points inside one all-or-nothing call that needs 12M gas
// available; the pool refuses to start it with less. Give those transactions room under the 16.7M cap.
export const FINALIZE_TX_GAS = 14_000_000n;

export const BACKED_TIPS = {
  back: "Offer ETH for this whole batch. Only a backing at or above the depositors' price can open the auction, as its opening bid. " +
    "If nobody outbids it, you get the Statement. Until the auction starts you can top up or take it back any time.",
  reconfirm: "Confirms your backing for the batch's current Credits, without adding ETH. Needed after the Credits change (including a backing posted while it filled).",
  unback: "Takes your backing back to Ready to collect. Only possible while it isn't the opening bid of a running auction.",
  vote: "The lowest price you'd accept for the whole batch. The depositors' price is the lowest price that more than 40 of the 80 slots accept. " +
    "No auction can start without it, and it only opens with a backing at or above it, so every auction sells at that price or more. Enter 0 to clear your vote.",
  startBacked: "Starts a 24-hour auction with the best backing as the opening bid (it meets the depositors' price). Nothing burns until it sells. Anyone can press it.",
  bid: "Your ETH is held by the pool. If you're outbid, you get it back (Ready to collect). Each bid must beat the last by 5%. Bids in the final 15 minutes add 15 minutes.",
  settleBacked: "Ends the auction and sells to the highest bidder: the 80 Credits burn into a Statement for them and depositors are paid. Anyone can press it.",
  withdrawBacked: "Take your Credits back to your wallet. Possible while the batch fills, and while it's full as long as no auction is running (the batch reopens).",
  redeemBacked: "You hold all 80 slots: burn them into a Statement straight to your wallet. No auction, no fee.",
  treasuryBack: "Owner only. Backs this batch from the store treasury, up to the per-batch cap and never above the depositors' price. Raising the cap takes 3 days.",
  deposit: "Moves the selected Credits into the open batch. Fee: {rule}, paid in ETH. You can withdraw until an auction starts; " +
    "they burn only if the batch sells, and then each earns 2 SCREDIT.",
  claim: "Sends your share of the sale to your wallet: your slots ÷ 80 of the price. Sales carry no fee.",
};

// Page copy for backed pools: the intro steps and the questions that differ from burn-first.
export function applyBackedCopy(el) {
  const steps = document.querySelector(".intro .steps");
  if (steps) steps.replaceChildren(
    ...[
      ["Deposit", "Add Credits to the open batch. Withdraw any time before an auction starts."],
      ["Vote", "Depositors set the batch's price: the lowest price more than 40 of the 80 slots accept."],
      ["Back", "Anyone offers ETH for the whole batch. Only a backing at or above the price can open the auction."],
      ["Auction", "24 hours, open to anyone, starting at the backing. It always sells at the price or more."],
      ["Collect", "Only a sale burns the 80 Credits. Your share = your Credits ÷ 80, plus 2 SCREDIT each."],
    ].map(([b, s]) => el("li", {}, el("b", {}, b), el("span", {}, s))),
  );
  const lead = document.querySelector(".intro p");
  if (lead) lead.textContent = "Pool your Credits with other holders. Nothing burns until a buyer is locked in: depositors set the price, " +
    "a backer commits ETH at that price or more, and a 24-hour auction lets anyone bid higher. The 80 Credits burn into a Statement only when it sells, and the sale is split by how many Credits each person put in.";
  for (const d of document.querySelectorAll("[data-mode='burn-first']")) d.remove();
  const gb = document.getElementById("gallery-blurb");
  if (gb) gb.textContent = "Every Statement the pool has sold. Each was burned from 80 Credits the moment its sale locked in; click one to see them.";
  const safe = [...document.querySelectorAll(".safety li")].find((li) => li.textContent.startsWith("During assembly"));
  if (safe) safe.textContent = "Nothing burns until a sale is locked in. The burn, the delivery to the buyer and the payout happen in one all-or-nothing step: if any part fails, it's all undone and the buyer is refunded. Jack's Statements contract can only reach the 80 Credits being sold.";
  const sb = document.getElementById("store-blurb");
  if (sb) sb.textContent = "Statements the store treasury won by backing batches, auctioned for SCREDIT only (never ETH). The treasury (75% of deposit fees) backs full batches, " +
    "capped per batch and never above the depositors' price; outbid, it gets its ETH back. Every SCREDIT bid also pays a small platform fee in ETH.";
  const faq = document.getElementById("faq");
  const q = (sum, text) => el("details", {}, el("summary", {}, sum), el("p", {}, text));
  faq?.querySelector("h2")?.after(
    q("How is the price set?", "Depositors vote the lowest price they'd accept. The batch's price is the lowest price that more than 40 of the 80 slots accept, " +
      "so a small group can't sell it cheap. No auction can start until that price exists."),
    q("What is backing?", "A backer offers ETH for a whole full batch. Several people can back the same batch. Only a backing at or above the depositors' price " +
      "can open the auction, and the best one becomes the opening bid. If nobody outbids it, the backer gets the Statement. Until the auction starts, a backing can be topped up or taken back any time."),
    q("What if someone backs too low?", "Nothing happens. A backing below the depositors' price can't start an auction, so it can't lock anyone's Credits or buy the batch. " +
      "If the depositors decide that offer is fair after all, the majority lowers its vote to it, and then it can open."),
    q("When do my Credits burn?", "Only when a sale is locked in, at the end of an auction that opened at or above the depositors' price. " +
      "The burn, delivery and payout happen in one transaction; if any part fails, everything is undone and the bidder is refunded."),
    q("Can I get my Credits back?", "Yes: any time while the batch fills, and while it's full as long as no auction is running. Taking Credits out of a full batch reopens it, " +
      "and backings made for the old set of Credits no longer count until their backer re-confirms them (one free click). Votes stay; a depositor who leaves entirely loses theirs. The deposit fee isn't refunded."),
  );
}

// ───────────────────────── batch model ─────────────────────────
// Everything the card, the drawer and the inbox need about one batch, from cached reads.
// ctx: the app's helpers (S, el, read, readFresh, send, eth, ethUsd, short, dur, now, toWei,
// confirmStep, toast, mosaicButton, bidHistory, bidList, whoDetails, PER).
async function load(ctx, b) {
  const { S, read, now } = ctx;
  const me = S.account;
  const [info, auction, best, minimum, backers, slots, pref, claimed, myBacking, opensAt] = await Promise.all([
    read("batchInfo", [b]), read("auctions", [b]), read("bestBacking", [b]), read("majorityMinimum", [b]),
    read("backersOf", [b]),
    me ? read("slots", [b, me]) : 0n, me ? read("reservePref", [b, me]) : 0n, me ? read("claimed", [b, me]) : false,
    me ? read("backings", [b, me]) : [0n, 0n], read("assemblyOpensAt"),
  ]);
  const [st, filled, depositors, statementId, proceeds, , nonce] = info;
  const state = BACKED_STATES[st];
  const [highBidder, highBid, auctionMin, endsAt] = auction;
  const [bestWho, bestAmt] = best;
  const [myBack, myBackNonce] = myBacking;
  let voted = 0n;
  if (state === "Filling" || state === "Full") {
    const addrs = await read("batchDepositors", [b]);
    const [counts, prefs] = await Promise.all([
      Promise.all(addrs.map((a) => read("slots", [b, a]))), Promise.all(addrs.map((a) => read("reservePref", [b, a]))),
    ]);
    voted = counts.reduce((t, n, i) => (prefs[i] ? t + n : t), 0n);
  }
  const m = {
    b, info, state, filled, depositors, statementId, proceeds, nonce, highBidder, highBid, auctionMin, endsAt,
    bestWho, bestAmt, minimum, backers, slots, pref, claimed, myBack, opensAt, voted,
    myStale: myBack > 0n && myBackNonce !== nonce,
    iLead: !!me && highBidder.toLowerCase() === me.toLowerCase(),
    iBestBacker: !!me && bestAmt > 0n && bestWho.toLowerCase() === me.toLowerCase(),
    canAct: !!me && !S.viewOnly,
  };
  m.ready = state === "Full" && minimum > 0n && bestAmt >= minimum;
  m.live = state === "Auction" && now() < endsAt;
  m.ended = state === "Auction" && !m.live;
  m.share = proceeds && slots ? (proceeds * slots) / 80n : 0n;
  // Where it is on the five-step rail: Fill → Price → Backer → Auction → Sold.
  m.step = state === "Filling" ? 0 : state === "Full" ? (!minimum ? 1 : !m.ready ? 2 : 3) : state === "Auction" ? 3 : 5;
  m.sig = JSON.stringify([info, auction, best, minimum, backers, slots, pref, claimed, myBacking, voted, m.live, now() >= opensAt, me, S.viewOnly],
    (_, v) => (typeof v === "bigint" ? v.toString() : v));
  return m;
}

const STEPS = ["Fill", "Price", "Backer", "Auction", "Sold"];
function rail(el, m) {
  return el("ol", { class: "brail", "aria-label": `Step ${Math.min(m.step + 1, 5)} of 5` }, ...STEPS.map((label, i) =>
    el("li", { class: i < m.step ? "done" : i === m.step ? "now" : "" }, el("i", {}), el("span", {}, label))));
}

// One short sentence: where the batch is and what it's waiting for.
function status(ctx, m) {
  const { el, eth, dur, now } = ctx;
  const who = (a) => (ctx.S.account && a.toLowerCase() === ctx.S.account.toLowerCase() ? "you" : nameOf(ctx, a));
  switch (m.state) {
    case "Filling": return `${m.filled}/80 Credits · ${80n - m.filled} to go`;
    case "Full":
      if (!m.minimum) return `Needs a price · ${m.voted}/80 slots voted, 41 needed`;
      if (!m.ready) return `Price ${eth(m.minimum)} · needs a backer at that price${m.bestAmt ? ` (best so far ${eth(m.bestAmt)})` : ""}`;
      return now() < m.opensAt ? `Backed at ${eth(m.bestAmt)} · auctions open in ${dur(m.opensAt - now())}`
        : `Backed at ${eth(m.bestAmt)} by ${who(m.bestWho)} · ready to start`;
    case "Auction":
      return m.live
        ? el("span", {}, `Live · ${m.iLead ? "you lead" : "high bid"} ${eth(m.highBid)} · ends in `, el("span", { "data-ends": String(m.endsAt) }, dur(m.endsAt - now())))
        : `Ended at ${eth(m.highBid)} · ready to settle`;
    case "Settled":
      if (!m.proceeds) return "Burned into a Statement for its sole holder";
      return `Sold for ${eth(m.proceeds)}${m.slots ? ` · your share ${eth(m.share)}${m.claimed ? ", collected" : ""}` : ""}`;
    default: return "";
  }
}
const nameOf = (ctx, a) => (ctx.S.store && a.toLowerCase() === ctx.S.store.toLowerCase() ? "the store treasury" : ctx.short(a));
const tagText = (m) => m.state === "Full" ? (!m.minimum ? "Needs a price" : m.ready ? "Ready" : "Needs a backer")
  : m.state === "Auction" ? (m.live ? "Live" : "Ended") : m.state === "Settled" ? "Sold" : "Filling";

// ───────────────────────── actions ─────────────────────────
function actions(ctx, m) {
  const { S, send, eth, toWei, confirmStep, toast } = ctx;
  const b = m.b;
  return {
    vote: (v) => {
      if (v == null) return toast("Enter a price in ETH, or 0 to clear your vote", true);
      send("Vote", "setReserve", [b, v]);
    },
    back: async (v) => {
      if (!v) return toast("Enter an amount in ETH", true);
      const total = m.myBack + v;
      if (total < 80n) return toast("A backing must be at least 80 wei", true);
      const ok = await confirmStep(`Back batch #${b} with ${eth(total, 6)}?`, [
        `${m.myBack ? `Adds ${eth(v, 6)} to your ${eth(m.myBack, 6)}. ` : ""}Your ETH is held by the pool as an offer for all 80 Credits.`,
        !m.minimum ? "The depositors haven't set a price yet: your backing waits, and counts once they set one at or below it."
          : total < m.minimum ? `That's below the depositors' price of ${eth(m.minimum, 6)}, so it can't open the auction unless they lower it.`
          : total > m.bestAmt ? "It meets the depositors' price and would be the opening bid." : `It meets the price; the best backing is ${eth(m.bestAmt, 6)}.`,
        "If it opens the auction and nobody outbids it, you get the Statement.",
        "Until the auction starts you can take it back any time.",
      ], "Back");
      if (ok) send(`Back #${b}`, "back", [b], v);
    },
    reconfirm: () => send(`Re-confirm #${b}`, "reconfirm", [b]),
    unback: () => send(`Take back #${b}`, "withdrawBacking", [b]),
    start: async () => {
      const ok = await confirmStep(`Start the auction for batch #${b}?`, [
        `Opening bid ${eth(m.bestAmt, 6)} (${nameOf(ctx, m.bestWho)}), at or above the depositors' price of ${eth(m.minimum, 6)}.`,
        "Runs 24 hours; anyone can bid higher (+5%), and bids in the last 15 minutes add 15 minutes.",
        "It sells to the highest bidder when it ends; only then do the 80 Credits burn. Depositors can't withdraw while it runs.",
      ], "Start auction");
      if (ok) send(`Start auction #${b}`, "startAuction", [b, m.bestAmt]);
    },
    bid: async (v, min) => {
      if (v == null) return toast("Enter a bid in ETH", true);
      if (v < min) return toast(`Minimum bid is ${eth(min, 6)}`, true);
      const net = v - (v * m.slots) / 80n;
      const ok = await confirmStep(`Bid ${eth(v, 6)} on batch #${b}?`, [
        "Your ETH is held by the pool. If someone outbids you, it comes back to collect.",
        "If yours is the highest bid when it ends, the 80 Credits burn into a Statement sent to you.",
        ...(m.slots ? [`You hold ${m.slots}/80 slots, so winning really costs you ${eth(net, 4)}.`] : []),
      ], "Place bid");
      if (ok) send(`Bid on #${b}`, "bid", [b], v);
    },
    settle: () => send(`Settle #${b}`, "settle", [b], undefined, undefined, undefined, FINALIZE_TX_GAS),
    claim: () => send(`Claim #${b}`, "claim", [b]),
    withdraw: async () => {
      const all = await ctx.readFresh("batchCredits", [b]);
      const owners = await Promise.all(all.map((id) => ctx.readFresh("depositorOf", [id])));
      const mine = all.filter((_, i) => owners[i].toLowerCase() === S.account.toLowerCase());
      if (m.state === "Full" && !(await confirmStep(`Withdraw your ${mine.length} from batch #${b}?`, [
        "The batch reopens and needs refilling before it can be auctioned.",
        "Backings were for these exact Credits: their backers re-confirm (free) before a start.",
        "Your vote goes if you take all your Credits; others' votes stay. The deposit fee isn't refunded.",
      ], "Withdraw"))) return;
      send(`Withdraw ${mine.length}`, "withdraw", [mine]);
    },
    redeem: async () => {
      if (await confirmStep(`Burn batch #${b} into your Statement?`, [
        "You hold all 80 slots: the Credits burn into one Statement, sent to your wallet. No auction, no fee.",
        "This can't be undone.",
      ], "Burn & take")) send(`Redeem #${b}`, "redeem", [b], undefined, undefined, undefined, FINALIZE_TX_GAS);
    },
    toWei,
  };
}

// The one thing that moves this batch forward for the person looking at it (or null).
async function primary(ctx, m) {
  const { el, eth, now } = ctx;
  const input = (ph, v = "") => el("input", { type: "number", step: "any", min: "0", placeholder: ph, value: v });
  if (!m.canAct) return null;
  const a = actions(ctx, m);
  const button = (label, fn, tip) => el("button", { class: "primary-btn", "data-tip": tip, onclick: fn }, label);
  const inline = (ph, val, label, fn, tip) => {
    const i = input(ph, val);
    return el("div", { class: "inline" }, i, el("button", { class: "primary-btn", "data-tip": tip, onclick: () => fn(a.toWei(i.value)) }, label));
  };
  switch (m.state) {
    case "Full":
      if (!m.minimum) return m.slots && !m.pref ? inline("Your price (ETH)", "", "Vote", a.vote, "vote") : null;
      if (!m.ready) {
        if (m.myStale) return button(`Re-confirm my ${eth(m.myBack)}`, a.reconfirm, "reconfirm");
        const need = m.minimum - m.myBack;
        return button(m.myBack ? `Top up to ${eth(m.minimum)}` : `Back at ${eth(m.minimum)}`, () => a.back(need), "back");
      }
      return now() >= m.opensAt ? button("Start auction", a.start, "startBacked") : null;
    case "Auction":
      if (m.ended) return button(`Settle · sell for ${eth(m.highBid)}`, a.settle, "settleBacked");
      if (m.iLead) return null;
      { const min = await ctx.readFresh("minNextBid", [m.b]);
        return inline("Bid (ETH)", formatEther(min), "Bid", (v) => a.bid(v, min), "bid"); }
    case "Settled":
      return m.slots && m.proceeds && !m.claimed ? button(`Claim ${eth(m.share)}`, a.claim, "claim") : null;
    default: return null;
  }
}

// ───────────────────────── compact card ─────────────────────────
export async function backedCard(ctx, b, mineOnly) {
  const { S, el } = ctx;
  const m = await load(ctx, b);
  if (mineOnly && !m.slots && !m.myBack && !m.iLead) return null;
  const key = `${mineOnly ? "mine" : "all"}:${b}`;
  const cached = S.cards.get(key);
  if (cached && cached.sig === m.sig) return cached.el;
  const meta = [`${m.filled}/80`, `${m.depositors} depositor${m.depositors === 1n ? "" : "s"}`];
  if (m.slots) meta.push(`you: ${m.slots}`);
  if (m.myBack) meta.push(`your backing ${ctx.eth(m.myBack)}`);
  const card = el("article", { class: `bcard s-${m.state.toLowerCase()}${m.state === "Full" && !m.ready ? " waiting" : ""}`, tabindex: "0", "aria-label": `Batch #${b}, ${tagText(m)}` },
    el("header", {}, el("b", {}, `Batch #${b}`), el("span", { class: "btag" }, tagText(m))),
    rail(el, m),
    el("p", { class: "bstatus" }, status(ctx, m)),
    await primary(ctx, m),
    el("footer", {}, el("span", {}, meta.join(" · ")), el("button", { class: "more", onclick: () => openDrawer(ctx, b) }, "Details →")),
  );
  card.addEventListener("click", (e) => { if (!e.target.closest("button, input, a, summary")) openDrawer(ctx, b); });
  card.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.target === card) openDrawer(ctx, b); });
  S.cards.set(key, { sig: m.sig, el: card });
  return card;
}

// ───────────────────────── detail drawer ─────────────────────────
export async function openDrawer(ctx, b) {
  ctx.S.drawerB = b;
  const dlg = document.getElementById("drawer");
  if (!dlg.open) dlg.showModal();
  await renderDrawer(ctx);
}
export async function refreshDrawer(ctx) {
  const dlg = document.getElementById("drawer");
  if (dlg?.open && ctx.S.drawerB != null) await renderDrawer(ctx);
}
async function renderDrawer(ctx) {
  const { S, el, eth, ethUsd } = ctx;
  const b = S.drawerB;
  const m = await load(ctx, b);
  const a = actions(ctx, m);
  const body = document.getElementById("drawer-body");
  const scroll = body.scrollTop;
  const input = (ph, v = "") => el("input", { type: "number", step: "any", min: "0", placeholder: ph, value: v });
  const sec = (title, ...kids) => el("section", { class: "dsec" }, el("h3", {}, title), ...kids);
  const row = (k, v) => el("div", { class: "drow" }, el("span", {}, k), el("b", {}, v));
  const ghost = (label, fn, tip) => el("button", { class: "ghost", "data-tip": tip, onclick: fn }, label);
  const parts = [];

  // Price
  if (m.state === "Filling" || m.state === "Full") {
    const p = [row("Depositors' price", m.minimum ? ethUsd(m.minimum) : "not set"), row("Voted", `${m.voted} of 80 slots · 41 needed`)];
    if (m.slots) {
      p.push(row("Your vote", m.pref ? ethUsd(m.pref) : "not voted"));
      if (m.canAct && m.pref) { const i = input("Your price (ETH)", formatEther(m.pref)); // first vote lives in the header
        p.push(el("div", { class: "inline" }, i, ghost(m.pref ? "Change vote" : "Vote", () => a.vote(a.toWei(i.value)), "vote"))); }
    }
    p.push(el("p", { class: "hint" }, "The price is the lowest price more than 40 of the 80 slots accept. No auction starts without it, and only a backing at or above it can open one."));
    parts.push(sec("Price", ...p));

    // Backing
    const list = m.backers[0].map((w, i) => ({ who: w, amt: m.backers[1][i], ok: m.backers[2][i] })).sort((x, y) => (y.amt > x.amt ? 1 : -1));
    const bk = [row("Best backing", m.bestAmt ? `${ethUsd(m.bestAmt)} · ${nameOf(ctx, m.bestWho)}` : "none")];
    if (list.length) bk.push(el("ol", { class: "backers" }, ...list.map((x) => el("li", { class: x.ok && (!m.minimum || x.amt >= m.minimum) ? "" : "stale" },
      el("span", {}, S.account && x.who.toLowerCase() === S.account.toLowerCase() ? "you" : nameOf(ctx, x.who)),
      el("span", {}, eth(x.amt), !x.ok ? " · needs re-confirming" : m.minimum && x.amt < m.minimum ? " · below price" : "")))));
    if (m.canAct) {
      const target = m.minimum && m.minimum > m.myBack ? m.minimum - m.myBack : 0n;
      const i = input(m.myBack ? "Add (ETH)" : "Amount (ETH)", target ? formatEther(target) : "");
      bk.push(el("div", { class: "inline" }, i, ghost(m.myBack ? "Add" : "Back", () => a.back(a.toWei(i.value)), "back")));
      if (m.myStale) bk.push(ghost(`Re-confirm my ${eth(m.myBack)} (free)`, a.reconfirm, "reconfirm"));
      if (m.myBack) bk.push(ghost(`Take back my ${eth(m.myBack)}`, a.unback, "unback"));
    }
    parts.push(sec("Backing", ...bk));
  }

  // Auction
  if (m.state === "Auction" || (m.state === "Settled" && m.proceeds)) {
    const au = m.state === "Auction"
      ? [row("Depositors' price", ethUsd(m.auctionMin)), row("High bid", `${ethUsd(m.highBid)} · ${m.iLead ? "you" : nameOf(ctx, m.highBidder)}`),
         row("Ends", el("span", { "data-ends": String(m.endsAt) }, ctx.dur(m.endsAt - ctx.now())))]
      : [row("Sold for", ethUsd(m.proceeds)), row("Statement", `#${m.statementId}`)];
    const bids = await ctx.bidHistory(b);
    if (bids?.length) au.push(ctx.bidList(bids, m.highBidder, S.account));
    parts.push(sec(m.state === "Auction" ? "Auction" : "Sale", ...au));
  }

  // You
  if (m.slots) {
    const y = [row("Your slots", `${m.slots} of 80 · ${((Number(m.slots) / 80) * 100).toFixed(1)}%`)];
    if (m.state === "Settled" && m.proceeds) y.push(row("Your share", `${ethUsd(m.share)}${m.claimed ? " · collected" : ""}`));
    if (m.canAct && (m.state === "Filling" || m.state === "Full")) y.push(ghost(`Withdraw my ${m.slots}`, a.withdraw, "withdrawBacked"));
    if (m.canAct && m.state === "Full" && m.slots === 80n) y.push(ghost("Burn into my Statement", a.redeem, "redeemBacked"));
    parts.push(sec("You", ...y));
  }

  // The Credits + who
  parts.push(sec(m.state === "Settled" ? `Statement #${m.statementId}` : "The 80 Credits", ctx.mosaicButton(b, m.statementId, m.state)));
  const who = ctx.whoDetails(b, m.depositors);
  if (who) parts.push(sec("Depositors", who));

  document.getElementById("drawer-title").replaceChildren(`Batch #${b} `, el("span", { class: "btag" }, tagText(m)));
  body.replaceChildren(
    el("div", { class: `dhead s-${m.state.toLowerCase()}` }, rail(el, m), el("p", { class: "bstatus" }, status(ctx, m)), await primary(ctx, m)),
    ...parts,
  );
  body.scrollTop = scroll;
}

// ───────────────────────── inbox ─────────────────────────
// Everything waiting on this wallet, one row each, with the one button that does it.
export async function renderInbox(ctx, ids) {
  const { S, el, eth, read, send } = ctx;
  const box = document.getElementById("inbox");
  if (!box || !S.account) return;
  const models = await Promise.all(ids.map((b) => load(ctx, b)));
  const rows = [];
  const go = (label, fn) => el("button", { class: "primary-btn", onclick: fn }, label);
  const open = (b) => go("Open", () => openDrawer(ctx, b));
  for (const m of models) {
    const a = actions(ctx, m);
    if (m.state === "Full" && !m.minimum && m.slots && !m.pref)
      rows.push([`Vote a price on #${m.b}`, `${m.voted}/80 slots voted${m.voted + m.slots >= 41n ? " · your vote makes the majority" : ", 41 needed"}`, open(m.b)]);
    if (m.state === "Full" && m.myStale)
      rows.push([`Re-confirm your backing on #${m.b}`, "The Credits changed since you backed; it's free", go("Re-confirm", a.reconfirm)]);
    else if (m.state === "Full" && m.minimum && m.myBack && m.myBack < m.minimum)
      rows.push([`Your backing on #${m.b} is below the price`, `${eth(m.myBack)} vs ${eth(m.minimum)}: top up or take it back`, open(m.b)]);
    if (m.ready && (m.slots || m.iBestBacker) && ctx.now() >= m.opensAt)
      rows.push([`Start #${m.b}`, `Backed at ${eth(m.bestAmt)}, at the depositors' price`, go("Start auction", a.start)]);
    if (m.ended && (m.slots || m.iLead))
      rows.push([`Settle #${m.b}`, `Ended at ${eth(m.highBid)}${m.iLead ? ": you won" : ""}`, go("Settle", a.settle)]);
  }
  // Collect: sale shares + refunds (outbid bids, taken-back backings, excess fees).
  const shares = models.filter((m) => m.state === "Settled" && m.slots && m.proceeds && !m.claimed);
  const refund = await read("pendingReturns", [S.account]);
  const total = shares.reduce((t, m) => t + m.share, refund);
  if (total) rows.unshift([`Collect ${eth(total)}`,
    [...shares.map((m) => `#${m.b} sale ${eth(m.share)}`), ...(refund ? [`refunds ${eth(refund)}`] : [])].join(" · "),
    go("Collect", async () => {
      for (const m of shares) if (!(await send(`Claim #${m.b}`, "claim", [m.b]))) return;
      if (refund) await send("Refund", "withdrawRefund");
    })]);
  box.hidden = false;
  document.getElementById("inbox-list").replaceChildren(...(rows.length
    ? rows.map(([t, d, btn]) => el("li", {}, el("div", {}, el("b", {}, t), el("span", {}, d)), btn))
    : [el("li", { class: "empty" }, el("div", {}, el("b", {}, "Nothing needs you right now"), el("span", {}, "Your batches are below.")))]));
  document.getElementById("inbox-count").textContent = rows.length ? String(rows.length) : "";
}

// ───────────────────────── treasury (owner only) ─────────────────────────
export async function renderTreasury(ctx) {
  const { S, el, eth, read } = ctx;
  const sec = document.getElementById("treasury-section");
  if (!sec) return;
  sec.hidden = !S.treasuryOwner;
  if (!S.treasuryOwner) return;
  const full = (S.byState ?? []).filter(([, st]) => st === "Full").map(([b]) => b);
  const [bal, cap] = await Promise.all([read("treasuryBalance", [], S.store, TREASURY_ABI), read("maxTreasuryBid", [], S.store, TREASURY_ABI)]);
  document.getElementById("treasury-meta").textContent = `holds ${eth(bal)} · cap ${eth(cap)} per batch · owner only`;
  const rows = await Promise.all(full.map(async (b) => {
    const [minimum, [, best], [depositors], [mine]] = await Promise.all([read("majorityMinimum", [b]), read("bestBacking", [b]),
      read("batchInfo", [b]).then((i) => [i[2]]), read("backings", [b, S.store])]);
    if (depositors < 2n) return null;
    // Only what the owner can act on: priced batches still waiting for a backer, and the treasury's own backings.
    if (!mine && (!minimum || best >= minimum)) return null;
    return el("div", { class: "trow" },
      el("div", { class: "trow-head" }, el("b", {}, `#${b}`),
        el("span", {}, minimum ? `price ${eth(minimum)} · ${best >= minimum ? `backed ${eth(best)}` : best ? `best ${eth(best)}, below` : "no backer"}` : "no price yet")),
      await treasuryControl(ctx, b, minimum));
  }));
  document.getElementById("treasury-list").replaceChildren(...(rows.filter(Boolean).length ? rows.filter(Boolean)
    : [el("p", { class: "muted" }, "Nothing to back right now: no priced batch is waiting for a backer.")]));
}

// Owner-only: back one batch from the store treasury. One line of numbers, one action.
// The contract re-checks every limit.
async function treasuryControl(ctx, b, minimum) {
  const { S, el, read, send, eth, toWei, confirmStep, toast } = ctx;
  const [[current, curNonce], cap, bal, info] = await Promise.all([
    read("backings", [b, S.store]), read("maxTreasuryBid", [], S.store, TREASURY_ABI), read("treasuryBalance", [], S.store, TREASURY_ABI), read("batchInfo", [b]),
  ]);
  if (!minimum) return el("p", { class: "tline" }, "Waits for the depositors' price");
  const limit = minimum < cap ? minimum : cap;
  const room = limit > current ? limit - current : 0n;
  const btn = (label, fn, cls = "") => el("button", { class: cls, onclick: fn }, label);
  const box = el("div", { class: "tctl" },
    el("p", { class: "tline" }, current ? `Treasury backing ${eth(current)} of ${eth(limit)}` : `Up to ${eth(limit)}${minimum < cap ? " (the price)" : " (the cap)"}`));
  if (room) {
    const i = el("input", { type: "number", step: "any", min: "0", "aria-label": "Treasury amount (ETH)", value: formatEther(room < bal ? room : bal) });
    box.append(el("div", { class: "inline" }, i, btn("Back", async () => {
      const v = toWei(i.value);
      if (!v) return toast("Enter an amount in ETH", true);
      const total = current + v;
      if (total > limit) return toast(`The treasury can back at most ${eth(limit, 6)} here`, true);
      const ok = await confirmStep(`Back batch #${b} from the treasury?`, [
        `Moves ${eth(v, 6)} of treasury ETH into the pool (total ${eth(total, 6)}).`,
        total === minimum ? "That's the depositors' price, so it can open the auction." : `Below the price of ${eth(minimum, 6)}, it can't open the auction yet.`,
        "If nobody outbids it, the Statement comes to the store for SCREDIT. Outbid or unwound, the ETH comes back.",
      ], "Back from treasury");
      if (ok) send(`Treasury backs #${b}`, "backBatch", [b, v, total], undefined, S.store, TREASURY_ABI);
    }, "treasury-btn")));
  }
  const acts = el("div", { class: "row" });
  if (current && curNonce !== info[6] && current <= minimum) acts.append(btn("Re-confirm (Credits changed)", () => send(`Treasury re-confirms #${b}`, "reconfirmBatch", [b], undefined, S.store, TREASURY_ABI)));
  if (current) acts.append(btn(`Return ${eth(current)}`, () => send(`Treasury unbacks #${b}`, "unbackBatch", [b], undefined, S.store, TREASURY_ABI), "ghost"));
  if (acts.childElementCount) box.append(acts);
  // The price rule is checked when the treasury backs (store audit Info-1): warn if it dropped since.
  if (current && current > minimum) box.append(el("p", { class: "tline warn" }, `The price dropped to ${eth(minimum)}, below this backing. Return it and back again if you don't want to pay more than they ask.`));
  return box;
}

