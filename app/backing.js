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
  "function auctions(uint256) view returns (address highBidder, uint256 highBid, uint256 minimum, uint64 endsAt, address backer, uint256 backing)",
  "function acceptTally(uint256, uint64) view returns (uint256)",
  "function accepted(uint256, uint64, address) view returns (bool)",
  "function cooldownUntil(uint256) view returns (uint64)",
  "function unsold(uint256) view returns (bool)",
  "function votedMedian(uint256) view returns (uint256)",
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
  "function startAuction(uint256 batchId)",
  "function acceptBacking(uint256 batchId, uint64 round, address backer, uint256 amount)",
  "function expire(uint256 batchId)",
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
  "error NoMinimum()", "error Cooldown()", "error BidInstead()", "error OfferChanged()", "error NotUnsold()", "error PriceMoved()",
  "error PivotalMinority()", "error NotYet()", "error NeedMoreGas()", "error TooMany()",
]);

// Contract enum → the names the rest of the site uses ("Settled" = sold and delivered).
// The store's treasury side (BackedStore): owner-only backing within a per-batch cap.
export const TREASURY_ABI = parseAbi([
  "function owner() view returns (address)",
  "function treasuryBalance() view returns (uint256)",
  "function maxTreasuryBid() view returns (uint256)",
  "function buyUnsold(uint256 batchId, uint256 expectedPrice)",
  "function collectRefund()",
  "error PriceMoved()", "error OverCap()",
]);

const STATEMENT_OWNER_ABI = parseAbi(["function ownerOf(uint256) view returns (address)"]);
// A bid prefill people can read: the minimum rounded UP to 4 significant digits (never below it).
const roundUp = (wei) => { const len = wei.toString().length; if (len <= 4) return wei; const u = 10n ** BigInt(len - 4); return ((wei + u - 1n) / u) * u; };

export const BACKED_STATES = ["Filling", "Full", "Auction", "Decide", "Settled"];
const LABEL = { Filling: "Filling", Auction: "Auction", Settled: "Sold" };
// A full batch's tag says what it's waiting for: a price, a backer at that price, or someone to press Start.
export const stateLabel = (s, minimum, bestAmt) => s !== "Full" ? LABEL[s] ?? s
  : !minimum ? "Needs a price" : bestAmt >= minimum ? "Ready to auction" : "Needs a backer";

export const BACKED_FILTERS = [
  ["all", "All", () => true],
  ["filling", "Filling", (s) => s === "Filling"],
  ["ready", "Pricing & backing", (s) => s === "Full"],
  ["auction", "Live auctions", (s) => s === "Auction"],
  ["decide", "Holders deciding", (s) => s === "Decide"],
  ["sold", "Sold", (s) => s === "Settled"],
];

// A sale burns 80 Credits and awards points inside one all-or-nothing call that needs 12M gas
// available; the pool refuses to start it with less. Give those transactions room under the 16.7M cap.
export const FINALIZE_TX_GAS = 14_000_000n;

