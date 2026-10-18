# ORIN contracts

The Solidity behind [ORIN](https://basescan.org/token/0x27bdeEdCcCA44975A48c083ffE119043506AeaDa)
on Base: a fixed-supply ERC-20, the factory that launches one and seeds its
Uniswap V3 pool in a single transaction, and the vesting pool that holds the
founder allocation.

| contract | address on Base |
|---|---|
| `CompanyToken` (ORIN) | [`0x27bdeEdCcCA44975A48c083ffE119043506AeaDa`](https://basescan.org/address/0x27bdeEdCcCA44975A48c083ffE119043506AeaDa#code) |
| `CompanyTokenFactory` | [`0xf68FE76b7fdec9074aa3C59b0F1B46a499073263`](https://basescan.org/address/0xf68FE76b7fdec9074aa3C59b0F1B46a499073263#code) |
| `AgentVestingPool` | [`0xA3959Ee7B66E524Ac5fE3934D6EeC1733ff13C1d`](https://basescan.org/address/0xA3959Ee7B66E524Ac5fE3934D6EeC1733ff13C1d#code) |

All three are verified on Basescan. **The verified source there is the
authoritative record of what was deployed.**

## Relationship to the deployed bytecode

Documentation comments in this repository were revised after deployment. The
executable logic is unchanged, but Solidity hashes the source text — comments
included — into the metadata appended to each contract, so a build from this
repository will not be byte-identical to what is on chain.

Compiling these sources and comparing against Base gives:

| contract | executable body | difference |
|---|---|---|
| `CompanyToken` | identical | metadata hash only |
| `AgentVestingPool` | identical | metadata hash only |
| `CompanyTokenFactory` | identical | its own metadata hash, plus the 32-byte `CompanyToken` metadata hash it embeds in order to deploy it |

Nothing else differs. To check that yourself, compile and compare the runtime
bytecode, ignoring the final metadata trailer — and note that the positions
holding `immutable` variables read as zeros in a local build and carry their
real values on chain (wNEWS, the Uniswap V3 factory and position manager in
`CompanyTokenFactory`; the ORIN token in `AgentVestingPool`).

If you need a byte-exact build, use the source published on Basescan.

## Build

```bash
npm ci
npx hardhat compile
```

The compiler settings in `hardhat.config.cjs` — 0.8.24, optimizer at 200 runs,
`cancun` — are the ones the deployed contracts were built with. Changing any of
them changes the output.

## Licence

MIT, matching the SPDX headers in each source file.
