# Artha Protocol — Security Audit Report

**Auditor:** AI security review (Claude), following `AUDIT_PROMPT.md`
**Date:** 2026-07-19
**Scope reviewed:** `contracts/src/**` (Diamond core, 9 facets, 7 vault libraries, `VaultShareToken`, oracle, a representative set of strategies + `BaseStrategy` + swappers, rewards, referral, governance)
**Ground truth used:** `contracts/docs/**` + the Solidity source. The root `README.md` (v4 ERC-721 design) was treated as **stale**, per `docs/architecture.md §7`.
**Commit state:** git `9d8c3b5` ("intial setup completed, review in pending"). **Zero tests exist** (`test/` is empty) — factored into every finding below.

> Note on method: findings are grounded in specific lines. Exploit paths are described as ordered sequences rather than Foundry PoCs (per request). Confidence is marked per finding; the two most important (H-01, H-02) are Confirmed by re-deriving the arithmetic and tracing state.

---

## 1. Executive summary

The architecture is thoughtful and unusually well-documented, and the highest-risk primitives (virtual-offset inflation defense, rounding discipline, checkpointed NAV, harvest-before-reallocate, asymmetric pause, keeper/guardian least-privilege, Diamond storage separation, OZ Governor/Timelock wiring) are implemented correctly. The Diamond, `LibDiamond`, governance stack, and `VaultShareToken` are clean.

However, two issues undermine core guarantees:

- **The performance fee can never be charged** (H-01). The high-water mark is initialized to `1e18` while the vault's natural price-per-share is exactly `1e12` (a factor of `10^DECIMALS_OFFSET` too high). The entire fee/HWM subsystem is inert on every vault. A worked example in `docs/formulas.md` is itself arithmetically wrong by the same `10^6`, which is why this was not caught.
- **A single strategy loss becomes a first-come-first-served race** (H-02). When a strategy is circuit-broken or reverts, its **stale last-known value keeps counting in NAV**, so redemptions price against an inflated NAV and are paid out of the *healthy* strategies/idle. Early exiters leave whole; late exiters absorb the entire loss. `emergencyWithdraw` amplifies this (prices against the stale checkpoint and cannot be paused).

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 2 |
| Medium | 5 |
| Low | 5 |
| Informational | 4 |
| Gas | 1 |

**Systemic themes:** (1) price-per-share scale vs. HWM/fee accounting; (2) stale-NAV redemption fairness under the fail-safe circuit breaker; (3) oracle hardening gaps (Pyth confidence, Chainlink bounds, L2 sequencer, feed-decimals assumption); (4) withdrawal-queue/cooldown venues not modeled; (5) **zero test coverage** across ~8,000 lines.

---

## 2. Scope, methodology & ground-truth notes

- **Authoritative:** code + `docs/`. `README.md` documents a superseded ERC-721 design and must not be used as spec (see I-01).
- **Trusted:** OZ / forge-std libraries (verified *usage*, not internals). Governance (Timelock) is trusted-but-rail-capped.
- **Zero-test caveat:** there is no invariant/fork/differential suite. Every High/Medium below is a path no test currently exercises; a suite is the single highest-leverage remediation.
- **Coverage:** all core vault contracts read in full; strategies sampled across each "shape" (`BaseStrategy`, `AaveV3UsdcStrategy`, `ERC4626WrapperStrategy`, `CrossAssetERC4626Strategy`/`EthenaSUsdeStrategy`, `UniswapV3Swapper`). The ~30 remaining concrete strategies were not each read line-by-line; findings about the base/cross-asset patterns propagate to their subclasses.

---

## 3. Findings

### [HIGH] H-01 — Performance fee can never crystallize: high-water mark initialized `10^DECIMALS_OFFSET` too high