export const BACKED_TIPS = {
  back: "Offer ETH for the whole batch, any amount. At or above the price when the auction starts, the best backing opens it as the first bid. " +
    "During the auction, offers stay below the price; if nobody bids, the best offer is what the holders vote on.",
  reconfirm: "Confirms your backing for the batch's current Credits, without adding ETH. Needed after the Credits change (including a backing posted while it filled).",
  unback: "Takes your backing back to collect. Not while an auction runs (offers are binding until it's settled), and not once it's the opening bid or the offer being voted on.",
  vote: "The lowest price you'd accept for the whole batch. The depositors' price is the lowest price more than 40 of the 80 slots accept: the auction's reserve. Enter 0 to clear your vote.",
  startBacked: "Depositors only, once there's a price; no backing needed. A backing at or above the price opens it as the first bid. Nothing burns until it sells.",
  bid: "Your ETH is held by the pool. The first bid must meet the depositors' price; after that +5% each. Outbid ETH comes back to collect. Bids in the final 15 minutes add 15 minutes.",
  settleBacked: "Ends the auction. A bid at the price buys it; with no bid, the backer buys it if their offer meets the price, otherwise holders get 24 hours to decide. Anyone can press it.",
  accept: "Accept the backer's exact offer. When more than 40 of the 80 slots accept, it sells to the backer in the same transaction and the sale is split by slots.",
  expire: "The holders' window closed without a majority: the backer is refunded, nothing burns, and the batch rests 24 hours (holders can leave; the store may buy it at the price).",
  withdrawBacked: "Take your Credits back to your wallet. Possible while the batch fills, and while it's full as long as no auction or holders' decision is running.",
  redeemBacked: "You hold all 80 slots: burn them into a Statement straight to your wallet. No auction, no fee.",
  treasuryBuy: "Owner only. Buys this unsold batch for the store at exactly the depositors' price, which must also be the median of their votes. Capped per purchase; raising the cap takes 3 days.",
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
      ["Auction", "A depositor starts it: 24 hours, reserve = the price. A bid at the price sells it."],
      ["Back", "Anyone offers ETH for the batch, any amount, before or during the auction."],
      ["Decide", "No bid? Holders vote on the best offer (41 of 80), or it's refunded and nothing burns."],
    ].map(([b, s]) => el("li", {}, el("b", {}, b), el("span", {}, s))),
  );
  const lead = document.querySelector(".intro p");
  if (lead) lead.textContent = "Pool your Credits with other holders. Nothing burns until a buyer is locked in: depositors set the price and start a 24-hour auction at it, " +
    "while backers can make offers for the whole batch. If nobody bids, the holders decide whether to take the best offer. The 80 Credits burn into a Statement only when it sells, and the sale is split by how many Credits each person put in.";
  for (const d of document.querySelectorAll("[data-mode='burn-first']")) d.remove();
  const gb = document.getElementById("gallery-blurb");
  if (gb) gb.textContent = "Every Statement the pool has sold. Each was burned from 80 Credits the moment its sale locked in; click one to see them.";
  const safe = [...document.querySelectorAll(".safety li")].find((li) => li.textContent.startsWith("During assembly"));
  if (safe) safe.textContent = "Nothing burns until a sale is locked in. The burn, the delivery to the buyer and the payout happen in one all-or-nothing step: if any part fails, it's all undone and the buyer is refunded. Jack's Statements contract can only reach the 80 Credits being sold.";
  const sb = document.getElementById("store-blurb");
  if (sb) sb.textContent = "Statements the store treasury bought, auctioned for SCREDIT only (never ETH). The treasury (75% of deposit fees) only buys batches whose round ended unsold, " +
    "at exactly the depositors' price, capped per purchase. Every SCREDIT bid also pays a small platform fee in ETH.";
  const faq = document.getElementById("faq");
  const q = (sum, text) => el("details", {}, el("summary", {}, sum), el("p", {}, text));
  faq?.querySelector("h2")?.after(
    q("How is the price set?", "Depositors vote the lowest price they'd accept. The batch's price is the lowest price that more than 40 of the 80 slots accept, " +
      "so a small group can't sell it cheap. It's the auction's reserve: the first bid must meet it."),
    q("What is backing?", "An offer for the whole batch, any amount, from anyone (often a whale), before or during the auction. Several people can back. " +
      "A backing at or above the price when the auction starts is its opening bid, so every bid must beat it. During the auction, offers stay below the price. " +
      "A backing can be taken back before an auction starts, or after it's settled; while an auction runs, offers are binding."),
    q("What happens if nobody bids?", "The holders get 24 hours to vote on the best offer: when more than 40 of the 80 slots accept, it sells to that backer. " +
      "Otherwise (or with no offer at all) the backer is refunded, nothing burns, and the batch rests: 24 hours, doubling each round in a row that doesn't sell. " +
      "Holders can take their Credits back during the rest, and the store treasury may buy it at exactly the depositors' price."),
    q("Can a backer or a low offer lock my Credits?", "No. Only depositors can start an auction, and only once the majority has set a price. Backers can't start anything, and anyone can beat a low offer with a better one."),
    q("When do my Credits burn?", "Only when a sale is locked in: a winning bid, an offer the majority accepted, or the store buying at the price. " +
      "The burn, delivery and payout happen in one transaction; if any part fails, everything is undone and the buyer is refunded."),
    q("Can I get my Credits back?", "Yes: any time while the batch fills, and while it's full as long as no auction or holders' decision is running. The 24-hour rest after an unsold round is a window to leave. " +
      "Taking Credits out of a full batch reopens it, and backings for the old set of Credits must be re-confirmed (free). The deposit fee isn't refunded."),
  );
}

