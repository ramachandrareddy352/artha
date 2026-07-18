# VaultHarvestFacet

**Source:** `contracts/src/facets/VaultHarvestFacet.sol`
**Access:** `onlyKeeper` for everything except `settle`, which is fully permissionless

## Purpose

Keeps a vault's NAV fresh and its capital allocated toward target weights: harvesting, deploying idle capital, and rebalancing.

## Functions

- **`harvest(vault, strategy) returns (uint256 realized)`** — `onlyKeeper`. Targets ONE strategy explicitly; a failure propagates (the keeper asked for this specific strategy — it should see the revert and react, not silently no-op). Refreshes NAV after.
- **`harvestAll(vault)`** — `onlyKeeper`. Best-effort sweep across every active strategy (`try/catch` per strategy — one stuck strategy never blocks harvesting the others). Refreshes NAV once at the end.
- **`settle(vault)`** — **permissionless**. Forces a fresh NAV checkpoint (and crystallizes the performance fee if a new price-per-share peak is reached) with no claim and no swap — just re-reads what each strategy already reports.
- **`deployIdle(vault)`** — `onlyKeeper`. Pushes idle capital above the target buffer into under-allocated strategies, in priority order. Never withdraws from a strategy, so it does not need a mandatory pre-move harvest.
- **`rebalance(vault)`** — `onlyKeeper`. The heavier operation: harvests every active strategy FIRST (hard-reverts the whole call if any harvest fails), then pulls excess out of over-allocated strategies into idle (pass 1) and deploys the freed capital into under-allocated strategies (pass 2).

Worked examples for `deployIdle` and `rebalance`, including a full target-weight-change walkthrough, are in `docs/formulas.md` §8.

## Security notes

- **`harvest()` vs `harvestAll()` failure semantics are deliberately different** — see Functions above. A direct, explicit single-strategy call should surface its own failure; a routine batch sweep should not let one bad actor block the rest.
- **`rebalance()`'s hard-revert-on-harvest-failure is deliberate**, unlike the withdrawal path's best-effort harvest — reallocating capital against stale, un-harvested value would mis-price exactly the capital being moved. Wait for conditions to improve and retry, rather than proceeding on a stale number.
- **No intra-strategy claim/sell split.** Every strategy's `harvest()` (see `BaseStrategy`) claims reward tokens and swaps them to base in one atomic call today. What this facet adds is ORCHESTRATION-level resilience (one strategy's stuck swap never blocks another strategy's harvest in the same batch) — a true claim-always-succeeds-even-if-sell-fails split would require changing `BaseStrategy`'s hooks across every concrete strategy file. Documented as a scoped-out follow-up in `docs/formulas.md` §9, not silently treated as done.
- All functions are `nonReentrant`.
