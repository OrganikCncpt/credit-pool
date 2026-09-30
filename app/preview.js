// Design preview only: mock Credits, no contract calls. Simulates Jack's printer model: each Credit
// is a 5×5 mark in one CMYK ink; a Statement is 80 of them on an 8×10 sheet; order and colour decide
// the look; layers print on top with multiply, so more layers print darker.
const INK = { c: "#00a3e0", m: "#e0007a", y: "#f5d000", k: "#111111" };
const INKS = ["c", "m", "y", "k"];
const $ = (id) => document.getElementById(id);

// Deterministic pseudo-random numbers, so the same mock Credit always draws the same mark.
function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
}
function mockCredit(id, ink) {
  const r = rng(id * 2654435761);
  const cells = Array.from({ length: 25 }, () => r() < 0.55);
  return { id, ink: ink ?? INKS[Math.floor(r() * 4)], cells, dx: Math.round(r() * 4 - 2), dy: Math.round(r() * 4 - 2) };
}
const shuffle = (a, seed) => { const r = rng(seed); a = a.slice(); for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };

// Draw one layer of 80 Credits onto a canvas (multiply blend over what's there).
function printLayer(ctx, credits, { misreg = false } = {}) {
  // 8 × 10 sheet centred on the canvas, with room for misregistration offsets.
  const px = 5, cell = 5 * px, gap = 12;
  const ox = (ctx.canvas.width - (8 * cell + 7 * gap)) / 2, oy = (ctx.canvas.height - (10 * cell + 9 * gap)) / 2;
  ctx.globalCompositeOperation = "multiply";
  credits.forEach((cr, i) => {
    const col = i % 8, row = Math.floor(i / 8);
    const x = ox + col * (cell + gap) + (misreg ? cr.dx * 2 : 0), y = oy + row * (cell + gap) + (misreg ? cr.dy * 2 : 0);
    ctx.fillStyle = INK[cr.ink];
    cr.cells.forEach((on, k) => { if (on) ctx.fillRect(x + (k % 5) * px, y + Math.floor(k / 5) * px, px, px); });
  });
  ctx.globalCompositeOperation = "source-over";
}
function blank(canvas) {
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, canvas.width, canvas.height);
  return ctx;
}

// ───────── 1. print order ─────────
const batch = shuffle(Array.from({ length: 80 }, (_, i) => mockCredit(1000 + i * 37)), 7); // deposit order
const ORDERS = {
  deposit: { name: "Deposit order (today)", credits: batch, slots: 18 },
  colour: { name: "Grouped by colour", credits: batch.slice().sort((a, b) => INKS.indexOf(a.ink) - INKS.indexOf(b.ink) || a.id - b.id), slots: 36 },
  number: { name: "By Credit number", credits: batch.slice().sort((a, b) => a.id - b.id), slots: 22 },
  misreg: { name: "Misregistered", credits: batch.slice().sort((a, b) => INKS.indexOf(a.ink) - INKS.indexOf(b.ink)), slots: 30, misreg: true },
};
let current = "deposit";
const voted = new Set();
function renderOrder() {
  const o = ORDERS[current];
  printLayer(blank($("order-canvas")), o.credits, { misreg: !!o.misreg });
  const slots = o.slots + (voted.has(current) ? 12 : 0);
  $("order-name").textContent = o.name;
  $("order-slots").textContent = String(slots);
  $("order-bar").style.width = `${(slots / 80) * 100}%`;
  $("order-vote").textContent = voted.has(current) ? (slots > 40 ? "Adopted: this order will print" : "You voted for this order") : "Vote for this order (your 12 slots)";
  $("order-vote").disabled = voted.has(current);
  for (const b of $("order-presets").querySelectorAll("button")) b.classList.toggle("pv-active", b.dataset.order === current);
}
$("order-presets").addEventListener("click", (e) => { const b = e.target.closest("button"); if (b) { current = b.dataset.order; renderOrder(); } });
$("order-vote").addEventListener("click", () => { voted.clear(); voted.add(current); renderOrder(); });
renderOrder();

