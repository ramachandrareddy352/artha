# Artha test plan

## 0. The question that shapes everything: can we test against live protocols?

**Yes — with `forge test --fork-url`, which clones mainnet state into a local EVM at a
pinned block. Every real contract is there: Aave's Pool, the real aUSDC, Comet, sDAI,
Curve pools, Convex booster.** We get tokens with `deal()`, which writes balance storage
directly, and we impersonate anyone with `vm.prank`.

The hard part is the second half of the question: **time.** `vm.warp()` moves
`block.timestamp` forward, but whether that actually produces YIELD depends entirely on
how each protocol computes it. There are two kinds of protocol, and they need different
handling:

### Protocols where time travel Just Works

Their yield is a **pure function of elapsed time**, computed on read. Warp 30 days and the
balance is genuinely 30 days larger — no external actor needed:

| Protocol | Why it works |
|---|---|
| Aave V3 / Spark | `liquidityIndex` is recomputed from `lastUpdateTimestamp` + `currentLiquidityRate` on every interaction. `aToken.balanceOf` grows on its own. |
| Compound V3 (Comet) | `accrueInternal()` reads `block.timestamp`; the supply index and `baseTrackingAccrued` (COMP) both advance. |
| sDAI / sUSDS | The Pot's `chi` accrues from `rho` (a timestamp) on `drip()`. `convertToAssets` rises. |
| Morpho Blue / MetaMorpho | Market interest accrues from `lastUpdate` on read. |
| Euler V2 (EVK) | Same shape — interest accrued from a stored timestamp. |

**These are the majority of our strategies, and they are fully testable end to end.**

### Protocols where time travel is NOT enough

Their yield requires an **external actor to push something on-chain**. Warping alone
changes nothing, so the test has to play that actor. This is the part the question is
really about, and each case has a specific answer:

| What doesn't move | Why | What we do instead |
|---|---|---|
| **Chainlink prices go STALE** | `latestRoundData().updatedAt` is frozen at the fork block. Warp past `maxStaleTime` and our own `PriceFeed` correctly reverts. | **This blocks everything, so it is fixed first.** A `MockAggregator` is registered in `PriceFeed` for each token, seeded from the REAL Chainlink price at fork time. It refreshes `updatedAt` on every warp — and lets us *move* prices, which we need anyway (see below). |
| **Rotation needs price moves** | BTC does not move at a pinned block. | Same harness. `oracle.setPrice(WBTC, +25%)` is the only way to test a strategy whose entire logic is price bands. |
| **Convex/Curve gauge rewards stop** | Convex's `BaseRewardPool` streams a reward amount over ~7 days; past `periodFinish`, `earned()` flatlines. | Call `booster.earmarkRewards(pid)` — permissionless, anyone can — then warp *inside* the fresh 7-day window. Repeat to compound. |
| **Curve `get_virtual_price` is flat** | It only rises on trading FEES, and no one trades in a forked chain. | Execute real swaps against the pool from a funded address to generate fees, or accept a flat virtual price and assert mechanics (LP minted, staked, unwound) rather than growth. |
| **wstETH / rETH rate is frozen** | The rate only moves when Lido's `AccountingOracle` submits a report. | `vm.mockCall` on `getStETHByWstETH` to raise the rate, which is exactly what a report does. The rate MATH itself is covered exhaustively in the mocked layer. |
| **sUSDe (Ethena) barely accrues** | Rewards are *transferred in* by Ethena's operator and vest over 8h. | Warp only within a vesting window, or `deal` USDe to the staking contract and prank the rewarder. Treat yield magnitude as out of scope; test the wrapper mechanics. |

**The honest summary: interest-bearing venues are testable for real, with real yield.
Emission-and-report-driven venues need us to simulate the actor that pushes the update —
which we do, explicitly, and never by faking our own contracts' numbers.**

### Why fork tests cannot be the whole suite

Fork tests are slow (one RPC round-trip per cold storage slot), non-deterministic across
block pins, need a paid RPC endpoint, and — most importantly — **cannot produce failure
conditions on demand.** We cannot make Aave pause its reserve, make a swap revert, make a
venue return a garbage price, or push a stablecoin off its peg. Those are precisely the
paths that matter most.

So the suite is layered.

---

## 1. Three layers

