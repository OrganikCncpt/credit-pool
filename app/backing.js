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
  "function acceptTally(uint256, uint64) view returns (uint256)",
  "function accepted(uint256, uint64, address) view returns (bool)",
  "function pendingReturns(address) view returns (uint256)",
  "function MIN_BACKING() view returns (uint256)",
  "function deposit(uint256[] creditIds) payable",
  "function depositAt(uint256[] creditIds, uint256 expectedBatch, uint256 expectedFilled) payable",
  "function depositInto(uint256 batchId, uint256[] creditIds, uint256 expectedFilled) payable",
  "function withdraw(uint256[] creditIds)",
  "function setReserve(uint256 batchId, uint256 reserveWei)",
  "function back(uint256 batchId) payable",
  "function withdrawBacking(uint256 batchId)",
  "function startAuction(uint256 batchId, uint256 minOpening)",
  "function bid(uint256 batchId) payable",
  "function settle(uint256 batchId)",
  "function acceptBid(uint256 batchId, uint64 round, address bidder, uint256 amount)",
  "function expire(uint256 batchId)",
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
  "error BidChanged()", "error NotYet()", "error NeedMoreGas()", "error TooMany()",
]);

// Contract enum → the names the rest of the site uses ("Settled" = sold and delivered).
// The store's treasury side (BackedStore): owner-only backing within a per-batch cap.
export const TREASURY_ABI = parseAbi([
  "function owner() view returns (address)",
  "function treasuryBalance() view returns (uint256)",
  "function maxTreasuryBid() view returns (uint256)",
  "function backBatch(uint256 batchId, uint256 amount, uint256 expectedTotal)",
  "function unbackBatch(uint256 batchId)",
  "function collectRefund()",
  "error NotFull()", "error NotDepositor()", "error AboveMinimum()", "error OverCap()", "error PriceMoved()",
]);

export const BACKED_STATES = ["Filling", "Full", "Auction", "Decide", "Settled"];
const LABEL = { Filling: "Filling", Full: "Needs backing", Auction: "Auction", Decide: "Deciding", Settled: "Sold" };
export const stateLabel = (s, backed) => (s === "Full" && backed ? "Ready to auction" : LABEL[s] ?? s);

export const BACKED_FILTERS = [
  ["all", "All", () => true],
  ["filling", "Filling", (s) => s === "Filling"],
  ["ready", "Needs a backer / ready", (s) => s === "Full"],
  ["auction", "Live auctions", (s) => s === "Auction"],
  ["decide", "Deciding", (s) => s === "Decide"],
  ["sold", "Sold", (s) => s === "Settled"],
];

// A sale burns 80 Credits and awards points inside one all-or-nothing call that needs 12M gas
// available; the pool refuses to start it with less. Give those transactions room under the 16.7M cap.
export const FINALIZE_TX_GAS = 14_000_000n;

export const BACKED_TIPS = {
  back: "Offer ETH for this whole batch. The best backing becomes the auction's opening bid, so the batch can go up for sale. " +
    "If nobody outbids it, you get the Statement. Until the auction starts you can top up or take it back any time.",
  unback: "Takes your backing back to Ready to collect. Only possible while it isn't the opening bid of a running auction.",
  vote: "The lowest price you'd accept for the whole batch. The minimum is the lowest price that more than 40 of the 80 slots accept. " +
    "An auction ending at or above it sells automatically; below it, depositors get 24 hours to accept or let it expire. Enter 0 to clear your vote.",
  startBacked: "Starts a 24-hour auction with the best backing as the opening bid. Nothing burns yet. Anyone can press it once the batch is full and backed.",
  bid: "Your ETH is held by the pool. If you're outbid, you get it back (Ready to collect). Each bid must beat the last by 5%. Bids in the final 15 minutes add 15 minutes.",
  settleBacked: "Ends the auction. At or above the depositors' minimum it sells now: 80 Credits burn into a Statement for the winner. Below it, depositors get 24 hours to accept.",
  accept: "Accept this exact bid. When more than 40 of the 80 slots accept, it sells in the same transaction: the Credits burn into a Statement for the bidder and the sale is split by slots.",
  expire: "The accept window closed without a majority: refunds the bidder, burns nothing, and the batch is ready for a new backing and auction.",
  withdrawBacked: "Take your Credits back to your wallet. Possible while the batch fills, and while it's full as long as no auction or accept window is running (the batch reopens).",
  redeemBacked: "You hold all 80 slots: burn them into a Statement straight to your wallet. No auction, no fee.",
  deposit: "Moves the selected Credits into the open batch. Fee: {rule}, paid in ETH. You can withdraw until an auction starts; " +
    "they burn only if the batch sells, and then each earns 2 SCREDIT.",
  treasuryBack: "Owner only. Backs this batch from the store treasury, up to the per-batch cap and never above the depositors' own minimum. Raising the cap takes 3 days.",
  claim: "Sends your share of the sale to your wallet: your slots ÷ 80 of the price. Sales carry no fee.",
};

