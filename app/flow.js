// credit.pool flow prototype: the full backed-auction experience on mock data (no contract calls).
// Deposit → batch fills → vote the minimum → a whale backs it → 24h auction → (accept) → burn → collect.
const $ = (id) => document.getElementById(id);
const h = (tag, attrs = {}, ...kids) => {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (k === "class") e.className = v;
    else e.setAttribute(k, v === true ? "" : v);
  }
  for (const k of kids.flat()) if (k != null && k !== false) e.append(k.nodeType ? k : document.createTextNode(String(k)));
  return e;
};

// ───────── mock world ─────────
const ETH_USD = 2600;
const usd = (eth) => `$${(eth * ETH_USD).toLocaleString("en-US", { maximumFractionDigits: eth * ETH_USD < 10 ? 2 : 0 })}`;
const fmt = (eth, dp = 4) => `${eth.toFixed(dp)} ETH`;
const feePer = (n) => (n >= 6 ? 1 : 2) / ETH_USD;          // $2 per Credit, $1 each for 6+
const INK = { c: "#00a3e0", m: "#e0007a", y: "#f2c500", k: "#151412" };
const INKS = ["c", "m", "y", "k"];
function rng(seed) { let s = seed >>> 0 || 1; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
function credit(id, ink) {
  const r = rng(id * 2654435761);
  return { id, ink: ink ?? INKS[Math.floor(r() * 4)], cells: Array.from({ length: 25 }, () => r() < 0.55), dx: Math.round(r() * 4 - 2), dy: Math.round(r() * 4 - 2) };
}
const ME = "you";
const others = Array.from({ length: 50 }, (_, i) => ({ ...credit(3000 + i * 71), who: `0x${(0x1a2b + i * 97).toString(16)}…${(i * 13 + 17).toString(16).padStart(2, "0")}` }));
const wallet = Array.from({ length: 18 }, (_, i) => credit(100 + i * 41));

let S;
function reset() {
  S = {
    phase: "pick", picked: new Set(), deposited: [], batch: others.slice(), order: "colour",
    minimum: 0.40, myVote: null, votes: 0, backings: [], high: null, bids: [], ends: 0,
    accept: 0, myAccept: false, balance: 1.0, points: 0, collected: false, printed: 0, feed: [],
  };
  log("Batch #46 is filling · 50 of 80 Credits from 11 holders");
}

// ───────── sheet (the Statement taking shape) ─────────
const cv = $("sheet"), ctx = cv.getContext("2d");
function arranged() {
  const list = S.batch.slice();
  if (S.order === "colour" || S.order === "misreg") list.sort((a, b) => INKS.indexOf(a.ink) - INKS.indexOf(b.ink) || a.id - b.id);
  if (S.order === "number") list.sort((a, b) => a.id - b.id);
  return list;
}
function drawSheet(inksUpTo = 4) {
  const W = cv.width, H = cv.height, px = 9, cell = 5 * px, gap = 20;
  const ox = (W - (8 * cell + 7 * gap)) / 2, oy = (H - (10 * cell + 9 * gap)) / 2;
  ctx.globalCompositeOperation = "source-over";
  ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, W, H);
  const list = arranged();
  for (let i = 0; i < 80; i++) {
    const x = ox + (i % 8) * (cell + gap), y = oy + Math.floor(i / 8) * (cell + gap);
    if (i >= list.length) { ctx.strokeStyle = "#e6e1d6"; ctx.setLineDash([4, 4]); ctx.strokeRect(x + .5, y + .5, cell - 1, cell - 1); ctx.setLineDash([]); }
  }
  ctx.globalCompositeOperation = "multiply";
  list.forEach((cr, i) => {
    if (INKS.indexOf(cr.ink) >= inksUpTo) return;
    const mis = S.order === "misreg" ? 3 : 0;
    const x = ox + (i % 8) * (cell + gap) + cr.dx * mis, y = oy + Math.floor(i / 8) * (cell + gap) + cr.dy * mis;
    ctx.fillStyle = INK[cr.ink];
    cr.cells.forEach((on, k) => { if (on) ctx.fillRect(x + (k % 5) * px, y + Math.floor(k / 5) * px, px, px); });
  });
  ctx.globalCompositeOperation = "source-over";
  list.forEach((cr, i) => { // your Credits get a small magenta corner mark
    if (cr.who !== ME || S.phase === "sold" || S.phase === "collect") return;
    const x = ox + (i % 8) * (cell + gap), y = oy + Math.floor(i / 8) * (cell + gap);
    ctx.fillStyle = INK.m; ctx.beginPath(); ctx.arc(x + cell + 4, y - 4, 4, 0, Math.PI * 2); ctx.fill();
  });
}
function mini(canvas, cr) {
  const c = canvas.getContext("2d"), s = canvas.width / 5;
  c.fillStyle = "#fff"; c.fillRect(0, 0, canvas.width, canvas.height); c.fillStyle = INK[cr.ink];
  cr.cells.forEach((on, k) => { if (on) c.fillRect((k % 5) * s, Math.floor(k / 5) * s, s, s); });
}

