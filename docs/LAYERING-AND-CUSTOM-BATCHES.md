# Custom batches and layering

**Status:** design, 2026-09-30. No code yet. Both features build on **sell first, burn second**
(`docs/SELL-FIRST-DESIGN.md`) and wait for Jack's Statements contract (checklist S-1..S-8 in
`docs/STATEMENTS-DESIGN.md`). A visual preview is at `app/preview.html` (mock data, no contract calls).

**Why these matter.** Jack (Sep 27): Statements print "like a printer, so the order and the color
determine the appearance of the output", and you can "keep layering them". Today every pooled Statement
prints in accidental deposit order ("random") and can never be layered. These two features are how
Credit Pool makes Statements look intentional, and they are where the value is.

---

## Part A: custom batches

Today there is one shared queue: batches fill in order and anyone's Credits go anywhere. Custom batches
let anyone open a batch with its own **rules**, alongside the default open queue (which stays).

### A1. Rules a batch can have

The creator sets these at creation. They are **immutable** once the first Credit is deposited.

| Rule | Options | Checked |
|---|---|---|
| **Colour / theme** | any of C, M, Y, K (e.g. "cyan only", "yellow + black") | on-chain at every deposit |
| **Traits** | Jack's traits (Print, Weight, Plates, Eights, …), Credit-number range | on-chain at every deposit |
| **Credit list** | exactly these Credit ids (up to 80) | on-chain |
| **Who can join** | anyone, or an invite list of addresses | on-chain |
| **Print order** | a preset (by number, grouped by colour, "misregistered", deposit order) **or** decided later by the arrangement vote (A3) | fixed before any sale |
| **Split** | equal per Credit (only option at launch; other splits later, only if they get their own review) | at payout |

The fee, 25/75 split, points, majority rules, 1-hour last call and backer offers are the same for every
batch. **The creator gets no powers after creation:** no fee, no cancel, no rule changes, no priority.
Creating costs one deposited Credit (the creator's own), which keeps spam down without a new fee.

### A2. How traits are checked safely

- **Nothing reads a price or an off-chain API.** A Credit's traits come from Jack's own on-chain data:
  `seedOf` plus the art contract's `describe()`.
- If calling `describe()` per deposit is too expensive in gas, we instead commit a **Merkle root of every
  Credit's traits** at deploy. A deposit then carries a proof for each Credit.
- That root is **checked in the test suite against Jack's on-chain art for all 122,154 Credits**. Anyone
  can recompute it, and it can't be changed after deploy.
- Gas: about 30k per proof check. Filtered batches get smaller deposit chunks on the site, sized
  under the per-transaction cap.

### A3. Arrangement vote (print order)

- **Proposing.** Once a batch is full, anyone can propose an order of its 80 Credits. The site generates
  presets. The contract checks only that the proposal is **exactly this batch's 80 ids, each once**.
- **Voting.** Depositors vote, weighted by Credits. The order is adopted with **more than 40 of 80 slots**.
- **Default.** Without an adopted order, the batch's creation preset applies. For the open queue that is
  Credit number ascending, **never** on-chain randomness: the caller of a permissionless burn could pick
  the "random" outcome.
- **Frozen before sale.** The order locks when an auction or last call starts, so buyers see exactly what
  prints.

### A4. Safety

- **Custody is unchanged.** One pool holds all Credits, the vault reaches only the batch being burned, and
  rules only restrict what can be deposited.
- **Invariants:**
  - every deposited Credit satisfies its batch's rules;
  - rules never change after the first deposit;
  - no creator power.
- **Tests:**
  - fuzz eligibility against the full trait table;
  - one attack test per rule (wrong colour, forged proof, a non-invited address, a proposal with a
    duplicate or foreign id);
  - gas for the worst filtered 100-Credit deposit.

---

## Part B: layering (back a Statement with Credits)

A **layer batch** prints its Credits onto an existing Statement (the **canvas**) instead of making a new one.
The result is one darker, richer Statement whose layers stay browsable on-chain.

### B1. Where canvases come from

1. **Store canvases (first version).** The store offers Statements it holds as canvases. Layer depositors
   earn points as usual.
   - When the layered Statement sells, the canvas's share of the sale goes to the **treasury**, and the layer's
     share goes to the layer's depositors.
   - The treasury can also back the layer itself (a backer offer), in which case the store keeps the richer
     Statement for its SCREDIT auction.
2. **Your own Statement (second version).** A Statement owner opts in and deposits it as a canvas. People
   add Credits to "back" it. When it sells, the proceeds split between the owner (the canvas's slots) and
   the layer's depositors (one slot per Credit).
   - The canvas owner can withdraw it any time before a sale is locked in, which returns the layer
     depositors' Credits unburned.

### B2. The sale and the split

- Layering follows sell first: **a layer burns only when a buyer or backer is locked in.** That means a
  winning auction bid at the majority minimum, or a majority-accepted offer after its 1-hour last call.
  Then, in one transaction:
  1. burn the layer onto the canvas;
  2. verify it printed;
  3. deliver the layered Statement to the buyer;
  4. book the payouts.
- **Split by slots:** the canvas counts **80 slots per existing layer** (the default; the canvas owner can
  set a different number at opt-in), and each layered Credit counts 1.
  - Example: a 1-layer canvas plus one 80-Credit layer is 160 slots. The canvas owner gets 80/160, and
    depositors get 1/160 per Credit.
- **Who votes:** layer depositors vote the layer's minimum price and print order. The canvas owner has a
  veto on the minimum: its own minimum. A sale needs both to be met.

### B3. What must be confirmed from Jack's contract (S-4)

- Who may add a layer: only the Statement's owner, or anyone it approves? The pool must be able to do it
  while holding the canvas.
- Is a layer exactly 80 Credits, or any number? Is there a maximum number of layers?
- Does layering mint anything, or only update the existing Statement? **Can we read a layer count or
  history on-chain?** The vault needs that to verify a layer really printed. This is the new custody check.
- Does colour or order work per layer the same way as the first print?

### B4. Safety (on top of the sell-first invariants)

| # | Invariant |
|---|---|
| L1 | A canvas held by the pool leaves only to (a) its owner, before a sale is locked, or (b) the buyer, in FINALIZE. |
| L2 | A layer burns only onto its own batch's canvas, only in FINALIZE, and only if the canvas's layer count rose by exactly one. Otherwise everything unwinds. |
| L3 | Payout = sale price split exactly by canvas slots + layer slots; Σ payouts ≤ price, with rounding dust < slots. |
| L4 | A canvas can't be in two layer batches at once, and can't be withdrawn while a sale is locked. |
| L5 | A failed layer burn loses no Credit, no canvas and no wei (full unwind, as in sell-first §5). |

**Threats and defences:**

| Threat | Defence |
|---|---|
| Canvas owner pulls the canvas at the last second | Blocked while an auction or last call is live |
| A layer printed onto the wrong Statement | Vault checks the canvas id and layer delta |
| A canvas swapped for a lookalike | Canvas id bound to the batch and its composition nonce |
| Owner sets absurd canvas slots | Visible before anyone deposits and fixed at opt-in; depositors choose whether to join |

---

## Order of work

1. **Arrangement vote** (A3). It is the smallest piece and fixes the "random" look for every batch.
2. **Custom batches: colour/theme rules, then traits and lists** (A1–A2).
3. **Layering on store canvases** (B1.1).
4. **Layering on your own Statement** (B1.2).

Each step goes through the ultra-safe gate from the sell-first doc:
- invariants and attack tests;
- proofs for custody;
- fork tests against Jack's real contract;
- a full internal audit;
- Sepolia;
- an external audit before mainnet.