const ZERO = "0x0000000000000000000000000000000000000000";

// Page copy for backed pools: the intro steps and the questions that differ from burn-first.
export function applyBackedCopy(el) {
  const steps = document.querySelector(".intro .steps");
  if (steps) steps.replaceChildren(
    ...[
      ["Deposit", "Add Credits to the open batch. Withdraw any time before an auction starts."],
      ["Back", "Anyone offers ETH for the whole batch. The best backing opens the auction."],
      ["Auction", "24 hours, open to anyone. At or above the depositors' minimum it sells."],
      ["Decide", "Below the minimum? Depositors have 24h to accept by majority, or everyone is refunded."],
      ["Collect", "Only a locked-in sale burns the 80 Credits. Your share = your Credits ÷ 80, plus 2 SCREDIT each."],
    ].map(([b, s]) => el("li", {}, el("b", {}, b), el("span", {}, s))),
  );
  const lead = document.querySelector(".intro p");
  if (lead) lead.textContent = "Pool your Credits with other holders. Nothing burns until a buyer is locked in: every batch needs a backer, " +
    "the best backing opens a 24-hour auction, and the 80 Credits burn into a Statement only when it sells. The sale is split by how many Credits each person put in.";
  for (const d of document.querySelectorAll("[data-mode='burn-first']")) d.remove();
  const gb = document.getElementById("gallery-blurb");
  if (gb) gb.textContent = "Every Statement the pool has sold. Each was burned from 80 Credits the moment its sale locked in; click one to see them.";
  const sb = document.getElementById("store-blurb");
  const safe = [...document.querySelectorAll(".safety li")].find((li) => li.textContent.startsWith("During assembly"));
  if (safe) safe.textContent = "Nothing burns until a sale is locked in. The burn, the delivery to the buyer and the payout happen in one all-or-nothing step: if any part fails, it's all undone and the buyer is refunded. Jack's Statements contract can only reach the 80 Credits being sold.";
  if (sb) sb.textContent = "Statements the store treasury won by backing batches, auctioned for SCREDIT only (never ETH). The treasury (75% of deposit fees) backs full batches, " +
    "capped per batch and never above the depositors' own minimum; outbid, it gets its ETH back. Every SCREDIT bid also pays a small platform fee in ETH.";
  const faq = document.getElementById("faq");
  const q = (sum, text) => el("details", {}, el("summary", {}, sum), el("p", {}, text));
  faq?.querySelector("h2")?.after(
    q("What is backing?", "A backer offers ETH for a whole full batch, in any amount. Several people can back the same batch; the best backing becomes the auction's opening bid. " +
      "If nobody outbids it, the backer gets the Statement. Until the auction starts, a backing can be topped up or taken back any time."),
    q("When do my Credits burn?", "Only when a sale is locked in: an auction that ends at or above the depositors' minimum, or a bid that more than 40 of the 80 slots accept. " +
      "The burn, delivery and payout happen in one transaction; if any part fails, everything is undone and the bidder is refunded."),
    q("What if the auction ends below the minimum?", "Depositors get 24 hours to accept the best bid. When more than 40 of the 80 slots accept, it sells. " +
      "Otherwise the window expires: the bidder is refunded, nothing burns, and the batch can be backed and auctioned again."),
    q("Can I get my Credits back?", "Yes: any time while the batch fills, and while it's full as long as no auction or accept window is running. Taking Credits out of a full batch reopens it, " +
      "and backings made for the old set of Credits no longer count until their backer confirms them again. The deposit fee isn't refunded."),
  );
}

