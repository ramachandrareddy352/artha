# Artha Vault — Formulas, Derivations & Worked Examples

This document derives every formula the vault (`contracts/src/facets/`, `contracts/src/libraries/`) uses, with worked numeric examples for each. It is the reference to check *"is this the number I expect"* against — every example below uses real numbers, not symbolic placeholders, and is arithmetic you can re-run by hand.

Conventions used throughout:
- **USDC vault example**: base asset decimals = 6.
- **Shares**: always 18 decimals (`SHARE_DECIMALS`), regardless of the base asset.
- **Basis points (bps)**: 10,000 = 100%.
- **`DECIMALS_OFFSET = 6`** → virtual shares = 10⁶, virtual assets = 1.

---

## 1. NAV (Net Asset Value)

```
navCheckpoint[vault] = idleBalance[vault] + Σ strategy.totalAssets()   (over every non-broken strategy)
                      + Σ strategyLastValue[vault][strategy]           (over every broken strategy, frozen at last-known-good)
```

`strategy.totalAssets()` is itself:

```
strategy.totalAssets() = positionValue + pendingRewardsValue
```

where `positionValue` is principal + accrued interest/appreciation in the strategy's venue, and `pendingRewardsValue` is unclaimed reward tokens, oracle-priced and haircut 2% (`REWARD_HAIRCUT_BPS = 200`), already converted to base-token terms by the strategy itself — the vault never talks to an oracle directly.

**This is a CHECKPOINT, not a live read.** `navCheckpoint` is only recomputed by `LibVaultNav.refreshNav(vault)`, which every state-changing entry point (`deposit`, `mint`, `withdraw`, `redeem`, `harvest`, `harvestAll`, `settle`, `deployIdle`, `rebalance`) calls first. Views (`totalAssets`, `pricePerShare`, `previewDeposit`, ...) read the checkpoint as-is.

### Worked example

A USDC vault (6dp) with 3 strategies:

| Component | Value (USDC, 6dp) |
|---|---|
| `idleBalance` | 50,000.000000 |
| Strategy A (Aave USDC) `totalAssets()` | 300,120.500000 |
| Strategy B (Curve+Convex USDC) `totalAssets()` | 200,450.000000 |
| Strategy C (Ethena sUSDe) `totalAssets()` | 149,800.250000 |
| **navCheckpoint** | **700,370.750000** |

`50,000 + 300,120.5 + 200,450 + 149,800.25 = 700,370.75` ✓.

---

## 2. Share Math — the virtual-offset formula

All four conversions (`LibVaultMath`) use the SAME base formula, only the rounding direction changes:

```
shares = assets × (totalSupply + 10^DECIMALS_OFFSET) / (navCheckpoint + 1)
assets = shares × (navCheckpoint + 1) / (totalSupply + 10^DECIMALS_OFFSET)
```

With `DECIMALS_OFFSET = 6`, the virtual-share term is `10^6 = 1,000,000` and the virtual-asset term is `1`.

| Function | Direction | Rounding |
|---|---|---|
| `deposit(assets)` → shares minted | assets → shares | **DOWN** (caller gets fewer shares) |
| `mint(shares)` → assets required | shares → assets | **UP** (caller pays more) |
| `withdraw(assets)` → shares burned | assets → shares | **UP** (caller burns more shares) |
| `redeem(shares)` → assets returned | shares → assets | **DOWN** (caller receives less) |

