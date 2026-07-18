# VaultViewFacet

**Source:** `contracts/src/facets/VaultViewFacet.sol`
**Access:** anyone (all functions are `view`)

## Purpose

Every read a frontend, integrator, or another protocol needs. All value reads price against the last CHECKPOINTED NAV (see `docs/formulas.md` §1) — call `VaultHarvestFacet.settle(vault)` first if a caller specifically needs a just-refreshed number.

## Functions

- `totalAssets(vault)`, `pricePerShare(vault)` — the checkpointed NAV and derived price.
- `previewDeposit(vault, assets)`, `previewMint(vault, shares)`, `previewWithdraw(vault, assets)`, `previewRedeem(vault, shares)` — the standard ERC-4626 preview set, using the same rounding directions as the real operations (`docs/formulas.md` §2).
- `maxWithdraw(vault, owner)` / `maxRedeem(vault, owner)` — bounded by BOTH the owner's own share balance AND the vault's actual available liquidity (idle + what every healthy strategy's own `maxWithdraw()` reports it could give up right now). A broken strategy contributes nothing to this figure.
- `availableLiquidity(vault)` — the raw liquidity figure `maxWithdraw`/`maxRedeem` are bounded by.
- `vaultConfig(vault) returns (VaultConfigView)` — a single-call batch read of every vault-level parameter (base asset, idle target, caps, fee, high-water mark, NAV, supply, price, paused state) for frontends that want one call instead of a dozen.
- `strategyList(vault)`, `strategyWeightBps(vault, strategy)`, `strategyStatus(vault, strategy) returns (disabled, broken, lastValue)`, `allVaults()`, `isCapExempt(vault, who)`.

## Security notes

Purely read-only — no state changes, no access control needed beyond the vault existing. `_availableLiquidity` skips broken strategies rather than reverting the whole call if one strategy's read is stale/untrusted.