// ───────────────────────── batch card ─────────────────────────
// ctx: the app's helpers (S, el, read, readFresh, send, eth, ethUsd, short, dur, now, toWei,
// confirmStep, toast, mosaicButton, bidHistory, bidList, whoDetails, PER).
export async function backedCard(ctx, b, mineOnly) {
  const { S, el, read, readFresh, send, eth, ethUsd, dur, now, toWei, confirmStep, toast, PER } = ctx;
  // The store's treasury shows by name wherever an address would.
  const short = (a) => (S.store && a.toLowerCase() === S.store.toLowerCase() ? "store treasury" : ctx.short(a));
  const me = S.account;
  const [info, auction, best, minimum, backers, slots, pref, claimed, myBacking, opensAt] = await Promise.all([
    read("batchInfo", [b]), read("auctions", [b]), read("bestBacking", [b]), read("majorityMinimum", [b]),
    read("backersOf", [b]),
    me ? read("slots", [b, me]) : 0n, me ? read("reservePref", [b, me]) : 0n, me ? read("claimed", [b, me]) : false,
    me ? read("backings", [b, me]) : [0n, 0n], read("assemblyOpensAt"),
  ]);
  const [st, filled, depositors, statementId, proceeds, round, nonce] = info;
  const state = BACKED_STATES[st];
  const [highBidder, highBid, auctionMin, endsAt] = auction;
  const [bestWho, bestAmt] = best;
  const [myBack, myBackNonce] = myBacking;
  const iLead = me && highBidder.toLowerCase() === me.toLowerCase();
  if (mineOnly && !slots && !myBack && !iLead) return null;
  const decide = state === "Decide";
  const [tally, iAccepted] = decide ? await Promise.all([read("acceptTally", [b, round]), me ? read("accepted", [b, round, me]) : false]) : [0n, false];
  const live = state === "Auction" && now() < endsAt;
  const bids = state === "Auction" || decide || state === "Settled" ? await ctx.bidHistory(b) : null;

  // Voting tally (≤ 80 depositors), so everyone sees how close the minimum is.
  let voted = null;
  if (state === "Filling" || state === "Full") {
    const addrs = await read("batchDepositors", [b]);
    const [counts, prefs] = await Promise.all([
      Promise.all(addrs.map((a) => read("slots", [b, a]))), Promise.all(addrs.map((a) => read("reservePref", [b, a]))),
    ]);
    voted = counts.reduce((s, n, i) => (prefs[i] ? s + n : s), 0n);
  }

  const sig = JSON.stringify([info, auction, best, minimum, backers, slots, pref, claimed, myBacking, tally, iAccepted, live, voted,
    bids?.length ?? 0, me, S.viewOnly, now() >= opensAt], (_, v) => (typeof v === "bigint" ? v.toString() : v));
  const cacheKey = `${mineOnly ? "mine" : "all"}:${b}`;
  const cached = S.cards.get(cacheKey);
  if (cached && cached.sig === sig) return cached.el;

  const pct = (n) => `${((Number(n) / 80) * 100).toFixed(n % 4n === 0n ? 0 : 1)}%`;
  const kv = el("dl", { class: "kv" });
  const row = (k, v) => kv.append(el("dt", {}, k), el("dd", {}, v));
  row("Depositors", String(depositors));
  if (me && slots) row("Your share", `${slots} of 80 · ${pct(slots)}`);

  const actions = el("div", { class: "actions" });
  const btn = (label, fn, cls = "", tip) => el("button", { class: cls, onclick: fn, "data-tip": tip }, label);
  const input = (ph, val = "") => el("input", { type: "number", step: "any", min: "0", placeholder: ph, value: val });
  const canAct = me && !S.viewOnly;

  // ── the backing panel: Filling and Full ──
  let backing = null;
  if (state === "Filling" || state === "Full") {
    const current = backers[0].map((w, i) => ({ who: w, amt: backers[1][i], ok: backers[2][i] })).sort((x, y) => (y.amt > x.amt ? 1 : -1));
    backing = el("div", { class: "backing" + (bestAmt ? " is-backed" : "") },
      el("div", { class: "backing-head" },
        el("span", { class: "backing-label" }, bestAmt ? "Backed" : "Not backed yet"),
        el("b", {}, bestAmt ? ethUsd(bestAmt) : "—")),
      el("p", { class: "muted small" }, bestAmt
        ? `Best backing by ${me && bestWho.toLowerCase() === me.toLowerCase() ? "you" : short(bestWho)}: the opening bid when the auction starts.`
        : state === "Full" ? "A batch goes up for auction only once someone backs it. The best backing is the opening bid." : "Backers can line up while the batch fills."),
    );
    if (current.length) {
      const list = el("ol", { class: "backers" }, ...current.map((x) => el("li", { class: x.ok ? "" : "stale" },
        el("span", {}, me && x.who.toLowerCase() === me.toLowerCase() ? `${short(x.who)} (you)` : short(x.who)),
        el("span", {}, eth(x.amt), x.ok ? "" : " · needs re-confirming"))));
      backing.append(list);
    }
    if (canAct) {
      const minBack = bestAmt ? bestAmt + 1n : 80n;
      const i = input(myBack ? "Add (ETH)" : "Backing (ETH)", myBack ? "" : formatEther(bestAmt ? bestAmt + bestAmt / 20n : 10n ** 15n));
      const stale = myBack && myBackNonce !== nonce;
      backing.append(el("div", { class: "row" }, i, btn(myBack ? (stale ? "Re-confirm / add" : "Add to backing") : "Back this batch", async () => {
        let v = toWei(i.value || "0");
        if (v == null) return toast("Enter an amount in ETH", true);
        if (v === 0n && stale) v = 1n; // re-confirming for the current Credits needs a non-zero top-up
        if (v === 0n) return toast("Enter an amount in ETH", true);
        if (myBack + v < 80n) return toast("A backing must be at least 80 wei (1 wei per slot)", true);
        const total = myBack + v;
        const ok = await confirmStep(`Back batch #${b} with ${eth(total, 6)}?`, [
          `${myBack ? `Adds ${eth(v, 6)} to your ${eth(myBack, 6)}. ` : ""}Your ETH is held by the pool as an offer for all 80 Credits.`,
          total >= minBack || !bestAmt ? "It would be the best backing: the opening bid when the auction starts." : `The best backing is ${eth(bestAmt, 6)}; yours opens the auction only if it's the highest when someone starts it.`,
          "If nobody outbids it in the auction, you get the Statement.",
          "Until the auction starts, you can take it back any time (it goes to Ready to collect). Once it's the opening bid, it's committed like any bid.",
          ...(state === "Filling" ? ["The batch is still filling: if its Credits change, you re-confirm your backing (any top-up) before it counts."] : []),
        ], "Back");
        if (ok) send(`Back #${b}`, "back", [b], v);
      }, "", "back")));
      if (myBack) backing.append(btn(`Take back my ${eth(myBack)}`, () => send(`Unback #${b}`, "withdrawBacking", [b]), "ghost", "unback"));
    }
    if (canAct && S.treasuryOwner && state === "Full" && depositors > 1n) backing.append(await treasuryControl(ctx, b, minimum));
  }

  // ── depositor votes: Filling and Full ──
  if ((state === "Filling" || state === "Full") && voted != null) {
    row("Minimum price", minimum ? ethUsd(minimum) : `not set · ${voted}/80 voted, need 41`);
    if (me && slots) row("Your minimum", pref ? ethUsd(pref) : "not voted");
    if (canAct && slots) {
      const i = input("Min price (ETH)", pref ? formatEther(pref) : "");
      actions.append(el("div", { class: "row" }, i, btn("Vote minimum", () => {
        const v = toWei(i.value);
        if (v == null) return toast("Enter a price in ETH, or 0 to clear your vote", true);
        send("Vote", "setReserve", [b, v]);
      }, "ghost", "vote")));
    }
  }

  if (state === "Full") {
    if (canAct && slots === PER) actions.append(btn("Burn into my Statement", async () => {
      if (await confirmStep(`Burn batch #${b} into your Statement?`, [
        "You hold all 80 slots, so this batch is yours alone: the 80 Credits burn into one Statement, sent to your wallet.",
        "This can't be undone. No auction, no fee.",
      ], "Burn & take")) send(`Redeem #${b}`, "redeem", [b], undefined, undefined, undefined, FINALIZE_TX_GAS);
    }, "ghost", "redeemBacked"));
    if (bestAmt && now() >= opensAt) {
      actions.prepend(btn(`Start auction · opens at ${eth(bestAmt)}`, async () => {
        const ok = await confirmStep(`Start the auction for batch #${b}?`, [
          `Opening bid: ${eth(bestAmt, 6)}, the best backing (${short(bestWho)}). It's committed for this auction.`,
          minimum ? `If the auction ends at ${eth(minimum, 6)} or more (the depositors' minimum), it sells automatically.`
            : "No majority minimum is set, so it never sells automatically: when it ends, depositors have 24 hours to accept the best bid.",
          "Runs 24 hours; bids in the last 15 minutes add 15 minutes. Depositors can't withdraw while it runs.",
          "Nothing burns now. If the backing drops before your transaction lands, it's refused.",
        ], "Start auction");
        if (ok) send(`Start auction #${b}`, "startAuction", [b, bestAmt]);
      }, "", "startBacked"));
    }
  }

  if (state === "Auction" || decide) {
    row("Minimum price", auctionMin ? ethUsd(auctionMin) : "none set (depositors decide)");
    row(decide ? "Best bid" : "High bid", `${ethUsd(highBid)} · ${iLead ? "you" : short(highBidder)}`);
    row(decide ? "Decide window ends" : "Ends", el("span", { "data-ends": String(endsAt) }, dur(endsAt - now())));
  }
  if (live && canAct) {
    const min = await readFresh("minNextBid", [b]);
    const netCost = (v) => v - (v * slots) / PER;
    const i = input("Bid (ETH)", formatEther(min));
    actions.append(el("div", { class: "row" }, i, btn("Bid", () => {
      const v = toWei(i.value);
      if (v == null) return toast("Enter a bid in ETH", true);
      if (v < min) return toast(`Minimum bid is ${formatEther(min)} ETH`, true);
      confirmStep(`Bid ${eth(v, 6)} on batch #${b}?`, [
        "Your ETH is held by the pool. You can't cancel a bid; if someone outbids you, it's returned to Ready to collect.",
        auctionMin ? `If the auction ends with your bid at or above ${eth(auctionMin, 6)}, it sells to you and the Statement goes to your wallet.`
          : "When the auction ends, depositors have 24 hours to accept the best bid by majority. If they don't, you're refunded.",
        ...(slots ? [`You hold ${slots}/80 slots, so if you win ${eth(v - netCost(v), 4)} comes back to you: it really costs you ${eth(netCost(v), 4)}.`] : []),
      ], "Place bid").then((ok) => ok && send(`Bid on #${b}`, "bid", [b], v));
    }, "", "bid")));
    actions.append(el("span", { class: "muted small" }, `min ${eth(min, 6)} · +5% per bid · bids in the last 15m extend it`));
  }
  if (state === "Auction" && !live) {
    actions.append(btn(highBid >= auctionMin && auctionMin ? "Settle: sells now" : "Settle: open the 24h decision", () =>
      send(`Settle #${b}`, "settle", [b], undefined, undefined, undefined, FINALIZE_TX_GAS), "", "settleBacked"));
  }
  if (decide) {
    const need = tally >= 41n ? 0n : 41n - tally;
    row("Accepted", `${tally} of 80 slots · ${need ? `${need} more to sell` : "majority"}`);
    const meter = el("div", { class: "accept-meter", title: `${tally}/80 accepted, 41 needed` },
      el("i", { style: `width:${(Number(tally) / 80) * 100}%` }), el("b", { style: "left:51.25%" }));
    actions.append(meter);
    if (now() < endsAt) {
      if (canAct && slots && !iAccepted) actions.append(btn(`Accept ${eth(highBid)}`, async () => {
        const mine = (highBid * slots) / PER;
        const ok = await confirmStep(`Accept ${eth(highBid, 6)} for batch #${b}?`, [
          `You're accepting exactly this bid from ${short(highBidder)}; if anything about it changed, your acceptance is refused.`,
          `Your ${slots} slot${slots > 1n ? "s" : ""} count toward the 41 needed. ${tally + slots >= 41n ? "This makes the majority: it sells in this transaction." : `After you, ${41n - tally - slots} more needed.`}`,
          `If it sells, the 80 Credits burn into a Statement for the bidder and your share is ${eth(mine, 6)}.`,
          "You can't take an acceptance back.",
        ], "Accept");
        if (ok) send(`Accept #${b}`, "acceptBid", [b, round, highBidder, highBid], undefined, undefined, undefined, FINALIZE_TX_GAS);
      }, "", "accept"));
      if (iAccepted) actions.append(el("span", { class: "muted small" }, "You accepted. Waiting for the majority."));
    } else {
      actions.append(btn("Close window: refund, nothing burns", () => send(`Expire #${b}`, "expire", [b]), "ghost", "expire"));
    }
  }

  if (state === "Settled") {
    row("Statement", `#${statementId}`);
    row(proceeds ? "Sold for" : "Taken by", proceeds ? ethUsd(proceeds) : "its sole holder");
    if (me && slots && proceeds) row("You get", `${ethUsd((proceeds * slots) / PER)}${claimed ? " · collected" : ""}`);
    if (canAct && slots && !claimed && proceeds) actions.append(btn(`Claim ${eth((proceeds * slots) / PER)}`, () => send(`Claim #${b}`, "claim", [b]), "", "claim"));
  }

  // Withdraw Credits: Filling, or Full with nothing running.
  if (canAct && slots && (state === "Filling" || state === "Full")) {
    actions.append(btn(`Withdraw my ${slots}`, async () => {
      const all = await readFresh("batchCredits", [b]);
      const owners = await Promise.all(all.map((id) => readFresh("depositorOf", [id])));
      const mine = all.filter((_, i) => owners[i].toLowerCase() === me.toLowerCase());
      if (state === "Full" && !(await confirmStep(`Withdraw from full batch #${b}?`, [
        "The batch reopens and needs refilling before it can be auctioned.",
        bestAmt ? "Its backers' offers were for these exact Credits: they'll need to re-confirm before an auction can start." : "Nobody has backed it yet.",
        "The deposit fee isn't refunded.",
      ], "Withdraw"))) return;
      send(`Withdraw ${mine.length}`, "withdraw", [mine]);
    }, "ghost", "withdrawBacked"));
  }

  const card = el("div", { class: "batch" },
    el("div", { class: "batch-top" }, el("b", {}, `Batch #${b}`), el("span", { class: `tag ${state}` }, stateLabel(state, !!bestAmt))),
    nextStepBacked(ctx, { state, filled, slots, me, bestAmt, minimum, voted, highBid, auctionMin, endsAt, tally, iAccepted, claimed, proceeds, opensAt, iLead }),
    backing,
    actions.childElementCount ? actions : null,
    el("div", { class: "bar", title: `${filled}/80` }, el("i", { style: `width:${(Number(filled) / 80) * 100}%` })),
    el("span", { class: "muted small" }, `${filled}/80 Credits`),
    ctx.mosaicButton(b, statementId, state),
    kv,
    bids?.length ? ctx.bidList(bids, highBidder, me) : null,
    ctx.whoDetails(b, depositors),
  );
  S.cards.set(cacheKey, { sig, el: card });
  return card;
}

