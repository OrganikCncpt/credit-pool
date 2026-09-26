# Credits (Jack Butcher) — verified mainnet source, read-only reference

Address: `0x97630aA70AB14ed9883B41dAfccBc11349723043` (Ethereum mainnet)
Pulled from Sourcify on 2026-09-23 (full match). Compiled with solc 0.8.28 + OpenZeppelin v5.

Not built or deployed by this repo (forge only compiles `src/`, `test/`, `script/`).
Kept here so audits can read the exact code the pool integrates with:
`burn(owner, ids)` needs owner or approved-for-all, works only after `seal()`;
`tokensOf` / `_owned` tracking makes transfers cost more gas;
`seedOf` / `timestampOf` survive burns, so burned Credits still render via `art().svg()`.

The Statements contract is NOT published yet. The pool's `IStatementAssembler` is a placeholder.