// ───────── 2. custom batches ─────────
const themeInks = new Set(INKS);
function renderTheme() {
  const inks = [...themeInks];
  const pool = Array.from({ length: 80 }, (_, i) => mockCredit(5000 + i * 53, inks.length ? inks[i % inks.length] : "k"));
  const preset = $("preset").value;
  let credits = pool;
  if (preset === "colour" || preset === "misreg") credits = pool.slice().sort((a, b) => INKS.indexOf(a.ink) - INKS.indexOf(b.ink));
  if (preset === "vote") credits = shuffle(pool, 3);
  printLayer(blank($("theme-canvas")), credits, { misreg: preset === "misreg" });
}
$("theme").addEventListener("click", (e) => {
  const b = e.target.closest("button"); if (!b) return;
  themeInks.has(b.dataset.ink) ? themeInks.delete(b.dataset.ink) : themeInks.add(b.dataset.ink);
  if (!themeInks.size) themeInks.add(b.dataset.ink); // at least one colour
  b.classList.toggle("on", themeInks.has(b.dataset.ink));
  renderTheme();
});
$("preset").addEventListener("change", renderTheme);
$("create-go").addEventListener("click", renderTheme);
renderTheme();

const EXAMPLES = [
  { name: "Open queue", inks: INKS, rule: "any Credit · order: by number", fill: 50, who: "anyone" },
  { name: "Cyan only", inks: ["c"], rule: "cyan · grouped by colour", fill: 64, who: "anyone" },
  { name: "Yellow then black", inks: ["y", "k"], rule: "yellow + black · by colour", fill: 23, who: "anyone" },
  { name: "Heavy print club", inks: INKS, rule: "Print: Heavy · misregistered", fill: 71, who: "invite list" },
];
$("example-batches").replaceChildren(...EXAMPLES.map((x) => {
  const card = document.createElement("div"); card.className = "pv-batch";
  const top = document.createElement("div"); top.className = "row";
  const b = document.createElement("b"); b.textContent = x.name;
  const inks = document.createElement("span"); inks.className = "inks";
  for (const k of x.inks) { const i = document.createElement("i"); i.style.background = INK[k]; inks.append(i); }
  top.append(b, inks);
  const rule = document.createElement("span"); rule.className = "muted small"; rule.textContent = x.rule;
  const bar = document.createElement("div"); bar.className = "pv-bar";
  const fillEl = document.createElement("i"); fillEl.style.width = `${(x.fill / 80) * 100}%`; fillEl.style.background = "var(--c)"; bar.append(fillEl);
  const meta = document.createElement("span"); meta.className = "muted small"; meta.textContent = `${x.fill}/80 · ${x.who}`;
  card.append(top, rule, bar, meta);
  return card;
}));