// ───────── chrome: rail, header, feed ─────────
const RAIL = [["pick", "Deposit"], ["fill", "Fill"], ["vote", "Vote"], ["back", "Back"], ["auction", "Auction"], ["decide", "Decide"], ["collect", "Collect"]];
const railIndex = (p) => ({ pick: 0, fill: 1, vote: 2, back: 3, auction: 4, decide: 5, printing: 5, sold: 6, collect: 6, refunded: 3 })[p];
function renderRail() {
  const at = railIndex(S.phase);
  $("rail").replaceChildren(...RAIL.map(([, lbl], i) => h("li", { class: i < at || (S.phase === "collect" && S.collected) ? "done" : i === at ? "now" : "" },
    h("div", { class: "bar" }, h("i")), h("div", { class: "lbl" }, lbl))));
}
function log(msg) {
  S.feed.unshift({ t: S.feed.length ? `+${S.feed.length * 3}m` : "now", msg });
  $("feed").replaceChildren(...S.feed.slice(0, 7).map((f) => h("li", {}, h("span", { class: "t" }, f.t), h("span", {}, f.msg))));
}
function bump(id) { const e = $(id); e.classList.remove("bump"); void e.offsetWidth; e.classList.add("bump"); }
function renderTop() {
  $("points").textContent = `${S.points} SCREDIT`;
  $("balance").textContent = fmt(S.balance);
  const n = S.batch.length;
  $("fill-bar").style.width = `${(n / 80) * 100}%`;
  $("fill-text").textContent = `${n} / 80 Credits`;
  $("order-text").textContent = `Print order: ${({ colour: "grouped by colour", number: "by Credit number", misreg: "misregistered", deposit: "deposit order" })[S.order]}`;
  const st = {
    pick: ["Filling", "", "Pick Credits to pool"], fill: ["Filling", "", "The batch is filling"],
    vote: ["Full · not burned", "full", "Agree on a minimum"], back: ["Full · awaiting backing", "full", "Waiting for a backer"],
    auction: ["Backed · auction live", "live", "The auction is live"], decide: ["Decide · 24h window", "decide", "Accept the best bid?"],
    printing: ["Printing", "live", "Printing the Statement"], sold: ["Sold · burned", "sold", "Statement #41 is printed"],
    collect: ["Sold · burned", "sold", S.collected ? "All collected" : "Collect your share"], refunded: ["Full · not burned", "full", "No sale, nothing burned"],
  }[S.phase];
  $("batch-state").textContent = st[0]; $("batch-state").className = `state ${st[1]}`;
  $("batch-title").textContent = st[2];
  $("stamp").hidden = !(S.phase === "sold" || S.phase === "collect");
  $("stamp").textContent = S.high ? `Sold · ${fmt(S.high.amt, 3)}` : "Sold";
}

// ───────── the panel: one step, one primary action ─────────
const mine = () => S.deposited.length;
const facts = (...rows) => h("dl", { class: "facts" }, ...rows.flatMap(([k, v, big]) => [h("dt", {}, k), h("dd", { class: big ? "big" : "" }, v)]));
const panel = (no, title, lead, ...body) => $("panel").replaceChildren(
  ...[h("div", { class: "step-no" }, no), h("h2", {}, title), lead ? h("p", { class: "lead" }, lead) : null, ...body].filter(Boolean));