- **ID:** ART-H-01
- **Severity:** High (Impact: protocol revenue = 0, and a stated safety mechanism is inert / High · Likelihood: certain, every vault / Certain)
- **Location:** [src/facets/VaultAdminFacet.sol:91](src/facets/VaultAdminFacet.sol#L91), [src/libraries/LibVaultMath.sol:96-102](src/libraries/LibVaultMath.sol#L96-L102), [src/libraries/LibVaultFee.sol:61-63](src/libraries/LibVaultFee.sol#L61-L63)
- **Confidence:** Confirmed.

**Description.** `createVault` seeds the mark at full scale:

```solidity
s.highWaterMarkPps[vault] = PPS_SCALE; // = 1e18
```

But the price-per-share formula divides by `supply + 10^DECIMALS_OFFSET`:

```solidity
pricePerShare = mulDiv(ta + 1, PPS_SCALE, supply + 10**DECIMALS_OFFSET, Floor);
```

At genesis the first depositor of `A` base units mints `A × 10^6` shares (`convertToSharesDown` with `supply=0, nav=0`). Therefore:

```
pps = (A + 1) · 1e18 / (A·1e6 + 1e6) = 1e18 / 1e6 = 1e12   (exactly, for any A, any decimals)
```

The natural price-per-share is **`1e12`**, i.e. `PPS_SCALE / 10^DECIMALS_OFFSET`, and it only ever rises *proportionally to yield*. `LibVaultFee.chargePerformanceFee` charges only when `pps > highWaterMarkPps`. Reaching `1e18` from `1e12` requires **1,000,000× growth** (≈ +99,999,900% return) — impossible. So `pps <= hwm` forever, the fee never mints, and the HWM never moves.

**Impact.** The protocol's only revenue mechanism (performance fee) collects **nothing**, on every vault, forever. The "true high-water mark" safety property is also inert (it never protects anything because it never engages). This is a silent, total failure of the fee subsystem.

**Attack scenario / demonstration (no attacker needed).**
1. `createVault(USDC, …, performanceFeeBps = 1000)` → `hwm = 1e18`.
2. Alice deposits 1,000,000 USDC → `pps = 1e12`.
3. Vault earns 50% over a year → `nav` ×1.5, `pps = 1.5e12`.
4. Any `settle`/deposit/withdraw runs `chargePerformanceFee`: `1.5e12 <= 1e18` → returns early. `treasury` receives 0 shares. Repeat indefinitely.

**Root cause & why missed.** `docs/formulas.md §2` computes this exact scenario as `pps ≈ 1,000 × 1e18` — but `1e9 × 1e18 / 1e15 = 1e12`, not `1e21`. The doc is wrong by `10^9`/`10^6`, masking the mismatch. See I-01.

**Recommendation.** Initialize the mark to the actual genesis pps:

```solidity
s.highWaterMarkPps[vault] = PPS_SCALE / (10 ** DECIMALS_OFFSET); // 1e12
```

…or, better, redefine `pricePerShare` so a "fair" share equals `1e18` at 1:1 and initialize the mark to `1e18` consistently. Add an invariant test: after N% yield, `treasury` share balance increases by exactly `feeBps%` of the profit; and a dip-then-recover charges no second fee. **Do not** simply lower the mark on an already-funded vault without care — a mark set below the *current* pps would retroactively charge on all historical growth at once.

---

### [HIGH] H-02 — Stale-NAV strategies keep counting at full value → strategy loss becomes a first-come redemption race (loss socialized onto last exiters)

- **ID:** ART-H-02
- **Severity:** High (Impact: late redeemers can lose their entire balance / High · Likelihood: conditional on a real strategy loss, but then trivially exploitable by anyone watching for the `StrategyCircuitBroken`/`StrategyReadReverted` event / Medium)
- **Location:** [src/libraries/LibVaultNav.sol:76-100](src/libraries/LibVaultNav.sol#L76-L100), [src/facets/VaultWithdrawFacet.sol:151-176](src/facets/VaultWithdrawFacet.sol#L151-L176), [src/facets/VaultEmergencyFacet.sol:83-139](src/facets/VaultEmergencyFacet.sol#L83-L139)
- **Confidence:** Confirmed (state traced).

**Description.** When a strategy either jumps beyond `strategyMaxDeltaBps` or reverts its `totalAssets()` read, `refreshNav` **keeps its last-known value in NAV**:

```solidity
if (broken) { totalAssets += s.strategyLastValue[vault][strat]; continue; }
// …suspicious jump…
s.strategyBroken = true; totalAssets += lastValue; continue;
// …revert…
catch { totalAssets += s.strategyLastValue[vault][strat]; }
```

This is a deliberate fail-safe (documented) so one bad venue can't freeze the whole vault. But the consequence is a solvency-fairness failure: if the strategy genuinely lost value (exploit, depeg, bad-debt socialization at the venue), NAV is now **overstated** by the shortfall, yet `_drain`/`redeem` pay withdrawals out of **idle + the still-healthy strategies** and *skip the broken one*:

```solidity
for (…) { if (s.strategyBroken[vault][strat]) continue; got = IStrategy(strat).withdraw(remaining); … }
```

So each redeemer during the frozen window burns shares priced at the **inflated** pps but is paid in **real** assets from the healthy pool. First movers exit at (near) full value; the shortfall concentrates entirely on whoever redeems last — they may recover nothing.

`emergencyWithdraw` makes it worse: it prices `entitlement = convertToAssetsDown(shares)` against the **stale checkpoint with no `refreshNav`** ([VaultEmergencyFacet.sol:92-95](src/facets/VaultEmergencyFacet.sol#L92-L95)) and is **not** gated by pause — so even a guardian pause (which blocks normal `withdraw`) cannot stop the race.

**Impact.** A partial, recoverable loss at one venue is amplified by protocol accounting into a bank run in which late/passive users bear 100% of the loss. Breaks pro-rata fairness; directly loses funds for the slowest users.

**Attack / exploitation sequence.**
1. Strategy C (say a cross-asset stable) suffers a real 40% loss; next `refreshNav` trips the breaker and freezes C at its old value. NAV is now overstated by ~C·0.4.
2. A watcher sees `StrategyCircuitBroken`. They (and everyone paying attention) call `redeem`/`emergencyWithdraw` immediately, paid in full from idle + healthy A/B at the inflated pps.
3. Idle and A/B drain. Remaining holders are left with shares against a vault whose only "asset" is the frozen, largely-worthless C position. `withdraw` reverts `INSUFFICIENT_LIQUIDITY`; `emergencyWithdraw` returns near-zero.

**Recommendation.**
- On a **downward** break or a revert, do **not** keep the full last-known value in NAV. Options: (a) mark the strategy's NAV contribution to a conservative floor (e.g. `maxWithdraw()` / an oracle-independent lower bound) rather than the stale high; (b) socialize the impairment immediately by writing down `strategyLastValue` to the last *successful* `withdraw`-implied value; (c) when any strategy is broken, switch redemptions to *pro-rata across available liquidity only* (ERC-4626 `maxWithdraw`-bounded) so no one can exit at the inflated price.
- Have `emergencyWithdraw` price against a freshly-refreshed, impairment-aware NAV (or against realized proceeds), and consider gating the *inflated* fast-exit under global pause while always allowing a *pro-rata* exit.
- Distinguish "read reverted" (unknown) from "value dropped sharply" (likely real loss) — they currently get identical fail-safe treatment.

---

### [MEDIUM] M-01 — Pyth price consumed without confidence-interval check (and via `getPriceUnsafe`)

- **ID:** ART-M-01
- **Location:** [src/oracle/sources/PythSource.sol:10-19](src/oracle/sources/PythSource.sol#L10-L19)
- **Confidence:** Confirmed.

`getPythPrice` reads `getPriceUnsafe(...)` and validates only `price > 0`, `publishTime != 0`, not-future, and staleness. It **ignores `p.conf`** (the confidence band). Pyth explicitly recommends rejecting or widening when `conf` is large relative to `price` (a wide band signals disagreement/illiquidity/manipulation). Because these prices feed reward valuation and cross-asset `_positionValue`/swap `minOut`, an attacker who forces a high-uncertainty publish can push the accepted price toward a favorable bound.

**Recommendation.** Require e.g. `p.conf * confBps / 1e4 <= uint64(p.price)` (reject when the band exceeds a governance-set fraction of price). Consider preferring `getPriceNoOlderThan` semantics. Verify the negative-exponent path `uint256(uint64(p.price))` and `_to8Decimals` against Pyth's signed price convention.

---

### [MEDIUM] M-02 — Chainlink reads don't check `minAnswer`/`maxAnswer` circuit bounds

- **ID:** ART-M-02
- **Location:** [src/oracle/sources/ChainlinkSource.sol:9-24](src/oracle/sources/ChainlinkSource.sol#L9-L24)
- **Confidence:** Plausible (aggregator-dependent).

Staleness/round-completeness checks are solid, but a feed that still uses `minAnswer`/`maxAnswer` will return the **clamped bound** during an extreme move (the classic LUNA/UST-style failure), which the strategy then trusts as truth. For reward valuation and cross-asset conversions this yields a systematically wrong price exactly when it matters.

**Recommendation.** Where the underlying aggregator exposes them, read `minAnswer`/`maxAnswer` and revert if `price` is at/through a bound; otherwise document per-feed that the aggregator has no such bounds. Pair with a per-token sanity band.

---

### [MEDIUM] M-03 — No L2 sequencer-uptime feed (if deployed on an L2)

- **ID:** ART-M-03
- **Location:** `src/oracle/PriceFeed.sol` (whole contract; no sequencer check)
- **Confidence:** Plausible (conditional on L2 deployment).

`docs`/`README` mention Arbitrum/OP/Base parameters. On an L2, right after sequencer downtime, Chainlink feeds can serve stale-but-"fresh-looking" data during the grace window. There is no `L2 Sequencer Uptime Feed` gate.

**Recommendation.** If any L2 deployment is intended, add the standard Chainlink sequencer-uptime check (uptime == up, and `block.timestamp - startedAt > GRACE_PERIOD`) before returning a price. If mainnet-only, document that explicitly and add a deploy guard.

---

### [MEDIUM] M-04 — Withdrawal-cooldown / queue venues (sUSDe, staking derivatives) can trap funds and block removal/migration

- **ID:** ART-M-04
- **Location:** [src/strategies/common/CrossAssetERC4626Strategy.sol:93-116](src/strategies/common/CrossAssetERC4626Strategy.sol#L93-L116), [src/strategies/usdc/yield/EthenaSUsdeStrategy.sol](src/strategies/usdc/yield/EthenaSUsdeStrategy.sol), [src/libraries/LibStrategyRegistry.sol:162](src/libraries/LibStrategyRegistry.sol#L162), [src/libraries/LibStrategyRegistry.sol:201](src/libraries/LibStrategyRegistry.sol#L201)
- **Confidence:** Confirmed (design gap).

`CrossAssetERC4626Strategy` assumes the target 4626's `withdraw`/`redeem` are synchronous. **sUSDe (Ethena) has a cooldown mode**: when enabled, `maxWithdraw` returns 0 and `withdraw`/`redeem` revert until `unstake`. Consequences:
- `_positionValue` (via `convertToAssets`) keeps reporting full value, so NAV counts capital that cannot currently be exited → the H-02 stale-value dynamics apply to a *live* strategy.
- Normal `withdraw` degrades (the strategy returns 0 and the queue moves on) — acceptable — but if it's the only liquidity, users can't exit.
- `emergencyWithdraw()` calls `_withdrawAll()` → `target.redeem(...)` which **reverts** during cooldown. In `removeStrategy`/`migrateStrategy` that call is **not** wrapped in try/catch ([LibStrategyRegistry.sol:162,201](src/libraries/LibStrategyRegistry.sol#L162)), so governance **cannot remove or migrate the strategy** until cooldown clears.

**Recommendation.** Model cooldown/queue venues explicitly: a two-step exit (`initiateWithdraw` → `completeWithdraw`), a `maxWithdraw` that reflects only *currently* claimable amounts, and a NAV contribution that discounts locked-but-cooling capital. Wrap the `emergencyWithdraw()` calls in `removeStrategy`/`migrateStrategy` so a temporarily-illiquid strategy can still be dropped (crediting whatever is realizable, writing the rest as pending).

---

### [MEDIUM] M-05 — `emergencyWithdraw` prices against a stale checkpoint and desyncs `navCheckpoint`

- **ID:** ART-M-05
- **Location:** [src/facets/VaultEmergencyFacet.sol:92-95](src/facets/VaultEmergencyFacet.sol#L92-L95), [src/facets/VaultEmergencyFacet.sol:114-132](src/facets/VaultEmergencyFacet.sol#L114-L132)
- **Confidence:** Confirmed.

Two concrete code-level issues (related to but distinct from H-02):
1. **Stale pricing:** `entitlement = convertToAssetsDown(shares)` uses `navCheckpoint` as-is with no `refreshNav`. If the checkpoint is stale-high, the caller's entitlement (and payout, funded from healthy assets) exceeds their true pro-rata share.
2. **Checkpoint desync:** the function sets each touched strategy's `strategyLastValue = 0` and adds any surplus to idle, but then updates NAV with a flat `navCheckpoint -= assetsReceived`. When a strategy frees **less** than its recorded `strategyLastValue` (`F < L`), the resulting checkpoint is **overstated by `L − F`** versus a true recomputation — transiently over-pricing shares until the next `refreshNav`.

**Recommendation.** Refresh (or at least conservatively re-read the touched strategies) before computing entitlement, and recompute `navCheckpoint` from components after the loop rather than decrementing by `assetsReceived`. At minimum, drop the touched strategies' `strategyLastValue` *before* summing and derive the new checkpoint from the post-state.

---

### [LOW] L-01 — Oracle assumes every feed reports 8 decimals; no `decimals()` read or rescale

- **ID:** ART-L-01
- **Location:** [src/oracle/sources/ChainlinkSource.sol:9-24](src/oracle/sources/ChainlinkSource.sol#L9-L24), [src/oracle/PriceFeed.sol:38-43](src/oracle/PriceFeed.sol#L38), [src/strategies/BaseStrategy.sol:190-206](src/strategies/BaseStrategy.sol#L190-L206)
- **Confidence:** Confirmed (trust-boundary).

`PriceFeed` documents that all feeds "MUST already report 8-decimal USD," and `ChainlinkSource` never reads `AggregatorV3Interface.decimals()`. Many Chainlink USD feeds are 8dp, but not all (e.g. some ETH-denominated feeds are 18dp). A single mis-registered feed silently mis-scales every reward valuation / cross-asset conversion by orders of magnitude. It's an oracle-admin trust issue, but a high-blast-radius footgun.

**Recommendation.** Read `feed.decimals()` at registration and store it; normalize to 8dp in `getChainlinkPrice`, or hard-require `decimals() == 8` at `setChainlinkConfig` time so a wrong feed reverts on configuration rather than on use.

---

### [LOW] L-02 — Staking emission has no `totalStaked` denominator: budget-drain and scale risk

- **ID:** ART-L-02
- **Location:** [src/rewards/UserRewardSystem.sol:126-145](src/rewards/UserRewardSystem.sol#L126-L145), [src/rewards/UserRewardVault.sol:141-165](src/rewards/UserRewardVault.sol#L141-L165)
- **Confidence:** Confirmed (design; documented but worth flagging).

`accRewardPerShare` integrates `rewardRate` over time **without** dividing by total staked, so ARTHA emitted = `rewardRate × (Σ staked shares) × time`, bounded only by `MAX_ARTHA` and the on-hand balance. Because vault shares are 18dp and roughly `10^6×` the base-asset units, a plausible-looking `rewardRate` can emit far more than intended, draining the 10M budget quickly; thereafter claims silently partial-fill on liquidity. This is a real operational/mis-config hazard rather than a theft vector.

**Recommendation.** Document the emission's dimensional analysis prominently and bound `rewardRate` (and/or a per-vault emission ceiling) on-chain. Add alerting on `arthaRemaining()` / `outstandingArtha()` vs. balance.

---

### [LOW] L-03 — ReferralVault commission path is never invoked by the vault (dead integration / model mismatch)

- **ID:** ART-L-03
- **Location:** [src/referral/ReferralVault.sol:392-430](src/referral/ReferralVault.sol#L392-L430), `src/facets/VaultWithdrawFacet.sol` (no referral call)
- **Confidence:** Confirmed.

`ReferralVault.settlePerformanceFee` expects a per-trader, per-withdrawal base-token fee (`onlyCaller(vault)` ⇒ the Diamond must call it), but the vault's fee is vault-wide HWM realized by share-minting and the withdraw path never calls it. `docs/formulas.md §9` acknowledges this as out-of-scope, but the `ReferralVault` NatSpec presents integration code that does not exist in the vault — a maintainer could wrongly assume referral commissions flow. As written, the whole commission/discount subsystem is unreachable in production.

**Recommendation.** Either wire an explicit hook in `VaultWithdrawFacet` (deriving a per-trader fee amount) or clearly mark `ReferralVault` as not-yet-integrated in its own header and remove the misleading integration snippet.

---

### [LOW] L-04 — Commingled cross-vault custody relies entirely on ledger correctness

- **ID:** ART-L-04
- **Location:** [src/libraries/LibAppStorage.sol:126-132](src/libraries/LibAppStorage.sol#L126-L132), [src/facets/VaultDepositFacet.sol:116-125](src/facets/VaultDepositFacet.sol#L116-L125)
- **Confidence:** Confirmed (defense-in-depth).

The Diamond holds every vault's base assets in its own token balances; per-vault separation is purely the `idleBalance[vault]` ledger. No path found lets vault A spend vault B's tokens (`_drain` only pulls A's own strategies; `_pullAndCredit` uses balance-delta with `received == assets`, rejecting fee-on-transfer), so the invariant holds for standard tokens — but there is no reconciliation and no `sweep`, so any accounting drift (or a future non-standard base asset) is silent and unrecoverable.

**Recommendation.** Add a governance `sweep`/reconcile that compares `Σ idleBalance[v]` (per base asset) against `token.balanceOf(diamond)` and can recover untracked surplus (also addresses L-05). Consider explicitly forbidding rebasing base assets at `createVault`.

---

### [LOW] L-05 — Direct token donations to the Diamond are untracked and permanently unrecoverable

- **ID:** ART-L-05
- **Location:** design (see `docs/formulas.md §9`), `src/facets/*` (no sweep function)
- **Confidence:** Confirmed.

A raw `transfer` to the Diamond is (correctly) never credited to NAV — good for inflation safety — but there is no `sweep`, so donated/mistakenly-sent tokens are stuck forever. Harmless to share pricing; a permanent lock and support burden.

**Recommendation.** Add a governance `sweep(token)` that can withdraw balances **in excess** of `Σ idleBalance` for that token (never the tracked idle).

---

### [INFORMATIONAL] I-01 — Stale/contradictory spec: `README.md` (v4) and an arithmetic error in `formulas.md`

- **Location:** `README.md`, `docs/formulas.md §2/§4`

`README.md` describes a superseded ERC-721/cost-basis design that does not match the code; `docs/architecture.md §7` says so, but the mismatch is a maintenance hazard. Separately, `formulas.md §2` computes `pps ≈ 1000 × 1e18` where the code yields `1e12` (off by `10^6`), and the §4 fee example uses a supply/NAV combination that can't co-exist at 6-dp — this masked H-01. **Fix the docs alongside H-01** and either delete or clearly quarantine the v4 README.

### [INFORMATIONAL] I-02 — `harvest`/`harvestAll`/`settle` run during pause; `settle` is permissionless

- **Location:** [src/facets/VaultHarvestFacet.sol:80-110](src/facets/VaultHarvestFacet.sol#L80-L110)

Intended, but note: `settle` (permissionless) triggers `chargePerformanceFee` at any time; once H-01 is fixed, confirm a permissionless `settle` at an attacker-chosen moment can't be used to time fee crystallization adversarially (it can't mint to anyone but `treasury`, so low risk — but re-verify post-fix). `deployIdle`/`rebalance` are correctly pause-gated.

### [INFORMATIONAL] I-03 — Circuit breaker treats "read reverted" and "value moved sharply" identically

- **Location:** [src/libraries/LibVaultNav.sol:84-100](src/libraries/LibVaultNav.sol#L84-L100)

A revert (unknown state) and a large *downward* move (likely real loss) both fall back to the stale high value. Consider differentiating (see H-02) — a revert might warrant "hold last value, freeze allocation," while a confirmed sharp drop warrants an impairment write-down.

### [INFORMATIONAL] I-04 — `strategyDisabled` strategies are excluded from `refreshNav`'s live re-read only via `broken`, not `disabled`

- **Location:** [src/libraries/LibVaultNav.sol:74-101](src/libraries/LibVaultNav.sol#L74-L101) vs. `docs/architecture` wording

`refreshNav` re-reads disabled-but-not-broken strategies live (correct — disabled only blocks *new deploys*), but confirm this matches the intended semantics for a strategy that is disabled *because* it's suspect; if disable is used as a "soft freeze," its value is still trusted live. Document the precise difference between disabled/broken value-in-NAV treatment.

### [GAS] G-01 — Minor

- `LibStrategyRegistry._removeFromList` shifts the array (O(n), n ≤ 5 — fine, and intentional to preserve priority order). `ReferralVault._outstandingBase` / `_isRegisteredShareToken` are O(#vaults) but admin-only/view. No action required; listed for completeness.

---

## 4. Invariant analysis

| Inv | Statement | Status | Notes / finding |
|---|---|---|---|
| I1 | NAV = idle + Σ strategy values | **Conditional** | Holds normally; desyncs transiently in `emergencyWithdraw` (M-05) |
| I2 | idle backed by real custody, no cross-vault spend | **Holds** (standard tokens) | Ledger-only separation; no sweep/reconcile (L-04) |
| I3 | Σ redeemable ≤ recoverable NAV | **Violated under stale NAV** | H-02: broken-strategy value inflates redeemable |
| I4 | Rounding favors vault (4 directions) | **Holds** | `LibVaultMath` correct; verified at 6/8/18 dp |
| I5 | `_drain` NAV decrement can't underflow/desync | **Holds** (normal) | `require(remaining==0)` guarantees full gather; see M-05 for emergency path |
| I6 | Breaker trips on jump/revert, keeps last value, drain keeps `strategyLastValue` honest | **Holds mechanically** | but the "keep last value" choice drives H-02 |
| I7 | Attacker can't mint cheap / over-redeem within a step | **Partially** | Sub-threshold manipulation bounded by `maxDeltaBps`; H-02 is the realized risk |
| I8 | First read (`lastValue==0`) not flagged | **Holds** | Confirmed; no seeding abuse found |
| I9 | Fee only on new peak, HWM pre-mint, dip/recover no re-charge | **Inert** | H-01: fee never charges at all |
| I10 | Fee shares priced pre-mint | **Holds** (code) | Correct ordering, but unreachable (H-01) |
| I11 | Virtual offset defeats inflation/donation at all decimals | **Holds** | Re-derived 6/8/18 dp; donations not NAV-credited |
| I12 | Correct modifiers; `onlyVault`/`onlyDiamond` resolve to Diamond | **Holds** | Verified across facets + share token + strategies |
| I13 | Permissionless `settle`/`emergencyWithdraw` not weaponizable | **Partially** | `emergencyWithdraw` stale pricing (M-05) + race (H-02) |
| I14 | Caps/limits enforced, non-bypassable except `isCapExempt` | **Holds** | Per-block cumulative caps correct |
| I15 | Pause gating; emergency always available; guardian can't unpause | **Holds** | but emergency exit prices stale (M-05/H-02) |
| I16 | No storage collision / selector clash; cut auth correct | **Holds** | `LibDiamond` namespaced slot; `AppStorage` slot 0; cut is `enforceIsContractOwner` |
| I17 | Shared reentrancy lock guards cross-facet; no read-only reentrancy | **Holds** (found) | Single slot-0 lock; state-changers `nonReentrant`; strategies also `nonReentrant` |

---

## 5. Per-component coverage log

| Component | Result |
|---|---|
| `Diamond.sol`, `LibDiamond.sol`, `DiamondCutFacet`, `DiamondLoupeFacet` | Reviewed — standard diamond-3; cut correctly owner-gated. No issue. |
| `LibAppStorage.sol` (+ `Modifiers`) | Reviewed — layout/append-only/lock correct. See L-04. |
| `LibVaultNav.sol` | Reviewed — **H-02**, I-03/I-04. |
| `LibVaultMath.sol` | Reviewed — rounding/offset correct; underpins **H-01** scale. |
| `LibVaultFee.sol` | Reviewed — logic correct but **H-01** makes it inert. |
| `LibStrategyRegistry.sol` | Reviewed — **M-04** (emergencyWithdraw not try/catch on remove/migrate). |
| `LibVaultCap.sol` | Reviewed — per-block cumulative caps correct. No issue. |
| `VaultDepositFacet` | Reviewed — balance-delta pull, cap ordering correct. No issue. |
| `VaultWithdrawFacet` | Reviewed — **H-02** (drain skips broken, prices vs inflated NAV). |
| `VaultEmergencyFacet` | Reviewed — **M-05**, **H-02** amplifier. |
| `VaultHarvestFacet` | Reviewed — try/catch semantics correct; I-02. |
| `VaultAdminFacet` / `OwnershipFacet` | Reviewed — **H-01** (HWM init); rails/bounds otherwise correct. |
| `VaultViewFacet` | Reviewed — previews match state-changing math. No issue. |
| `VaultShareToken.sol` | Reviewed — mint/burn/spendAllowance Diamond-only. No issue. |
| `BaseStrategy.sol` + sampled strategies | Reviewed — **L-01** (oracle dp), **M-04** (cooldown). |
| Swappers (`UniswapV3Swapper`) | Reviewed — approval hygiene ok; `minOut` from oracle floor. No issue. |
| `oracle/**` | Reviewed — **M-01/M-02/M-03/L-01**. |
| `rewards/**` | Reviewed — **L-02**; accounting otherwise consistent. |
| `referral/**` | Reviewed — **L-03**; registry two-step transfer & self-referral guard correct. |
| `governance/**` | Reviewed — standard OZ v5, timestamp clock, cap; wiring correct. No issue. |

---

## 6. Test-coverage gap analysis (highest-leverage remediation)

There are **no tests**. Before mainnet, at minimum:
1. **Fee/HWM invariant** (would have caught H-01): after X% yield, `treasury` shares == `feeBps%` of profit; dip-recover charges nothing; runs at 6/8/18 dp.
2. **Solvency invariant under broken strategy** (H-02): fuzz deposits/withdraws with a strategy that reports high but withdraws low; assert no sequence lets aggregate payouts exceed real recoverable assets, and no user is left worse than pro-rata.
3. **Fork tests per venue** (M-04): Aave/Compound/Morpho/Curve+Convex and especially cooldown venues (sUSDe) — deposit, harvest, partial/full withdraw, emergency, remove, migrate — including cooldown-enabled and paused-market states.
4. **Oracle unit tests** (M-01/2/3/L-01): stale, negative/zero, at-bound, non-8dp feed, wide Pyth confidence, L2 sequencer down.
5. **Access-control negative tests** (I12): every admin/keeper/guardian function rejects the wrong caller; `onlyVault`/`onlyDiamond` enforced.
6. **Differential ERC-4626**: `previewX` == actual `X`; rounding always vault-favorable; round-trip never profitable.
7. **Diamond**: add/replace/remove/loupe correctness; storage-layout snapshot test to enforce the append-only `AppStorage` rule.

---

## 7. Systemic & architectural observations

- **Two economic properties are broken today** (H-01 fee never charges, H-02 loss-socialization race). Both stem from the *scale* and *staleness* seams between checkpointed NAV and the fee/breaker logic — fix them together and add the invariant tests above.
- **Oracle is the soft underbelly.** The vault deliberately delegates all pricing to strategies/oracle; harden Pyth confidence, Chainlink bounds, L2 sequencer, and the 8-dp feed assumption before relying on any reward-token or cross-asset valuation.
- **Governance blast radius is concentrated** in the Timelock (owns Diamond, tokens, oracle admin, treasury). This is the intended, standard design and is well-reasoned, but it means Timelock key management and the guardian veto are the real security boundary — the on-chain rails (`MAX_PERFORMANCE_FEE_BPS`, `MAX_IDLE_BPS`, `strategyMaxDeltaBps != 0`) are good and should be extended (e.g. bound `rewardRate`, require non-rebasing base assets).
- **Docs are a strength but currently a liability** where stale (I-01). Since the docs were the ground truth for this review, an arithmetic slip in them (formulas.md) directly corresponded to a code bug (H-01). Keep them in lockstep and add the numeric examples as executable tests.
- **Zero tests** across ~8,000 lines is, by itself, the largest risk to shipping safely.