```
Layer 1  UNIT + FUZZ         mocked venues        fast, deterministic, no RPC
         ↳ every strategy's invest/divest/harvest/tend/emergency path
         ↳ every failure mode: reverting swap, dead oracle, paused venue, dust, 0
         ↳ admin actions interleaved with user actions
         ↳ runs in CI with no secrets

Layer 2  FORK INTEGRATION    real protocols       proves our ABIs are right
         ↳ per token: USDC, USDT, DAI, WETH, WBTC
         ↳ real yield over real warped time where the protocol allows it
         ↳ skipped automatically when no RPC is configured

Layer 3  INVARIANTS          handler-driven       on mocked venues, so it can run deep
         ↳ random sequences of user + admin + keeper actions
         ↳ properties that must hold after EVERY action
```

Layer 1 is written first because Layer 3 reuses its mocks and Layer 2 reuses its
assertions.

---

## 2. File layout

```
test/
  mocks/
    Mocks.sol                 MockERC20, MockOracle, MockSwapper, MockERC4626
    MockVenues.sol            MockAavePool + MockAToken, MockComet + MockCometRewards,
                              MockCurvePool, MockConvex, MockLst, MockBeefy
    MockAggregator.sol        Chainlink shape with settable price + fresh updatedAt
  helpers/
    VaultHarness.sol          deploys facets + Vault, wires roles, helper actions
    ForkBase.sol              fork setup, RPC gate, PriceFeed re-pointing, deal helpers
    Addresses.sol             mainnet addresses per protocol per token
  unit/
    BaseStrategy.t.sol        custody semantics, dust sweep, rescue, tend, settlement
    MultiRewardStrategy.t.sol registry, dust floors, unpriced tokens, failed swaps
    RotationStrategy.t.sol    every band, cooldown, parking, forced stance, round trip
    HoldStrategy.t.sol        + LiquidStaking valuation (lower-of-two rule)
    AaveV3LendStrategy.t.sol
    CompoundV3Strategy.t.sol
    CurveConvexStrategy.t.sol
    ERC4626Strategies.t.sol   wrapper + cross-asset
    VaultStrategyFlow.t.sol   deployIdle, rebalance, harvest, tend, circuit breaker
    VaultAdminFlow.t.sol      add/remove/migrate/reweight/disable, execOnStrategy
    Interleaving.t.sol        admin + user acting inside the same block
  fuzz/
    ShareMath.t.sol           deposit/withdraw round-trips never mint value
    RotationBands.t.sol       fuzzed price paths, cooldown, band monotonicity
    RewardValuation.t.sol     fuzzed decimals/prices, haircut, no overflow
  fork/
    UsdcStrategies.t.sol
    UsdtStrategies.t.sol
    DaiStrategies.t.sol
    WethStrategies.t.sol
    WbtcStrategies.t.sol
  invariant/
    Handler.sol               bounded random user/admin/keeper actions
    VaultInvariants.t.sol
```

---

## 3. Layer 1 — what each unit suite must prove

### Every strategy, the same seven-point checklist

Applied to all of: Aave V3, Compound V3, ERC-4626 wrapper, cross-asset 4626, Beefy,
Curve+Convex, Hold, LiquidStaking, Pendle PT, LP booster, Rotation.

1. `invest` deploys, and the receipt lands with the RIGHT custodian (vault for
   aToken/4626/hold/LST/PT; strategy for Comet/Convex/rotation).
2. `positionValue` tracks the venue after yield, after loss, and at exactly zero.
3. `divest(x)` returns ≥ x−dust to the vault, and never more than requested.
4. `divest(huge)` returns everything available without reverting.
5. `harvest` sells only what clears the dust floor, and credits the vault by measured
   delta.
6. `emergencyWithdraw` unwinds fully — including when the swap route is broken (partial,
   never revert).
7. Every `onlyVault` function reverts for everyone else.

### Failure modes that must degrade, not revert

- Oracle has no price for a reward token → skipped, `RewardSkipped` emitted, NAV
  unaffected, vault NOT paused.
- Swap reverts mid-harvest → other rewards still sell; that one retries next time.
- Venue `positionValue` reverts → `LibVaultNav` catches, breaker trips, vault pauses,
  `emergencyWithdraw` still works.