// ───────────────────────── batch model ─────────────────────────
// Everything the card, the drawer and the inbox need about one batch, from cached reads.
// ctx: the app's helpers (S, el, read, readFresh, send, eth, ethUsd, short, dur, now, toWei,
// confirmStep, toast, mosaicButton, bidHistory, bidList, whoDetails, PER).
async function load(ctx, b) {
  const { S, read, now } = ctx;
  const me = S.account;
  const [info, auction, best, minimum, backers, slots, pref, claimed, myBacking, opensAt, cooldown, unsold] = await Promise.all([
    read("batchInfo", [b]), read("auctions", [b]), read("bestBacking", [b]), read("majorityMinimum", [b]),
    read("backersOf", [b]),
    me ? read("slots", [b, me]) : 0n, me ? read("reservePref", [b, me]) : 0n, me ? read("claimed", [b, me]) : false,
    me ? read("backings", [b, me]) : [0n, 0n], read("assemblyOpensAt"), read("cooldownUntil", [b]), read("unsold", [b]),
  ]);
  const [st, filled, depositors, statementId, proceeds, round, nonce] = info;
  const state = BACKED_STATES[st];
  const [highBidder, highBid, auctionMin, endsAt, backer, backing] = auction;
  const [bestWho, bestAmt] = best;
  const [myBack, myBackNonce] = myBacking;
  const meL = me?.toLowerCase();
  let voted = 0n;
  if (state === "Filling" || state === "Full") {
    const addrs = await read("batchDepositors", [b]);
    const [counts, prefs] = await Promise.all([
      Promise.all(addrs.map((a) => read("slots", [b, a]))), Promise.all(addrs.map((a) => read("reservePref", [b, a]))),
    ]);
    voted = counts.reduce((t, n, i) => (prefs[i] ? t + n : t), 0n);
  }
  const [tally, iAccepted] = state === "Decide" ? await Promise.all([read("acceptTally", [b, round]), me ? read("accepted", [b, round, me]) : false]) : [0n, false];
  const owner = state === "Settled" && me ? await read("ownerOf", [statementId], S.statements, STATEMENT_OWNER_ABI).catch(() => null) : null;
  const m = {
    b, info, state, filled, depositors, statementId, proceeds, round, nonce, highBidder, highBid, auctionMin, endsAt, backer, backing,
    bestWho, bestAmt, minimum, backers, slots, pref, claimed, myBack, opensAt, voted, cooldown, unsold, tally, iAccepted,
    myStale: myBack > 0n && myBackNonce !== nonce,
    iLead: !!me && highBidder.toLowerCase() === meL,
    iBacker: !!me && backing > 0n && backer.toLowerCase() === meL,
    iWon: !!owner && owner.toLowerCase() === meL,
    hasBid: highBidder !== "0x0000000000000000000000000000000000000000",
    canAct: !!me && !S.viewOnly,
  };
  m.cooling = state === "Full" && now() < cooldown;
  m.ready = state === "Full" && minimum > 0n && !m.cooling && now() >= opensAt; // no backing needed
  m.opensWithBacking = m.ready && bestAmt >= minimum;                             // it would be the opening bid
  m.live = (state === "Auction" || state === "Decide") && now() < endsAt;
  m.ended = state === "Auction" && !m.live;
  m.windowOver = state === "Decide" && !m.live;
  m.share = proceeds && slots ? (proceeds * slots) / 80n : 0n;
  // Fill → Price → Auction (incl. the holders' decision) → Sold.
  m.step = state === "Filling" ? 0 : state === "Full" ? (!minimum ? 1 : 2) : state === "Settled" ? 4 : 2;
  m.sig = JSON.stringify([info, auction, best, minimum, backers, slots, pref, claimed, myBacking, voted, m.live, now() >= opensAt, m.cooling,
    unsold, tally, iAccepted, me, S.viewOnly, m.iWon], (_, v) => (typeof v === "bigint" ? v.toString() : v));
  return m;
}

