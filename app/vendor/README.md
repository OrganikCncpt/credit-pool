# Vendored viem

`viem.js` and `viem-accounts.js` are minified ESM bundles of **viem 2.56.8**, served from
this site so no third-party code loads at runtime (no CDN, no supply-chain dependency).

| File | Exports | sha256 |
|---|---|---|
| `viem.js` | createPublicClient, createWalletClient, custom, http, parseAbi, formatEther, parseEther, defineChain | `deee83f95d91b85519c8a7df2484eadd9b7b26d94bfc5404419862a5b5d929cb` |
| `viem-accounts.js` | privateKeyToAccount (local demo `?dev=` mode only) | `5e927228266b7e01666b828994b512b686a32b34e11ca76d03602d4b6df1b1bd` |

Rebuild (same output for the same versions):

```bash
npm init -y && npm install viem@2.56.8 esbuild@0.25
echo 'export { createPublicClient, createWalletClient, custom, http, parseAbi, formatEther, parseEther, defineChain } from "viem";' > entry.js
echo 'export { privateKeyToAccount } from "viem/accounts";' > entry-accounts.js
npx esbuild entry.js --bundle --format=esm --minify --target=es2022 --legal-comments=eof --outfile=viem.js
npx esbuild entry-accounts.js --bundle --format=esm --minify --target=es2022 --legal-comments=eof --outfile=viem-accounts.js
```