const primary = (label, onclick, disabled) => h("button", { class: "primary", onclick, disabled }, label);
const secondary = (label, onclick) => h("button", { class: "secondary", onclick }, label);
const tally = (n, label) => h("div", { class: "tally" },
  h("div", { class: "track" }, h("i", { style: `width:${(n / 80) * 100}%` }), h("span", { class: "q", title: "41 of 80: a majority" })),
  h("div", { class: "lbls" }, h("span", {}, `${n} / 80 ${label}`), h("span", {}, "majority at 41")));
const left = () => { const s = Math.max(0, Math.floor((S.ends - Date.now()) / 1000)); return `${String(Math.floor(s / 3600)).padStart(2, "0")}:${String(Math.floor(s / 60) % 60).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`; };

function renderPanel() {
  const n = S.picked.size;
  if (S.phase === "pick") {
    const grid = h("div", { class: "picker" }, ...wallet.map((cr) => {
      const c = h("canvas", { width: 50, height: 50 }); mini(c, cr);
      return h("button", { class: `pick${S.picked.has(cr.id) ? " on" : ""}`, title: `Credit #${cr.id}`, "aria-pressed": S.picked.has(cr.id) ? "true" : "false",
        onclick: () => { S.picked.has(cr.id) ? S.picked.delete(cr.id) : S.picked.add(cr.id); render(); } }, c);
    }));
    const fee = n * feePer(n);
    return panel("Step 1 of 6 · Deposit", "Pool your Credits",
      "Pick Credits from your wallet. They join batch #46. You can take them back any time until it fills.",
      grid,
      h("div", { class: "row", style: "justify-content:space-between;margin:-4px 0 14px" },
        h("button", { class: "link", onclick: () => { wallet.slice(0, 12).forEach((c) => S.picked.add(c.id)); render(); } }, "Pick 12"),
        h("span", { class: "muted", style: "font-size:12.5px" }, n >= 6 || !n ? "6+ at once: $1 each" : `add ${6 - n} more for $1 each`)),
      facts(["Credits", String(n)], ["Fee", n ? `${usd(fee)} · ${fmt(fee, 5)}` : "—"], ["You'll earn", n ? `${n * 2} SCREDIT when it prints` : "—"]),
      h("div", { class: "two-step" }, h("span", { class: "now" }, "1 · Approve pool (once)"), h("span", {}, "2 · Deposit")),
      primary(n ? `Approve & deposit ${n}` : "Pick Credits to continue", () => {
        const picks = wallet.filter((c) => S.picked.has(c.id));
        S.balance -= n * feePer(n);
        S.deposited = picks.map((c) => ({ ...c, who: ME }));
        S.batch = S.batch.concat(S.deposited);
        S.phase = "fill"; log(`You deposited ${n} Credits · ${usd(fee)} fee`); render();
      }, !n),
      h("p", { class: "hint" }, "The approval only lets the pool move Credits you deposit yourself. Revoke it any time."));
  }
  if (S.phase === "fill") {
    const need = 80 - S.batch.length;
    return panel("Step 2 of 6 · Fill", `${need} more to fill the batch`,
      "Other holders are adding Credits. When it reaches 80 it locks, still unburned, and depositors agree on a price.",
      facts(["Your Credits", `${mine()} of ${S.batch.length}`], ["Your share when it sells", `${mine()}/80 · ${((mine() / 80) * 100).toFixed(1)}%`, true], ["Can you leave?", "Yes, until it fills"]),
      primary("Waiting for the batch to fill…", null, true),
      secondary("Withdraw my Credits", () => { S.batch = S.batch.filter((c) => c.who !== ME); S.balance += 0; S.deposited = []; S.picked.clear(); S.phase = "pick"; log("You withdrew your Credits (fee not refunded)"); render(); }),
      h("p", { class: "hint" }, "Use the prototype bar above: “Others fill the batch”."));
  }
  if (S.phase === "vote") {
    const f = h("input", { type: "number", step: "0.01", min: "0", value: String(S.myVote ?? S.minimum), "aria-label": "Minimum price in ETH" });
    return panel("Step 3 of 6 · Vote", "What's the least you'd sell for?",
      "The minimum is the price more than half of the 80 Credits agree to. Every Credit is one vote.",
      h("div", { class: "field" }, f, h("span", { class: "unit" }, "ETH for the batch")),
      h("div", { class: "callout" }, "That's ", h("b", { id: "pc" }, `${fmt((S.myVote ?? S.minimum) / 80, 4)} per Credit`), " · floor on OpenSea ", h("b", {}, "0.0045"), " (guide only)"),
      h("div", { class: "eyebrow" }, "Print order"),
      h("div", { class: "chips" }, ...[["colour", "Grouped by colour"], ["number", "By number"], ["misreg", "Misregistered"], ["deposit", "Deposit order"]]
        .map(([k, l]) => h("button", { class: `chip${S.order === k ? " on" : ""}`, onclick: () => { S.order = k; render(); } }, l))),
      tally(S.votes, "Credits voted"),
      primary(S.myVote != null ? `You voted ${fmt(S.myVote, 2)} · change` : `Vote with your ${mine()} Credits`, () => {
        S.myVote = Number(f.value) || S.minimum; if (!S.voted) { S.votes += mine(); S.voted = true; }
        log(`You voted ${fmt(S.myVote, 2)} and “${({ colour: "grouped by colour", number: "by number", misreg: "misregistered", deposit: "deposit order" })[S.order]}”`);
        advanceVote(); render();
      }),
      h("p", { class: "hint" }, "Votes can change until the auction starts. The print order freezes then."));
  }
  if (S.phase === "back" || S.phase === "refunded") {
    const best = S.backings.slice().sort((a, b) => b.amt - a.amt)[0];
    const f = h("input", { type: "number", step: "0.01", min: "0", value: "0.30", "aria-label": "Backing in ETH" });
    return panel("Step 4 of 6 · Back", S.phase === "refunded" ? "No sale. Back it again?" : "Every auction starts with a backer",
      S.phase === "refunded"
        ? "Nobody's ETH was kept and nothing was burned. Your Credits are still in the batch; wait for better backing or withdraw."
        : "A backer commits ETH for the whole batch, in any amount. The best backing opens the auction; anyone can beat it.",
      S.backings.length ? h("ul", { class: "list" }, ...S.backings.slice().sort((a, b) => b.amt - a.amt).map((b, i) =>
        h("li", { class: i === 0 ? "top" : "" }, h("span", {}, h("span", { class: "who" }, b.who), h("span", { class: "tag" }, i === 0 ? "opens" : "fallback")),
          h("span", { class: "amt" }, `${fmt(b.amt, 2)} · ${usd(b.amt)}`)))) : h("div", { class: "callout" }, "No backing yet. Whales can post one any time."),
      facts(["Majority minimum", fmt(S.minimum, 2)], ["Best backing", best ? `${fmt(best.amt, 2)} · ${fmt(best.amt / 80, 4)}/Credit` : "—", true]),
      primary(best ? `Start the auction at ${fmt(best.amt, 2)}` : "Needs a backer to start", () => {
        S.high = { who: best.who, amt: best.amt }; S.bids = [{ ...S.high, note: "backing" }];
        S.ends = Date.now() + 24 * 3600_000; S.phase = "auction"; log(`Auction started · ${best.who}'s ${fmt(best.amt, 2)} backing is the opening bid`); render();
      }, !best),
      h("details", { style: "margin-top:12px" }, h("summary", { class: "muted", style: "font-size:13px;cursor:pointer" }, "Back it yourself"),
        h("div", { class: "field", style: "margin-top:10px" }, f, h("span", { class: "unit" }, "ETH")),
        secondary("Post backing (held by the contract)", () => { const v = Number(f.value); if (v > 0) { S.backings.push({ who: ME, amt: v }); S.balance -= v; log(`You backed the batch with ${fmt(v, 2)}`); render(); } })));
  }
  if (S.phase === "auction") {
    const min = +(S.high.amt * 1.05).toFixed(4);
    const f = h("input", { type: "number", step: "0.001", min: String(min), value: String(min), "aria-label": "Your bid in ETH" });
    const net = (v) => v - (v * mine()) / 80;
    return panel("Step 5 of 6 · Auction", "Open to everyone for 24 hours",
      "Beat the high bid by 5%. A bid in the last 15 minutes adds 15 minutes.",
      h("div", { class: "countdown", id: "cd" }, left()),
      h("ul", { class: "list" }, ...S.bids.slice().reverse().slice(0, 4).map((b, i) =>
        h("li", { class: i === 0 ? "top" : "" }, h("span", {}, h("span", { class: "who" }, b.who), b.note ? h("span", { class: "tag" }, b.note) : null), h("span", { class: "amt" }, fmt(b.amt, 4))))),
      facts(["High bid", `${fmt(S.high.amt, 4)} · ${usd(S.high.amt)}`, true], ["Majority minimum", fmt(S.minimum, 2)],
        ["If it ends here", S.high.amt >= S.minimum ? "Sells automatically" : "Depositors decide (24h)"]),
      h("div", { class: "field" }, f, h("span", { class: "unit" }, "ETH")),
      primary(`Bid ${fmt(min, 4)}`, () => {
        const v = Math.max(min, Number(f.value) || min);
        S.high = { who: ME, amt: v }; S.bids.push({ ...S.high }); S.balance -= v;
        if (S.ends - Date.now() < 15 * 60_000) S.ends = Date.now() + 15 * 60_000;
        log(`You bid ${fmt(v, 4)}`); render();
      }),
      h("p", { class: "hint" }, `You hold ${mine()}/80: if you win at ${fmt(min, 4)}, ${fmt(min - net(min), 4)} comes back to you, so it really costs ${fmt(net(min), 4)}.`));
  }
  if (S.phase === "decide") {
    return panel("Step 6 of 6 · Decide", "The best bid is under your minimum",
      "Depositors have 24 hours to accept it. A majority (41 of 80 Credits) sells; otherwise everyone is refunded and nothing burns.",
      h("div", { class: "countdown", id: "cd" }, left()),
      facts(["Best bid", `${fmt(S.high.amt, 4)} · ${usd(S.high.amt)}`, true], ["Majority minimum", fmt(S.minimum, 2)], ["Your share if accepted", fmt((S.high.amt * mine()) / 80, 4)]),
      tally(S.accept, "Credits accept"),
      primary(S.myAccept ? "You accepted" : `Accept with your ${mine()} Credits`, () => { S.myAccept = true; S.accept += mine(); log(`You voted to accept ${fmt(S.high.amt, 4)}`); checkAccept(); render(); }, S.myAccept),
      secondary("Let it expire (refund everyone)", () => expire()));
  }
  if (S.phase === "printing") {
    return panel("Burning & printing", "Locked in. Printing now.",
      "One transaction: the 80 Credits burn, the Statement prints and goes to the buyer, and depositors are paid.",
      facts(["Buyer", S.high.who === ME ? "you" : S.high.who], ["Price", fmt(S.high.amt, 4), true], ["Passes", ["Cyan", "Magenta", "Yellow", "Black"].slice(0, S.printed).join(" · ") || "…"]),
      primary("Printing…", null, true));
  }
  if (S.phase === "sold" || S.phase === "collect") {
    const share = (S.high.amt * mine()) / 80;
    const refunds = S.bids.filter((b) => b.who === ME && b !== S.high).reduce((t, b) => t + b.amt, 0)
      + S.backings.filter((b) => b.who === ME && !(S.high.who === ME && S.bids[0].who === ME && S.bids.length === 1)).reduce((t, b) => t + b.amt, 0);
    const iWon = S.high.who === ME;
    return panel("Done · Collect", S.collected ? "All collected" : "Your share is ready",
      iWon ? "You won the Statement. Your share of your own payment comes back to you too." : `Statement #41 went to ${S.high.who}. No sale fee: depositors split the whole price.`,
      facts(["Sold for", `${fmt(S.high.amt, 4)} · ${usd(S.high.amt)}`], ["Your share", `${mine()}/80 → ${fmt(share, 6)}`, true],
        refunds ? ["Refunds (outbid bids)", fmt(refunds, 4)] : ["Refunds", "none"], ["Store points", `+${mine() * 2} SCREDIT`]),
      primary(S.collected ? "Collected ✓" : `Collect ${fmt(share + refunds, 6)}`, () => {
        S.balance += share + refunds; S.points += mine() * 2; S.collected = true; S.phase = "collect";
        log(`You collected ${fmt(share + refunds, 6)} and ${mine() * 2} SCREDIT`); bump("balance"); bump("points"); render();
      }, S.collected),
      S.collected ? secondary("Start another batch", () => { reset(); render(); }) : null,
      h("p", { class: "hint" }, "SCREDIT can't be sent or sold. Bid it on Statements in the store."));
  }
}