const STEPS = ["Fill", "Price", "Auction", "Sold"];
function rail(el, m) {
  return el("ol", { class: "brail", "aria-label": `Step ${Math.min(m.step + 1, 4)} of 4` }, ...STEPS.map((label, i) =>
    el("li", { class: i < m.step ? "done" : i === m.step ? "now" : "" }, el("i", {}), el("span", {}, i === 2 && m.state === "Decide" ? "Decide" : label))));
}
const nameOf = (ctx, a) => (ctx.S.store && a.toLowerCase() === ctx.S.store.toLowerCase() ? "the store treasury" : ctx.short(a));
const tagText = (m) => m.state === "Full" ? (!m.minimum ? "Needs a price" : m.cooling ? "Resting" : "Ready")
  : m.state === "Auction" ? (m.live ? "Live" : "Ended") : m.state === "Decide" ? (m.live ? "Holders decide" : "Window closed")
  : m.state === "Settled" ? "Sold" : "Filling";

// One short sentence: where the batch is and what it's waiting for.
function status(ctx, m) {
  const { el, eth, dur, now } = ctx;
  const who = (a) => (ctx.S.account && a.toLowerCase() === ctx.S.account.toLowerCase() ? "you" : nameOf(ctx, a));
  const ends = (pre, post = "") => el("span", {}, pre, el("span", { "data-ends": String(m.endsAt) }, dur(m.endsAt - now())), post);
  switch (m.state) {
    case "Filling": return `${m.filled}/80 Credits · ${80n - m.filled} to go`;
    case "Full":
      if (!m.minimum) return `Needs a price · ${m.voted}/80 slots voted, 41 needed`;
      if (m.cooling) return el("span", {}, `Unsold last round · resting, restart in `, el("span", { "data-ends": String(m.cooldown) }, dur(m.cooldown - now())));
      if (now() < m.opensAt) return `Price ${eth(m.minimum)} · auctions open in ${dur(m.opensAt - now())}`;
      return `Price ${eth(m.minimum)} · ${m.bestAmt >= m.minimum ? `${who(m.bestWho)}'s ${eth(m.bestAmt)} would open it`
        : m.bestAmt ? `best offer ${eth(m.bestAmt)}` : "no offers yet"} · a depositor can start`;
    case "Auction":
      if (!m.live) return m.hasBid ? `Ended at ${eth(m.highBid)} · ready to settle`
        : m.bestAmt ? `No bid at ${eth(m.auctionMin)} · settle to let holders decide on the best offer, ${eth(m.bestAmt)}`
        : "No bid and no offer · settle to end it unsold";
      return m.hasBid ? ends(`Live · ${m.iLead ? "you lead" : "high bid"} ${eth(m.highBid)} · ends in `)
        : ends(`Live · reserve ${eth(m.auctionMin)}, no bid yet${m.bestAmt ? ` · best offer ${eth(m.bestAmt)}` : ""} · ends in `);
    case "Decide":
      return m.live ? ends(`No bid · take ${who(m.backer)}'s ${eth(m.backing)}? ${m.tally}/80 accepted, 41 sells · `, " left")
        : "The holders' window closed without a majority · close it to refund the backer";
    case "Settled":
      if (!m.proceeds) return "Burned into a Statement for its sole holder";
      if (m.iWon && !m.slots) return `You won it for ${eth(m.proceeds)} · Statement #${m.statementId} is in your wallet`;
      return `Sold for ${eth(m.proceeds)}${m.slots ? ` · your share ${eth(m.share)}${m.claimed ? ", collected" : ""}` : ""}`;
    default: return "";
  }
}

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
        `${m.myBack ? `Adds ${eth(v, 6)} to your ${eth(m.myBack, 6)}. ` : ""}Your ETH is held by the pool as a standing offer for all 80 Credits.`,
        m.state === "Auction" ? "During the auction an offer must stay below the depositors' price (at the price, bid instead). If nobody bids, the best offer is what the holders vote on."
          : m.minimum && total >= m.minimum ? `It meets the depositors' price (${eth(m.minimum, 6)}): if it's the best when the auction starts, it's the opening bid, and every bid must beat it.`
          : "If nobody bids at the depositors' price, the best offer when the auction ends is what the holders vote on.",
        total > m.bestAmt ? "It would be the best offer right now." : `The best offer is ${eth(m.bestAmt, 6)}.`,
        m.state === "Auction" ? "Offers are binding while the auction runs: you can take it back after it's settled, unless it's the offer the holders vote on."
          : "You can take it back any time before an auction starts. Once one runs, offers are binding until it's settled.",
      ], "Back");
      if (ok) send(`Back #${b}`, "back", [b], v);
    },
    reconfirm: () => send(`Re-confirm #${b}`, "reconfirm", [b]),
    unback: () => send(`Take back #${b}`, "withdrawBacking", [b]),
    start: async () => {
      const ok = await confirmStep(`Start the auction for batch #${b}?`, [
        `Reserve: ${eth(m.minimum, 6)}, the depositors' price.`,
        m.bestAmt >= m.minimum ? `${nameOf(ctx, m.bestWho)}'s ${eth(m.bestAmt, 6)} opens it as the first bid; every bid must beat it by 5%.`
          : "The first bid must meet the reserve. Backers can keep making offers below it during the auction.",
        "With no bid: the holders vote on the best offer for 24 hours, or with no offer it ends unsold and rests.",
        "Runs 24 hours. Nothing burns until it sells. Depositors can't withdraw while it runs.",
      ], "Start auction");
      if (ok) send(`Start auction #${b}`, "startAuction", [b]);
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
    accept: async () => {
      const after = m.tally + m.slots;
      const ok = await confirmStep(`Take ${eth(m.backing, 6)} for batch #${b}?`, [
        `You accept exactly this offer from ${nameOf(ctx, m.backer)}; if it changed, your acceptance is refused.`,
        `Your ${m.slots} slot${m.slots > 1n ? "s" : ""} count toward the 41 needed. ${after >= 41n ? "This makes the majority: it sells in this transaction." : `After you, ${41n - after} more needed.`}`,
        `If it sells, your share is ${eth((m.backing * m.slots) / 80n, 6)}. You can't take an acceptance back.`,
      ], "Accept");
      if (ok) send(`Accept #${b}`, "acceptBacking", [b, m.round, m.backer, m.backing], undefined, undefined, undefined, FINALIZE_TX_GAS);
    },
    expire: () => send(`Close #${b}`, "expire", [b]),
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
  const { el, eth } = ctx;
  if (!m.canAct) return null;
  const a = actions(ctx, m);
  const input = (ph, v = "") => el("input", { type: "number", step: "any", min: "0", placeholder: ph, value: v });
  const button = (label, fn, tip) => el("button", { class: "primary-btn", "data-tip": tip, onclick: fn }, label);
  const inline = (ph, val, label, fn, tip) => {
    const i = input(ph, val);
    return el("div", { class: "inline" }, i, el("button", { class: "primary-btn", "data-tip": tip, onclick: () => fn(a.toWei(i.value)) }, label));
  };
  switch (m.state) {
    case "Full":
      if (!m.minimum) return m.slots && !m.pref ? inline("Your price (ETH)", "", "Vote", a.vote, "vote") : null;
      if (m.myStale) return button(`Re-confirm my ${eth(m.myBack)}`, a.reconfirm, "reconfirm");
      if (m.ready && m.slots) return button("Start auction", a.start, "startBacked");
      return m.slots ? null : inline("Offer (ETH)", "", "Back", a.back, "back");
    case "Auction":
      if (m.ended) return button("Settle", a.settle, "settleBacked");
      if (m.iLead) return null;
      { const min = await ctx.readFresh("minNextBid", [m.b]);
        return inline("Bid (ETH)", formatEther(roundUp(min)), "Bid", (v) => a.bid(v, min), "bid"); }
    case "Decide":
      if (m.windowOver) return button("Close: refund the backer", a.expire, "expire");
      return m.slots && !m.iAccepted ? button(`Accept ${eth(m.backing)}`, a.accept, "accept") : null;
    case "Settled":
      return m.slots && m.proceeds && !m.claimed ? button(`Claim ${eth(m.share)}`, a.claim, "claim") : null;
    default: return null;
  }
}