// Owner-only: back this batch from the store treasury. The contract re-checks every limit.
async function treasuryControl(ctx, b, minimum) {
  const { S, el, read, send, eth, toWei, confirmStep, toast } = ctx;
  const [[current], cap, bal] = await Promise.all([
    read("backings", [b, S.store]), read("maxTreasuryBid", [], S.store, TREASURY_ABI), read("treasuryBalance", [], S.store, TREASURY_ABI),
  ]);
  const limit = minimum && minimum < cap ? minimum : cap;
  const room = limit > current ? limit - current : 0n;
  const i = el("input", { type: "number", step: "any", min: "0", placeholder: "Treasury (ETH)", value: room ? formatEther(room < bal ? room : bal) : "" });
  const box = el("div", { class: "treasury-ctl" },
    el("span", { class: "backing-label" }, "Store treasury · owner"),
    el("span", { class: "muted small" }, `Backing ${eth(current)} · limit ${eth(limit)}${minimum && minimum < cap ? " (the depositors' minimum)" : " (per-batch cap)"} · treasury holds ${eth(bal)}`),
    el("div", { class: "row" }, i,
      el("button", { "data-tip": "treasuryBack", onclick: async () => {
        const v = toWei(i.value);
        if (!v) return toast("Enter an amount in ETH", true);
        const total = current + v;
        if (total > limit) return toast(`The treasury can back at most ${eth(limit, 6)} here`, true);
        const ok = await confirmStep(`Back batch #${b} from the treasury?`, [
          `Moves ${eth(v, 6)} of treasury ETH into the pool, for a total treasury backing of ${eth(total, 6)}.`,
          "If it opens the auction and nobody outbids it, the Statement comes to the store, ready to list for SCREDIT.",
          "Outbid, expired or unwound: the ETH comes back to the treasury (Collect).",
          "If the backing changed before this lands, it's refused.",
        ], "Back from treasury");
        if (ok) send(`Treasury backs #${b}`, "backBatch", [b, v, total], undefined, S.store, TREASURY_ABI);
      } }, "Back from treasury")),
  );
  // The minimum rule is checked when the treasury backs (store audit Info-1): if depositors lower
  // their minimum afterwards, say so, so the owner can return the difference before a start.
  if (current && minimum && current > minimum) box.append(el("p", { class: "next warn" },
    `The depositors' minimum dropped to ${eth(minimum)}, below the treasury's ${eth(current)} backing. Return it and back again at the new minimum if you don't want to pay more than they ask.`));
  if (current) box.append(el("button", { class: "ghost", onclick: () => send(`Treasury unbacks #${b}`, "unbackBatch", [b], undefined, S.store, TREASURY_ABI) }, `Return ${eth(current)} to treasury`));
  return box;
}