- Venue at zero liquidity → `maxWithdraw` reports it, withdrawal queue routes around via
  `tryDivestFrom`.

### Rotation, specifically (the most novel logic)

- Seeds its reference price on first tend rather than rotating immediately.
- Take-profit fires at the band, not one basis point before.
- Rebound confirmation blocks entry until the trough is left behind.
- Trailing stop tracks the peak only while holding quote.
- Stop-loss and `maxQuoteHold` both force the return leg.
- Cooldown blocks a second rotation in the window, including via `forceStance`? (no —
  `forceStance` deliberately bypasses; assert that.)
- **The money test: a full round trip at −25%/+20% leaves strictly MORE base token than
  it started with**, net of two swaps' slippage.
- A one-way trend leaves LESS, and the loss is bounded by `exitStopLossBps`.
- Parked legs: yield in the park accrues to the position; unparking mid-band works.
- `_custodiesBase` settlement: divest returns `min(requested, balance)`, emergency
  returns everything, invest does not sweep the position away.

### Admin and user interleaving (the explicit ask)

Each of these runs as: *start action → interleave → finish → assert nothing broke.*

| Admin does | While a user does | Must hold |
|---|---|---|
| `addStrategy` | deposits in the same block | new deposit prices off the same NAV; weights still sum to 100% |
| `removeStrategy` | withdraws | user gets full value; removed strategy's assets are in idle |
| `migrateStrategy` | deposits and withdraws | no value created or destroyed across the swap |
| `setTargets` (reweight) | redeems | redemption drains in priority order regardless |
| `setStrategyDisabled` | deposits | disabled strategy receives no new capital but still pays out |
| `setIdleTargetBps` up | withdraws | more idle available, no revert |
| `setCaps` (lower TVL cap) | deposits | deposit above cap reverts, existing holders unaffected |
| guardian `pauseVault` | mid-withdraw | withdraw blocked, `emergencyWithdraw` still open |
| keeper `rebalance` | deposits in the same block | share price unchanged by the rebalance itself |
| keeper `tend` (rotation) | withdraws right after | withdrawal priced at post-rotation NAV |
| `execOnStrategy` (retune bands) | deposits | config change never moves NAV |
| direct token transfer to vault | any | uncounted until `sync()`, then lifts all holders |

---

## 4. Layer 2 — fork suites, per token

Each token file follows the same shape, so a reviewer can diff them.

**Common setup:** fork at a pinned block → deploy facets + `Vault` for that base asset →
deploy a `PriceFeed` with `MockAggregator`s seeded from real Chainlink → deploy the
token's strategies against REAL protocol addresses → `deal` the base token to users.

| Token | Strategies exercised against live contracts |
|---|---|
| **USDC** | Aave V3, Compound V3 (COMP claim), Morpho MetaMorpho, Euler V2, Spark, Curve 3pool + Convex, Yearn V3, sUSDS (cross-asset), sUSDe (cross-asset), rotation vs WBTC |
| **USDT** | Aave V3, Compound V3 USDT Comet, Morpho, Euler V2, Curve 3pool + Convex, Yearn V3 |
| **DAI** | Aave V3, Spark DAI, **sDAI** (the headline: real chi accrual over warped time), Morpho, Euler V2, Curve + Convex, Yearn V3 |
| **WETH** | Aave V3, Compound V3 WETH Comet, Morpho, Euler V2, **wstETH**, **rETH**, **sfrxETH**, Curve WETH/stETH + Convex, Yearn V3, rotation vs USDC |
| **WBTC** | Aave V3, Morpho, Euler V2, Curve WBTC/tBTC + Convex, Yearn V3, **rotation vs USDC — the full sell-high/buy-back round trip on real swap venues** |

**Per strategy, on the fork:** deposit → `deployIdle` → warp 30 days → assert
`positionValue` GREW (for the interest-bearing venues) → `harvest` → `withdraw` →
assert the user got principal + yield − fees.

**RPC gate:** `ForkBase.setUp` reads `ETH_RPC_URL`; if unset it calls `vm.skip(true)` so
the whole file is skipped rather than failed. CI stays green without secrets; anyone with
an RPC gets the full suite.

---

## 5. Layer 3 — invariants