// ───────────────────────── compact card ─────────────────────────
export async function backedCard(ctx, b, mineOnly) {
  const { S, el } = ctx;
  const m = await load(ctx, b);
  if (mineOnly && !m.slots && !m.myBack && !m.iLead && !m.iBacker && !m.iWon) return null;
  const key = `${mineOnly ? "mine" : "all"}:${b}`;
  const cached = S.cards.get(key);
  if (cached && cached.sig === m.sig) return cached.el;
  const meta = [`${m.filled}/80`, `${m.depositors} depositor${m.depositors === 1n ? "" : "s"}`];
  if (m.slots) meta.push(`you: ${m.slots}`);
  if (m.myBack) meta.push(`your backing ${ctx.eth(m.myBack)}`);
  if (m.iBacker) meta.push(`your offer ${ctx.eth(m.backing)}`);
  const waiting = (m.state === "Full" && !m.ready) || m.state === "Decide";
  const card = el("article", { class: `bcard s-${m.state.toLowerCase()}${waiting ? " waiting" : ""}`, tabindex: "0", "aria-label": `Batch #${b}, ${tagText(m)}` },
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
  const who = (x) => (S.account && x.toLowerCase() === S.account.toLowerCase() ? "you" : nameOf(ctx, x));
  const parts = [];

  if (m.state === "Filling" || m.state === "Full" || m.state === "Auction") {
    const p = [row("Depositors' price", m.minimum ? ethUsd(m.minimum) : "not set"),
      row("Voted", `${m.voted} of 80 slots · ${m.voted >= 41n ? "majority" : "41 needed"}`)];
    if (m.slots) {
      p.push(row("Your vote", m.pref ? ethUsd(m.pref) : "not voted"));
      if (m.canAct && m.pref) { const i = input("Your price (ETH)", formatEther(m.pref)); // the first vote lives in the header
        p.push(el("div", { class: "inline" }, i, ghost("Change vote", () => a.vote(a.toWei(i.value)), "vote"))); }
    }
    p.push(el("p", { class: "hint" }, "The price is the lowest price more than 40 of the 80 slots accept. It's the auction's reserve: the first bid must meet it."));
    if (m.state !== "Auction") parts.push(sec("Price", ...p));

    const list = m.backers[0].map((w, i) => ({ who: w, amt: m.backers[1][i], ok: m.backers[2][i] })).sort((x, y) => (y.amt > x.amt ? 1 : -1));
    const bk = [row(m.state === "Auction" ? "Best offer below the price" : "Best backing", m.bestAmt ? `${ethUsd(m.bestAmt)} · ${who(m.bestWho)}` : "none")];
    if (list.length) bk.push(el("ol", { class: "backers" }, ...list.map((x) => el("li", { class: x.ok ? "" : "stale" },
      el("span", {}, who(x.who)), el("span", {}, eth(x.amt), x.ok ? "" : " · needs re-confirming")))));
    if (m.canAct) {
      const i = input(m.myBack ? "Add (ETH)" : "Amount (ETH)");
      bk.push(el("div", { class: "inline" }, i, ghost(m.myBack ? "Add" : "Back", () => a.back(a.toWei(i.value)), "back")));
      if (m.myStale) bk.push(ghost(`Re-confirm my ${eth(m.myBack)} (free)`, a.reconfirm, "reconfirm"));
      if (m.myBack && m.state !== "Auction") bk.push(ghost(`Take back my ${eth(m.myBack)}`, a.unback, "unback"));
      if (m.myBack && m.state === "Auction") bk.push(el("p", { class: "hint" }, `Your ${eth(m.myBack)} offer is binding until the auction is settled.`));
    }
    bk.push(el("p", { class: "hint" }, "A backing is a standing offer for the whole batch, any amount. At or above the price when the auction starts, the best one is the opening bid. " +
      "During the auction, offers stay below the price; if nobody bids, the best offer is what the holders vote on."));
    parts.push(sec(m.state === "Auction" ? "Offers below the price" : "Backing", ...bk));
  }

  if (m.state === "Auction" || m.state === "Decide") {
    const au = [row("Reserve (the price)", ethUsd(m.auctionMin)),
      row("High bid", m.hasBid ? `${ethUsd(m.highBid)} · ${who(m.highBidder)}` : "none yet"),
      ...(m.state === "Decide" ? [row("Offer being voted on", `${ethUsd(m.backing)} · ${who(m.backer)}`)] : []),
      row(m.state === "Decide" ? "Holders' window ends" : "Ends", el("span", { "data-ends": String(m.endsAt) }, ctx.dur(m.endsAt - ctx.now())))];
    if (m.state === "Decide") au.push(row("Accepted", `${m.tally} of 80 slots · ${m.tally >= 41n ? "majority" : `${41n - m.tally} more to sell`}`),
      el("div", { class: "accept-meter" }, el("i", { style: `width:${(Number(m.tally) / 80) * 100}%` }), el("b", {})));
    const bids = await ctx.bidHistory(b);
    if (bids?.length) au.push(ctx.bidList(bids, m.highBidder, S.account));
    parts.push(sec(m.state === "Decide" ? "Holders decide" : "Auction", ...au));
  }
  if (m.state === "Settled" && m.proceeds) {
    const sa = [row("Sold for", ethUsd(m.proceeds)), row("Statement", `#${m.statementId}`)];
    const bids = await ctx.bidHistory(b);
    if (bids?.length) sa.push(ctx.bidList(bids, m.highBidder, S.account));
    parts.push(sec("Sale", ...sa));
  }

  if (m.slots) {
    const y = [row("Your slots", `${m.slots} of 80 · ${((Number(m.slots) / 80) * 100).toFixed(1)}%`)];
    if (m.state === "Settled" && m.proceeds) y.push(row("Your share", `${ethUsd(m.share)}${m.claimed ? " · collected" : ""}`));
    if (m.canAct && (m.state === "Filling" || m.state === "Full")) y.push(ghost(`Withdraw my ${m.slots}`, a.withdraw, "withdrawBacked"));
    if (m.canAct && m.state === "Full" && m.slots === 80n) y.push(ghost("Burn into my Statement", a.redeem, "redeemBacked"));
    parts.push(sec("You", ...y));
  }

  parts.push(sec(m.state === "Settled" ? `Statement #${m.statementId}` : "The 80 Credits", ctx.mosaicButton(b, m.statementId, m.state)));
  const dep = ctx.whoDetails(b, m.depositors);
  if (dep) parts.push(sec("Depositors", dep));

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
    const involved = m.slots || m.iLead || m.iBacker || m.myBack;
    if (m.state === "Full" && !m.minimum && m.slots && !m.pref)
      rows.push([`Vote a price on #${m.b}`, `${m.voted}/80 slots voted${m.voted + m.slots >= 41n ? " · your vote makes the majority" : ", 41 needed"}`, open(m.b)]);
    if (m.state === "Full" && m.myStale)
      rows.push([`Re-confirm your backing on #${m.b}`, "The Credits changed since you backed; it's free", go("Re-confirm", a.reconfirm)]);
    if (m.ready && m.slots)
      rows.push([`Start #${m.b}`, `Price ${eth(m.minimum)}${m.bestAmt ? ` · best offer ${eth(m.bestAmt)}` : ""}`, go("Start auction", a.start)]);
    if (m.ended && involved)
      rows.push([`Settle #${m.b}`, m.hasBid ? `Ended at ${eth(m.highBid)}${m.iLead ? ": you won" : ""}` : m.bestAmt ? "No bid: holders vote on the best offer" : "No bid, no offer: ends unsold", go("Settle", a.settle)]);
    if (m.state === "Decide" && m.live && m.slots && !m.iAccepted)
      rows.push([`Take the backer's ${eth(m.backing)} for #${m.b}?`, `No bid at ${eth(m.auctionMin)} · ${m.tally}/80 accepted, 41 sells`, go("Accept", a.accept)]);
    if (m.windowOver && involved)
      rows.push([`Close #${m.b}`, "Holders didn't take the offer: refund the backer", go("Close", a.expire)]);
  }
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
// Unsold batches the store may buy at exactly the depositors' price.
export async function renderTreasury(ctx) {
  const { S, el, eth, read, send, confirmStep } = ctx;
  const sec = document.getElementById("treasury-section");
  if (!sec) return;
  sec.hidden = !S.treasuryOwner;
  if (!S.treasuryOwner) return;
  const [bal, cap] = await Promise.all([read("treasuryBalance", [], S.store, TREASURY_ABI), read("maxTreasuryBid", [], S.store, TREASURY_ABI)]);
  document.getElementById("treasury-meta").textContent = `holds ${eth(bal)} · cap ${eth(cap)} per purchase · owner only`;
  const full = (S.byState ?? []).filter(([, st]) => st === "Full").map(([b]) => b);
  const rows = await Promise.all(full.map(async (b) => {
    const [unsold, price, median, info] = await Promise.all([read("unsold", [b]), read("majorityMinimum", [b]), read("votedMedian", [b]), read("batchInfo", [b])]);
    if (!unsold || info[2] < 2n) return null;
    const why = !price ? "no price now" : price !== median ? `price ${eth(price)} isn't the voters' median (${eth(median)})`
      : price > cap ? "over the per-purchase cap" : price > bal ? "more than the treasury holds" : null;
    return el("div", { class: "trow" },
      el("div", { class: "trow-head" }, el("b", {}, `#${b}`), el("span", {}, price ? `unsold · price ${eth(price)}` : "unsold")),
      why ? el("p", { class: "tline" }, `Can't buy: ${why}`)
        : el("button", { class: "treasury-btn", "data-tip": "treasuryBuy", onclick: async () => {
          const ok = await confirmStep(`Buy batch #${b} for the store at ${eth(price, 6)}?`, [
            "Its last round ended unsold: no bid at the depositors' price, and they didn't take the backer's offer.",
            `Pays exactly the depositors' price from the treasury (holds ${eth(bal)}). The 80 Credits burn into a Statement for the store, ready to list for SCREDIT.`,
            "If the votes change before this lands, it's refused.",
          ], "Buy for the store");
          if (ok) send(`Store buys #${b}`, "buyUnsold", [b, price], undefined, S.store, TREASURY_ABI, FINALIZE_TX_GAS);
        } }, `Buy at ${eth(price)}`));
  }));
  const list = rows.filter(Boolean);
  document.getElementById("treasury-list").replaceChildren(...(list.length ? list
    : [el("p", { class: "muted" }, "Nothing to buy: no batch is resting after an unsold round.")]));
}
