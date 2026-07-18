# VaultAdminFacet

**Source:** `contracts/src/facets/VaultAdminFacet.sol`
**Access:** every function `onlyGovernance` (== the ArthaTimelock)

## Purpose

Every governance action that shapes a vault: creation, strategy lifecycle, risk limits, and fees. Pause/unpause live in `VaultEmergencyFacet` instead, so an emergency response never needs a multi-day governance proposal.

## Functions

### Vault creation

**`createVault(baseAsset, name, symbol, idleTargetBps, minDeposit, tvlCap, depositCapPerBlock, withdrawCapPerBlock, performanceFeeBps, strategyMaxDeltaBps, harvestMaxImpactBps) returns (address vault)`**

Deploys a new `VaultShareToken` and sets the vault's full risk configuration in one call. Starts with zero strategies. `highWaterMarkPps` starts at `1e18` (the fee only ever charges on growth above the starting 1:1 price). `strategyMaxDeltaBps` must be non-zero (see Security notes).

### Strategy lifecycle

- **`addStrategy(vault, strategy, allStrategies, allWeightsBps, idleTargetBps)`** — registers a new strategy AND sets the full target-weight vector in the same call (add + reweight is atomic here — no window where the new strategy sits at an undeclared weight). Validates `strategy.vault() == address(this)` and `strategy.asset() == vault's base asset`.
- **`setTargets(vault, strategies, weightsBps, idleTargetBps)`** — updates target weights only. Does NOT move capital — see `VaultHarvestFacet.rebalance()` for execution. `sum(weightsBps) + idleTargetBps <= 10,000` (intentionally `<=`, not `==`: governance may widen the idle buffer beyond the stated target).
- **`setStrategyDisabled(vault, strategy, bool)`** — blocks NEW deploys into a strategy without unwinding it; existing capital keeps earning and is still withdrawn from in priority order.
- **`clearStrategyCircuitBreak(vault, strategy)`** — governance-reviewed clear of an automatic circuit-break (see `docs/formulas.md` §7).
- **`removeStrategy(vault, strategy, dustFloor)`** — fully harvests (hard-revert if it fails) and unwinds a strategy; unrecoverable dust below `dustFloor` is written off.
- **`migrateStrategy(vault, from, to)`** — atomically unwinds `from` and deploys the proceeds into `to`, carrying `from`'s target weight over unchanged. One call, no window where the capital's allocation sits idle between a separate remove and a separate add.

### Risk limits & fees

- `setCaps(vault, tvlCap, depositCapPerBlock, withdrawCapPerBlock, minDeposit)`
- `setCapExempt(vault, who, bool)` — exempt an address (e.g. a vetted institutional counterparty) from the per-block flow caps.
- `setPerformanceFee(vault, bps)` — hard-capped at `MAX_PERFORMANCE_FEE_BPS` (30%) in code, not just governance discretion.
- `setStrategyMaxDeltaBps(vault, bps)` / `setHarvestMaxImpactBps(vault, bps)`

### Protocol roles

- `setKeeper(address, bool)`, `setGuardian(address, bool)`, `setTreasury(address)`

## Security notes

- **`strategyMaxDeltaBps` cannot be 0.** Zero would silently mean "the NAV circuit breaker is off for this vault" — enforced at `createVault` and `setStrategyMaxDeltaBps` so this can never be an accident of a governance call that simply omitted the parameter. To genuinely run without an effective breaker, set `10,000` (100%), not 0.
- **Harvest-before-reallocate.** `removeStrategy` and `migrateStrategy` harvest the affected strategy first and hard-revert the whole call if that harvest fails — reallocating against stale, un-harvested value would mis-price exactly the capital being moved. `setTargets` itself does NOT harvest (it only updates stored config); the mandatory harvest happens in `VaultHarvestFacet.rebalance()`, which is what actually executes toward the new targets.
- `addStrategy`/`setTargets`/`removeStrategy`/`migrateStrategy` are all `nonReentrant`, since each makes external calls to the strategy contract being added/removed/migrated.