function nextStepBacked(ctx, x) {
  const { el, eth, dur, now } = ctx;
  const mine = x.me && x.slots;
  const t = (s, cls = "") => el("p", { class: "next " + cls }, s);
  switch (x.state) {
    case "Filling":
      return t(`Filling: ${80n - x.filled} more Credits needed.${mine ? " You can withdraw yours any time before an auction starts." : " Deposit yours above to join."}`);
    case "Full":
      if (!x.bestAmt) return t("Full and waiting for a backer: anyone can offer ETH for the whole batch. The best backing opens the auction. Nothing burns until a sale is locked in.", "warn");
      if (now() < x.opensAt) return t(`Backed at ${eth(x.bestAmt)}. Auctions open in ${dur(x.opensAt - now())}.`);
      return t(`Backed at ${eth(x.bestAmt)}. Anyone can start the 24-hour auction now${x.minimum ? `; it sells automatically at ${eth(x.minimum)} or more` : "; no majority minimum yet, so depositors will decide at the end"}.`);
    case "Auction":
      return now() < x.endsAt
        ? el("p", { class: "next" }, `Auction live: ${x.iLead ? "you lead" : "high bid"} ${eth(x.highBid)}. Ends in `,
          el("span", { "data-ends": String(x.endsAt) }, dur(x.endsAt - now())), ". Anyone can bid.")
        : t(x.auctionMin && x.highBid >= x.auctionMin
          ? "Auction over at or above the minimum. Anyone can press Settle: the Credits burn into a Statement for the winner and depositors are paid."
          : "Auction over below the minimum. Press Settle to open the 24-hour window for depositors to accept or decline.");
    case "Decide":
      return now() < x.endsAt
        ? el("p", { class: "next warn" }, `Depositors decide: ${x.tally}/80 slots accepted ${eth(x.highBid)}, 41 sells it. `,
          el("span", { "data-ends": String(x.endsAt) }, dur(x.endsAt - now())), " left.", mine && !x.iAccepted ? " Your vote counts." : "")
        : t("The window closed without a majority. Anyone can close it: the bidder is refunded and nothing burns.");
    case "Settled":
      if (!x.proceeds) return t("Burned into a Statement for the depositor who held all 80 slots.");
      return t(mine ? (x.claimed ? "Sold, and you've collected your share." : `Sold. Your share is ready: ${eth((x.proceeds * x.slots) / 80n)}.`)
        : "Sold: the Statement went to the winner. Depositors can collect their share.");
    default: return null;
  }
}
