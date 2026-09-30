# Statements: order, colour and layering

**Status:** design only, 2026-09-29. No code changes yet. Jack's Statements contract is expected
around October 1. Everything marked **Unconfirmed** gets checked against his published code before
anything is built.

## What we know

This comes from Jack Butcher's posts on X, Sep 27. It is not from contract code.

- **Printer model.** "Layering statements behaves like a printer, so the order and the color determine
  the appearance of the output." Credits carry CMYK ink (cyan, magenta, yellow, black). The order they
  are printed in, combined with each Credit's colour, produces the image. His examples show clearly
  different, deliberate styles: "4x cyan", "4x yellow then 1x black", "4x random", "2x misregistered".
- **Layering.** "Assemble 80 credits into a statement and stop, or keep layering them. … the more you layer
  the darker the print, you will be able to navigate through each layer in the token view and all
  history/layers will be preserved onchain."

## What this means for Credit Pool today

- **Our Statements come out "random".** `_deposit` burns in deposit order, and `withdraw`'s swap-and-pop
  shuffles that order further. Every pooled Statement is effectively the "random" style, and depositors
  can't choose anything else. Competitors already let pools arrange their Credits.
- **Arrangement is value.** The same 80 Credits can print very differently, so the chosen order feeds
  directly into the sale price, and from there into depositors' payouts.
- **Layering breaks an assumption.** `CreditPool.assemble` and `AssemblyVault` require exactly one **new**
  Statement per 80 Credits. Printing onto an existing Statement would mint nothing new. It also means
  fewer than 1,526 Statements may ever exist.

## Design 1: arrangement vote (per batch)

The goal is to let a batch's depositors choose the print order without the contract needing to
understand art.

1. **Propose.** Once a batch is Full, anyone can propose an arrangement: an ordered list of that batch's
   80 Credit ids. The site builds proposals for them: sorted by colour, by Credit number, "misregistered",
   or a painted layout. The contract checks only that the list is **exactly the batch's own 80 ids, each
   once**. That check is O(80) with a bitmap or sorted comparison.
2. **Vote.** Depositors back one proposal, weighted by their slots, just like the reserve vote. An
   arrangement is adopted once more than 40 of the 80 slots back it.
3. **Burn.** `assemble` passes the adopted order to Statements. Without an adopted arrangement it uses a
   **fixed, documented default**, such as Credit number ascending, not the accidental deposit order.
   The default is written into the contract and shown on the site, so nobody is surprised.
4. **Never on-chain randomness.** `assemble` is permissionless, so any "random" choice made from block data
   would really be picked by whoever calls it, by timing the call. If a batch wants the "random" look, it
   votes for a proposal that was shuffled off-chain.

Open questions:
- Should the vote be allowed while the batch is still Filling? Probably not, because the ids aren't final.
- Is there a deadline? A batch shouldn't be stuck waiting for a vote. Assembly always stays possible
  with the default order.
- Proposal spam: cap the proposals per batch, or charge a small deposit to propose.
- Custody is unchanged. The vault still holds only this batch's 80 Credits and still verifies they were
  burned. Only the order of the list changes.

## Design 2: colour-themed batches (later)

Batches that only accept Credits of one colour (for example a "cyan batch"), so pooled Statements come
out coherent.
- Needs each Credit's colour on-chain at deposit time. Jack's art contract exposes `describe(seed, paidAt)`,
  which returns colours and plates. Check its gas cost before calling it on every deposit, or use a
  precomputed table that anyone can verify.
- This changes the single shared queue into several queues, one per theme. It's a bigger product change,
  so decide after Design 1 ships.

## Design 3: layering mode (after Jack's contract)

Ideas to evaluate once the real layering rules are known:
- **Store layering:** pooled batches print onto a Statement the store treasury holds, making it richer
  before its SCREDIT auction.
- **Member layering:** a pool prints onto a Statement one of its members owns (that member's approval is
  needed).
- Custody changes: the vault would have to verify "the Statement gained a layer" instead of "a new
  Statement appeared". That is a new check in the most sensitive code path, so it needs a full audit.

## Checklist: confirm from Jack's published contract

| # | Question | Why it matters |
|---|---|---|
| S-1 | The exact assemble/print function signature, and whether it takes an order or a "direction" parameter | Our placeholder `IStatementAssembler` only passes ids |
| S-2 | How order maps to the print: grid position, ink/layer order, or both | Decides what an "arrangement" means and what the site should propose |
| S-3 | Does colour come only from each Credit's own data, or is it chosen at print time? | Design 2, and whether there's another parameter to vote on |
| S-4 | Layering rules: who may add a layer, whether it's exactly 80 Credits, whether the Statement's owner must approve, and whether a layer mints anything | Design 3, and our "exactly one new Statement" checks |
| S-5 | Is there any randomness inside Jack's contract (for example misregistration)? What is it seeded by? | If the caller can influence it, `assemble` timing becomes a lever |
| S-6 | Do layers or the order count toward the 1,526 cap? | The cap guard on deposits (OK-2) |
| S-7 | Everything in OK-1..OK-5 and `AUDIT-SCOPE.md` §6 | Contract callers, signatures, per-address caps, mint recipient, burn vs escrow, transfer restrictions |