// ───────── 3. backed auctions ─────────
const FLOOR = 0.0045, MINIMUM = 0.40;
const backings = [
  { who: "0x7a3…c1", eth: 0.36 },
  { who: "store treasury", eth: 0.33 },
];
let phase = "full";          // full → auction → accept → sold | refunded
let high = 0, highWho = "", ends = 0, acceptSlots = 0, timer3 = null;
const fmtLeft = (ms) => { const s = Math.max(0, Math.floor(ms / 1000)); return `${String(Math.floor(s / 3600)).padStart(2, "0")}:${String(Math.floor(s / 60) % 60).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`; };
function renderBackings() {
  const sorted = backings.slice().sort((a, b) => b.eth - a.eth);
  $("backings").replaceChildren(...sorted.map((o, i) => {
    const tr = document.createElement("tr");
    const per = o.eth / 80;
    for (const c of [o.who, `${o.eth.toFixed(2)} ETH`, per.toFixed(4), `${per >= FLOOR ? "+" : ""}${(((per - FLOOR) / FLOOR) * 100).toFixed(0)}%`]) {
      const td = document.createElement("td"); td.textContent = c; tr.append(td);
    }
    const td = document.createElement("td"); td.className = "muted small";
    td.textContent = i > 0 ? "fallback"
      : phase === "full" ? "opens the auction"
      : o.who === highWho && phase !== "refunded" ? "committed"
      : "outbid · refunded";
    tr.append(td);
    return tr;
  }));
  $("ba-start").disabled = phase !== "full" || !backings.length;
  $("ba-back").disabled = phase !== "full";
}
function renderAuction() {
  $("ba-auction").hidden = phase === "full";
  $("ba-bid").textContent = `${high.toFixed(4)} ETH`; $("ba-who").textContent = highWho;
  $("ba-auction-actions").hidden = phase !== "auction";
  $("ba-accept").hidden = phase !== "accept";
  $("ba-accept-slots").textContent = String(acceptSlots);
  $("ba-accept-bar").style.width = `${(acceptSlots / 80) * 100}%`;
  const tags = { auction: ["auction", "Auction", "left · opened with the best backing"], accept: ["accept window", "Assembled", "left for depositors to accept (41/80)"], sold: ["sold · burned", "Settled", ""], refunded: ["refunded · not burned", "Full", ""] };
  if (tags[phase]) { $("ba-phase").textContent = tags[phase][0]; $("ba-phase").className = `tag ${tags[phase][1]}`; $("ba-phase-note").textContent = tags[phase][2]; }
  $("ba-tag").textContent = phase === "sold" ? "sold · burned" : phase === "auction" ? "backed · auction live" : phase === "accept" ? "backed · accept window" : "full · not burned";
  renderBackings();
}
function tick3() {
  const left = ends - Date.now();
  $("ba-left").textContent = phase === "sold" || phase === "refunded" ? "done" : fmtLeft(left);
  if (left <= 0 && phase === "auction") endAuction();
  else if (left <= 0 && phase === "accept") expire();
}
function finalize(price, who) {
  phase = "sold"; clearInterval(timer3);
  $("ba-result").textContent = `FINALIZE: burned the 80 Credits, Statement delivered to ${who}, ${price.toFixed(4)} ETH split to depositors. ` +
    `Your 12 slots: ${((price / 80) * 12).toFixed(4)} ETH to collect.`;
  renderAuction(); tick3();
}
function endAuction() {
  if (high >= MINIMUM) return finalize(high, highWho);
  phase = "accept"; ends = Date.now() + 24 * 3600_000; acceptSlots = 0;
  $("ba-result").textContent = `Ended at ${high.toFixed(4)} ETH, below the 0.40 minimum. Depositors have 24h to accept it by majority.`;
  renderAuction();
}
function expire() {
  phase = "refunded"; clearInterval(timer3);
  $("ba-result").textContent = `Not accepted in 24h: ${highWho} refunded ${high.toFixed(4)} ETH, nothing burned, the Credits are still yours. ` +
    `Fallback backings are still posted for another round.`;
  renderAuction(); tick3();
}
$("ba-back").addEventListener("click", () => {
  const v = Number($("ba-amount").value);
  if (!(v > 0)) return;
  const mine = backings.find((b) => b.who === "you");
  mine ? (mine.eth = v) : backings.push({ who: "you", eth: v });
  renderBackings();
});
$("ba-start").addEventListener("click", () => {
  const best = backings.slice().sort((a, b) => b.eth - a.eth)[0];
  phase = "auction"; high = best.eth; highWho = best.who; ends = Date.now() + 24 * 3600_000;
  $("ba-result").textContent = "";
  clearInterval(timer3); timer3 = setInterval(tick3, 1000); renderAuction(); tick3();
});
$("ba-outbid").addEventListener("click", () => {
  high = high * 1.05; highWho = highWho === "you" ? "0x19f…0b" : "you";
  if (ends - Date.now() < 15 * 60_000) ends = Date.now() + 15 * 60_000;
  renderAuction(); tick3();
});
$("ba-end").addEventListener("click", () => { ends = Date.now(); tick3(); });
$("ba-accept-vote").addEventListener("click", () => { acceptSlots = Math.min(80, acceptSlots + 12); $("ba-accept-vote").disabled = true; check(); });
$("ba-others").addEventListener("click", () => { acceptSlots = Math.min(80, acceptSlots + 18); check(); });
$("ba-expire").addEventListener("click", () => { ends = Date.now(); tick3(); });
function check() { renderAuction(); if (acceptSlots > 40) finalize(high, highWho); }
renderBackings();

// ───────── 4. layering ─────────
const layerInks = ["c"];
let nextInk = "c";
function renderLayers() {
  const n = Number($("layers").value);
  while (layerInks.length < n) layerInks.push(nextInk);
  layerInks.length = n;
  const ctx = blank($("layer-canvas"));
  layerInks.forEach((ink, L) => {
    const credits = Array.from({ length: 80 }, (_, i) => mockCredit(9000 + L * 811 + i * 17, ink));
    printLayer(ctx, credits, { misreg: L > 0 });
  });
  $("layers-n").textContent = String(n);
  const mine = Math.max(1, Math.min(80, Number($("mine").value) || 1));
  const canvasSlots = 80 * n, total = canvasSlots + 80;
  $("split").textContent = `When it sells: canvas (store treasury) ${canvasSlots}/${total} · this layer's depositors 80/${total} · ` +
    `your ${mine} Credits = ${((mine / total) * 100).toFixed(1)}% of the sale, plus ${mine * 2} SCREDIT.`;
}
$("layers").addEventListener("input", renderLayers);
$("mine").addEventListener("input", renderLayers);
$("layer-inks").addEventListener("click", (e) => {
  const b = e.target.closest("button"); if (!b) return;
  nextInk = b.dataset.ink;
  for (const x of $("layer-inks").querySelectorAll("button")) x.classList.toggle("on", x === b);
});
renderLayers();