Every rounding favors the vault / existing holders, never the caller — applied as one consistent rule (`LibVaultMath`'s header), not decided per function.

### Why the virtual offset defeats the first-depositor / donation attack

Classic attack: attacker deposits 1 wei first (mints 1 wei of shares), then DONATES a huge amount of the base asset directly to the vault contract (bypassing `deposit()`, e.g. a plain `transfer`). Without the offset, the next real depositor's shares would be computed as:

```
shares = assets × totalSupply / totalAssets = assets × 1 / (1 + donation)
```

— which rounds to **0** for almost any real deposit, stealing it.

With the offset (`totalSupply + 10^6` in the numerator, `totalAssets + 1` in the denominator), the attacker would need to donate roughly **10^6× their own stake** to move the price enough to zero out a victim's shares — a donation that large is a pure loss to the attacker (the donated funds round overwhelmingly to the vault's OTHER holders' benefit, not the attacker's, since the attacker's own 1-wei stake is a vanishingly small fraction of the post-donation pool). The attack becomes strictly loss-making.

### Worked example — first depositor

Vault just created. `totalSupply = 0`, `navCheckpoint = 0`.

Alice deposits 1,000.000000 USDC:

```
shares = 1,000,000,000 × (0 + 1,000,000) / (0 + 1)
       = 1,000,000,000 × 1,000,000
       = 1,000,000,000,000,000     (1e15, in share-wei, i.e. 1,000,000 shares at 18dp... )
```

Wait — units: `assets` is in the base asset's raw units (6dp for USDC, so 1,000 USDC = `1_000_000_000` in raw 6dp terms is WRONG — 1,000 USDC at 6dp = `1_000 × 10^6 = 1,000,000,000`). Let's redo cleanly:

```
assets  = 1,000 USDC = 1,000,000,000  (6dp raw units)
supply  = 0
navCheckpoint = 0
offset  = 10^6 = 1,000,000

shares = 1,000,000,000 × (0 + 1,000,000) / (0 + 1)
       = 1,000,000,000,000,000
       = 1e15
```

Alice receives `1e15` share-wei = **0.001 shares** at 18dp (`1e15 / 1e18 = 0.001`). That looks small, but `pricePerShare` right after is:

```
pps = (navCheckpoint + 1) × 1e18 / (supply + offset)
    = (1,000,000,000 + 1) × 1e18 / (1e15 + 1,000,000)
    ≈ 1,000,000,000 × 1e18 / 1e15
    ≈ 1,000 × 1e18   (~1,000 USD per share, since Alice owns effectively the whole pool)
```

This is expected and harmless — pricePerShare is an internal accounting ratio, not a marketed "$1 per share" constant; the frontend displays a user's USDC-equivalent balance (`convertToAssetsDown(shares)`), not raw share count.

### Worked example — inflation attack, defeated

Attacker deposits 1 wei (`assets = 1`) first:

```
shares = 1 × (0 + 1,000,000) / (0 + 1) = 1,000,000  (1e6 share-wei = an infinitesimal 1e-12 shares)
```

Attacker then donates 10,000 USDC (`10_000_000_000` raw units) directly via `transfer` (not `deposit`) — this raises `idleBalance` only if the vault code credits raw transfers to idle, which it deliberately does **not** (see §9) — but even granting the attacker the maximum-damage assumption that the donation is somehow counted in NAV:

```
navCheckpoint = 10_000_000_001   (1 wei original deposit + 10,000 USDC donation)
supply        = 1,000,000
```

Victim deposits 1,000 USDC (`1_000_000_000`):

```
shares = 1_000_000_000 × (1,000,000 + 1,000,000) / (10_000_000_001 + 1)
       = 1_000_000_000 × 2,000,000 / 10_000_000_002
       ≈ 199,999.9996
       ≈ 199,999   (rounded down)
```

The victim still receives ~200,000 share-wei — a fair, non-zero, proportionate amount (roughly 1/50th of the attacker's inflated pool, matching the real 1,000-vs-50,001 USDC ratio). **The attack does not zero out the victim.** Compare to the no-offset case where the victim would have received **0** shares and lost their entire deposit.

---

## 3. Price Per Share

```
pricePerShare = (navCheckpoint + 1) × 1e18 / (totalSupply + 10^DECIMALS_OFFSET)
```

Informational and used for the high-water-mark comparison — never used directly for deposit/withdraw math (those always go through the offset-aware conversions in §2).

---

## 4. Performance Fee — Aggregate High-Water Mark

```
if pricePerShare <= highWaterMarkPps:
    no fee, no HWM change

else:
    highWaterMarkPps = pricePerShare              // raised BEFORE minting, to the gross peak
    profitPerShare   = pricePerShare - oldHWM
    profitAssets     = profitPerShare × totalSupply / 1e18
    feeAssets        = profitAssets × performanceFeeBps / 10_000
    feeShares        = convertToSharesDown(feeAssets)     // priced against PRE-mint state
    mint(treasury, feeShares)
```

Runs inside `LibVaultNav.refreshNav` — i.e. on **every** NAV refresh, not only when a keeper explicitly harvests. This matters because price-per-share can rise purely from interest accrual (a lending strategy's position value climbs every block) with no harvest event at all.

### Worked example

Vault: `totalSupply = 1,000,000e18` shares, `performanceFeeBps = 1,000` (10%), `highWaterMarkPps = 1.00e18` (starting peak).

NAV grows (interest accrual) such that `pricePerShare` is now `1.05e18` (a 5% gain):

```
profitPerShare = 1.05e18 - 1.00e18 = 0.05e18
profitAssets   = 0.05e18 × 1,000,000e18 / 1e18 = 50,000e18   (50,000 USD-equivalent worth of growth)
feeAssets      = 50,000e18 × 1,000 / 10,000 = 5,000e18       (10% of the profit)
feeShares      = convertToSharesDown(5,000e18)
               ≈ 5,000e18 × (1,000,000e18 + 1e6) / (navCheckpoint + 1)
               ≈ 5,000e18 / 1.05                                (since pps ≈ 1.05 pre-mint)
               ≈ 4,761.9e18 shares minted to treasury
```

`highWaterMarkPps` is now `1.05e18`. If price-per-share later dips to `1.02e18` and recovers to `1.05e18` again, **no new fee is charged** — only a move ABOVE `1.05e18` triggers another crystallization. This is the "true high-water mark" property (§Q33 of the design discussion): never re-charge recovered ground.

Note the post-mint `pricePerShare` is slightly BELOW the recorded HWM (`1.05e18`) immediately after minting — this is expected and correct: the HWM marks the gross peak reached before the dilutive fee mint, and price-per-share must climb back past it again before the next fee.

---

## 5. Per-Block Flow Caps

```
if isCapExempt[vault][caller]: skip entirely

if block.number != depositFlowBlock[vault]:
    depositFlowBlock[vault]  = block.number
    depositFlowAmount[vault] = 0

require(depositFlowAmount[vault] + amount <= depositCapPerBlock[vault])
depositFlowAmount[vault] += amount
```

(Symmetric for withdrawals, tracked in a separate mapping so the two caps are independent.)

### Worked example

`depositCapPerBlock = 500,000 USDC` (raw: `500_000_000_000`). Three deposits land in the same block:

| Deposit | Amount | Cumulative | Result |
|---|---|---|---|
| Alice | 200,000 | 200,000 | OK |
| Bob | 250,000 | 450,000 | OK |
| Carol | 100,000 | 550,000 | **REVERTS** — `550,000 > 500,000` |

Carol's transaction reverts entirely (no partial fill — consistent with the withdrawal semantics in §6). She can resubmit in the next block, where `depositFlowAmount` resets to 0.

An address with `isCapExempt[vault][addr] = true` (e.g. a vetted institutional counterparty, or the atomic `migrateStrategy` flow) skips this check regardless of amount.

---

## 6. Withdrawal Drain & the Atomic-Revert Invariant

```
shortfall = assets > idleBalance ? assets - idleBalance : 0

if shortfall == 0:
    pay entirely from idle

else:
    idleBalance = 0
    remaining = shortfall
    for strategy in priorityQueue:                 // index 0 first
        if strategy.broken: skip
        got = strategy.withdraw(remaining)          // strategy caps its own delivery, never exceeds `remaining`
        remaining -= got
        strategyLastValue[strategy] -= got          // keep the circuit-breaker's cache honest

    require(remaining == 0, "INSUFFICIENT_LIQUIDITY")   // whole tx reverts otherwise
```

### Worked example

Vault: `idleBalance = 30,000 USDC`, strategies `[A, B, C]` in priority order, each holding `100,000 / 80,000 / 50,000` USDC. A user withdraws `150,000 USDC`.

```
shortfall = 150,000 - 30,000 = 120,000
idleBalance -> 0

Strategy A: request 120,000, delivers 100,000 (its whole position) -> remaining = 20,000
Strategy B: request  20,000, delivers  20,000                      -> remaining = 0
Strategy C: never touched
```

Total delivered: `30,000 (idle) + 100,000 (A) + 20,000 (B) = 150,000` ✓. If Strategy B had only been able to deliver `15,000` (e.g. a venue liquidity limit) and Strategy C were `broken` (skipped), `remaining` would end at `5,000 ≠ 0` and the **entire transaction reverts** — the user keeps their shares, no partial burn, no partial payout, and can retry once liquidity recovers.

---

## 7. NAV Circuit Breaker

```
diff  = |newValue - lastValue|
limit = lastValue × strategyMaxDeltaBps / 10,000

if diff > limit:
    strategyBroken[vault][strategy] = true          // excluded from new deploys; last-known value still counts in NAV
```

`lastValue == 0` (a brand-new strategy's first-ever read) is never flagged — nothing to compare against yet.

### Worked example

`strategyMaxDeltaBps = 2,000` (20%). Strategy's last checkpointed value was `100,000 USDC`.

| New reading | `diff` | `limit` (20% of 100,000) | Tripped? |
|---|---|---|---|
| 108,000 (organic 3 days of interest) | 8,000 | 20,000 | No |
| 45,000 (a real, honest 55,000 legitimate withdrawal happened via `_drain`, which ALREADY adjusted `strategyLastValue` down to 45,000 before this read) | 0 | 9,000 | No — this is exactly why `_drain` and `deployIdle`/`rebalance` update the cache directly instead of leaving it stale |
| 20,000 (an UN-explained 80% drop — e.g. a manipulated oracle feed, or an exploit) | 80,000 | 20,000 | **Yes — circuit breaks** |

**Configuration note:** `strategyMaxDeltaBps` must be set looser than the worst-case combined slippage of any strategy's own entry/exit swaps (`maxSlippageBps` on the strategy itself). A cross-asset strategy (e.g. Ethena, Frax) with `maxSlippageBps = 100` (1%) swapping on both entry and exit could legitimately show a value move approaching that bound right after a `deployIdle`/`rebalance` — if `strategyMaxDeltaBps` were set tighter than that (e.g. 50 bps), the very next NAV refresh would falsely trip the breaker on a perfectly healthy strategy. As a rule of thumb, set `strategyMaxDeltaBps` at least 3-5× a strategy's own `maxSlippageBps` to leave headroom for legitimate slippage while still catching genuine manipulation-scale jumps.

`strategyMaxDeltaBps` cannot be set to 0 (see `VaultAdminFacet.createVault` / `setStrategyMaxDeltaBps`) — 0 would silently mean "circuit breaker disabled," which must never be an accident of a governance call that simply omitted the parameter. To genuinely run without an effective breaker, set it to `10,000` (100%).

---

## 8. Keeper Operations — Worked Examples

### 8.1 `deployIdle(vault)` — routine capital deployment

Pushes idle ABOVE the target buffer into under-allocated strategies. Never withdraws from a strategy.

```
targetIdle = navCheckpoint × idleTargetBps / 10,000
available  = idleBalance > targetIdle ? idleBalance - targetIdle : 0

for strategy in priorityQueue:
    target  = navCheckpoint × strategyWeightBps[strategy] / 10,000
    current = strategyLastValue[strategy]
    if current >= target: continue
    toDeploy = min(target - current, available)
    deposit toDeploy into strategy
    available -= toDeploy
```

**Example.** Vault: `navCheckpoint = 1,000,000 USDC`, `idleTargetBps = 500` (5%), `idleBalance = 150,000` (a large recent deposit sitting idle). Targets: A=40%, B=30%, C=20% (idle 5%, weights sum to 90% ≤ 100%, intentionally leaving 5% extra headroom per the "sum ≤ 100%" rule). Current strategy values: A=380,000, B=280,000, C=190,000.

```
targetIdle = 1,000,000 × 500 / 10,000 = 50,000
available  = 150,000 - 50,000 = 100,000

Strategy A: target = 400,000, current = 380,000, gap = 20,000 -> deploy 20,000, available = 80,000
Strategy B: target = 300,000, current = 280,000, gap = 20,000 -> deploy 20,000, available = 60,000
Strategy C: target = 200,000, current = 190,000, gap = 10,000 -> deploy 10,000, available = 50,000
```

`50,000` remains idle (above the `50,000` target — nothing left under-allocated to absorb it this round; it will be picked up on the next `deployIdle` once targets or NAV shift, or simply sits as extra buffer, which is safe).

### 8.2 `rebalance(vault)` — target weights changed

Governance changes targets: A 40%→25%, B 30%→35%, C 20%→30%, idle stays 5% (sum = 95%). `rebalance` is called.

**Step 1 — mandatory harvest (hard revert if any fails).** Every strategy harvests first; suppose this realizes a small amount of pending rewards, bumping `navCheckpoint` from `1,000,000` to `1,004,200`.

**Step 2 — refreshNav**, now `navCheckpoint = 1,004,200`. New targets:

```
A: 1,004,200 × 2,500 / 10,000 = 251,050
B: 1,004,200 × 3,500 / 10,000 = 351,470
C: 1,004,200 × 3,000 / 10,000 = 301,260
idle target: 1,004,200 × 500 / 10,000 = 50,210
```

Current values (post-harvest): A=400,000+small bump ≈ 401,680, B=300,000+bump ≈ 301,260, C=200,000+bump ≈ 200,840 (illustrative split of the 4,200 harvest gain across the three).

**Step 3 — pass 1, pull excess from over-allocated strategies:**

```
A: current 401,680 > target 251,050 -> withdraw 150,630 -> idle += 150,630
B: current 301,260 <= target 351,470 -> skip (under-allocated, handled in pass 2)
C: current 200,840 <= target 301,260 -> skip
```

**Step 4 — pass 2, deploy into under-allocated strategies:**

```
idleBalance now = 50,000 (old idle) + 150,630 (freed from A) = 200,630
available = 200,630 - 50,210 (target idle) = 150,420

B: gap = 351,470 - 301,260 = 50,210 -> deploy 50,210, available = 100,210
C: gap = 301,260 - 200,840 = 100,420 -> deploy min(100,420, 100,210) = 100,210, available = 0
```

C ends slightly short of its exact target (100,210 of 100,420 needed) purely because the freed capital ran out — this is expected; the NEXT `deployIdle`/`rebalance` (once more capital is idle) closes the remaining gap. No revert, no partial-fill ambiguity: every unit of freed capital was fully accounted for and deployed.

### 8.3 Adding a new strategy

`addStrategy(vault, D, allStrategies=[A,B,C,D], allWeightsBps=[20,30,25,25]%×100, idleTargetBps=500)` — atomic: D is appended to the list AND the full weight vector (including D's initial 25%) is set in the SAME call, per the "add + reweight simultaneously" design choice. D starts with `strategyLastValue = 0` and zero deposits; the next `rebalance()` pulls excess from the now-over-weighted A/B/C and deploys it into D following the same two-pass algorithm as §8.2.

### 8.4 Removing a strategy

`removeStrategy(vault, C, dustFloor=1000)` — harvests C (hard-revert if it fails), calls C's `emergencyWithdraw()` to pull everything it will give up, credits the proceeds to `idleBalance`, and requires C's remaining `totalAssets()` be `<= dustFloor` (unrecoverable venue-rounding remainder, written off) or the call reverts. C is then removed from the priority list — positions at higher indices shift down by one, preserving the withdrawal order of the strategies that remain.

---

## 9. Deliberately Out of Scope (documented, not silently skipped)

- **Intra-strategy claim/sell split.** `BaseStrategy.harvest()` claims reward tokens and swaps them to base in one atomic call today. The vault layer adds ORCHESTRATION-level resilience (a stuck strategy's harvest failure never blocks harvesting any OTHER strategy — see `VaultHarvestFacet.harvestAll`'s per-strategy `try/catch`), but a true INTRA-strategy split (claim always succeeds even if the sell leg reverts) would require splitting `BaseStrategy._harvestRewards()` into separate claim/sell hooks across every concrete strategy file — scoped out of this pass, tracked as a follow-up.
- **ReferralVault integration.** `ReferralVault.settlePerformanceFee` expects a PER-TRADER, PER-WITHDRAWAL base-token fee amount (cost-basis model). This vault's performance fee is vault-WIDE, aggregate-high-water-mark, realized via share-minting at NAV-refresh time (§4) — a structurally different model with no natural per-trader amount to attribute to a referral code. `ReferralVault` is left as standalone infrastructure, not wired into `VaultWithdrawFacet`. `UserRewardVault` (ARTHA staking on vault shares) integrates with zero changes needed, since it pulls shares via a plain `transferFrom` the user initiates directly — no vault-side wiring required at all.
- **Direct token donations.** A `transfer()` straight to the Diamond (bypassing `deposit()`) is never credited to `idleBalance` or `navCheckpoint` — only `_pullAndCredit`'s balance-delta-checked `safeTransferFrom` inside `deposit`/`mint` updates vault accounting. A raw donation just sits as an untracked token balance with no effect on share pricing (and is not currently swept anywhere — a future `sweep()` admin function could recover it, out of scope here).