A `Handler` exposes bounded random actions — `deposit`, `withdraw`, `redeem`,
`emergencyWithdraw`, `deployIdle`, `rebalance`, `harvestAll`, `tendAll`, `addStrategy`,
`removeStrategy`, `setTargets`, `pause`/`unpause`, `warp`, `movePrice`, `venueYield`,
`venueLoss` — over multiple actors, and the fuzzer runs long random sequences of them.

Properties asserted after every single call:

1. `totalAssets() == idleBalance + Σ positionValue(healthy) + Σ lastValue(broken)`
2. `pricePerShare` never falls except through a real venue loss or a charged fee — never
   through a deposit, a withdrawal, a rebalance, a tend, or a harvest.
3. Sum of user shares == `shareToken.totalSupply()`.
4. No user can withdraw more value than their share of NAV (no value creation).
5. `Σ strategyWeightBps + idleTargetBps == 10_000`, always.
6. `idleBalance <= baseAsset.balanceOf(vault)` — the ledger never claims more than custody.
7. A paused vault admits no deposit and no normal withdraw, but always admits
   `emergencyWithdraw`.
8. A broken strategy is never invested into and never blocks a withdrawal.
9. The rotation strategy's stance only changes at a band or by governance force.
10. Nothing is ever left stranded in a strategy after `removeStrategy` beyond `dustFloor`.

---

## 6. Order of work

1. Mocks and the vault harness.
2. Unit suites, base layer first (`BaseStrategy`, `MultiRewardStrategy`), then per
   strategy family, then vault flow, then interleaving.
3. Fuzz suites.
4. Fork suites, one token file at a time.
5. Invariants last, reusing everything above.

## 7. What the fork layer actually found

Three real defects, none of which the mocked layer could have produced, plus two
pre-existing behaviours worth knowing about.

**Fixed — `CometRewards.rewardConfig` decode reverted valuation.** The live contract
returns a THREE-field struct; ours declared four (it appended `multiplier` in a later
version). A return-data decoding failure is *not* caught by `try/catch` — it reverts
straight through — so `pendingRewardsValue()` → `positionValue()` reverted, which
`LibVaultNav` reads as a broken strategy: circuit breaker tripped, entire vault
auto-paused. Now decoded by return-data LENGTH, with a missing `multiplier` defaulting
to no scaling. Regression-tested against both layouts.

**Fixed — an under-funded distributor bricked `rebalance` and strategy retirement.**
Compound's `CometRewards` has run out of COMP on mainnet, so `claim` reverts with
"transfer amount exceeds balance". The claim step was unguarded, so that revert
propagated into `harvest()` — and `rebalance` harvests with hardRevert, while
`removeStrategy`/`migrateStrategy` require the harvest to succeed. One third-party
contract running dry would have frozen rebalancing and made the affected strategy
impossible to retire. The claim is now best-effort, exactly like the sell already was.

**Fixed — `HoldStrategy._divest` under-delivered by the spread.** Sizing the sale for
exactly `amount` came up a few basis points short, and `WithdrawFacet._drain` requires
the FULL amount from the queue — so withdrawals routed through a swap-based strategy
reverted. Restored the slippage gross-up; the overshoot lands in the vault as idle
rather than being lost.

**Known, by design — a 100% redeem cannot come out of a slippage-bearing venue.** Exiting
a Curve position single-sided realizes slightly less than its virtual-price valuation,
so `_drain` cannot produce the last few basis points and reverts. Withdrawing 99.9%
works; the emergency exit covers the remainder but is `whenPaused`, so the final holder
of such a vault needs governance to pause. Worth a deliberate decision before launch.
(The same shortfall applies to `CrossAssetERC4626Strategy`, which does not gross up.)

**Known, by design — an auto-pause triggered inside `deposit` is rolled back.**
`refreshNav` can trip the breaker and pause, but `deposit`/`deployIdle` then revert with
`PAUSED`, undoing the pause with the rest of the transaction. The pause only sticks when
the breaker trips inside `withdraw`, `harvest`, or `emergencyWithdraw`. Not exploitable
— the next such call re-trips it — but the protection is not as immediate as it reads.

## 8. Running it

```bash
forge test                              # layers 1 and 3; no RPC needed
forge test --match-path 'test/fork/*'   # layer 2, needs ETH_RPC_URL
ETH_RPC_URL=https://... forge test      # everything
forge coverage --ir-minimum             # coverage report
```