// ───────── simulated other people ─────────
function advanceVote() {
  const others = S.votes - (S.voted ? mine() : 0);
  if (S.votes > 40) { S.phase = "back"; log(`Majority reached: minimum ${fmt(S.minimum, 2)} · ${S.votes}/80 voted`); }
  return others;
}
function checkAccept() { if (S.accept > 40) startPrint(); }
function expire() {
  for (const b of S.bids) if (b.who === ME) S.balance += b.amt;
  S.phase = "refunded"; S.high = null; S.bids = []; S.accept = 0; S.myAccept = false;
  log("Window closed without a majority · every bid refunded · nothing burned"); render();
}
function endAuction() {
  if (S.high.amt >= S.minimum) return startPrint();
  S.phase = "decide"; S.ends = Date.now() + 24 * 3600_000; S.accept = 0;
  log(`Auction ended at ${fmt(S.high.amt, 4)}, under the minimum · 24h to decide`); render();
}
function startPrint() {
  S.phase = "printing"; S.printed = 0; log("Sale locked in · burning 80 Credits"); render();
  const step = () => {
    S.printed += 1; drawSheet(S.printed); renderPanel();
    if (S.printed < 4) setTimeout(step, 650);
    else setTimeout(() => { S.phase = "sold"; log(`Statement #41 printed and delivered to ${S.high.who === ME ? "you" : S.high.who}`); render(); }, 700);
  };
  ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, cv.width, cv.height);
  setTimeout(step, 400);
}
const DEMO = {
  pick: [["Pick 12 for me", () => { wallet.slice(0, 12).forEach((c) => S.picked.add(c.id)); render(); }]],
  fill: [["Others fill the batch", () => {
    const need = 80 - S.batch.length;
    S.batch = S.batch.concat(Array.from({ length: need }, (_, i) => ({ ...credit(8000 + i * 29), who: "0x5f2…e1" })));
    S.phase = "vote"; log(`Batch full · 80/80 · ${need} more from 0x5f2…e1`); render();
  }]],
  vote: [["Others vote 0.40", () => { S.votes = Math.min(80, S.votes + 34); log("0x1a2b…11 and 4 others voted 0.40"); advanceVote(); render(); }]],
  back: [["A whale backs 0.36", () => { S.backings.push({ who: "0x7a3…c1", amt: 0.36 }); log("0x7a3…c1 backed the batch · 0.36 ETH held"); render(); }],
    ["Treasury backs 0.33", () => { S.backings.push({ who: "store treasury", amt: 0.33 }); log("The store treasury backed · 0.33 ETH"); render(); }]],
  refunded: [["A whale backs 0.38", () => { S.backings.push({ who: "0x9c1…04", amt: 0.38 }); log("0x9c1…04 backed · 0.38 ETH"); render(); }]],
  auction: [["Rival bid +5%", () => { const v = +(S.high.amt * 1.05).toFixed(4); if (S.high.who === ME) S.balance += 0; S.high = { who: "0x19f…0b", amt: v }; S.bids.push({ ...S.high }); log(`0x19f…0b bid ${fmt(v, 4)}`); render(); }],
    ["Skip to the end", () => { S.ends = Date.now(); endAuction(); }]],
  decide: [["Others accept", () => { S.accept = Math.min(80, S.accept + 30); log("Depositors holding 30 Credits accepted"); checkAccept(); render(); }],
    ["Let it expire", () => expire()]],
};

// ───────── render loop ─────────
function render() {
  renderTop(); renderRail(); if (S.phase !== "printing") drawSheet(); renderPanel();
  $("demo-actions").replaceChildren(...(DEMO[S.phase] ?? []).map(([l, fn]) => h("button", { onclick: fn }, l)));
}
setInterval(() => { const cd = $("cd"); if (cd) cd.textContent = left(); if (S.phase === "auction" && Date.now() >= S.ends) endAuction(); }, 1000);
$("restart").addEventListener("click", () => { reset(); render(); });
reset(); render();
