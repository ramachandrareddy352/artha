# Artha — full-protocol adversarial test plan

This is the plan for testing the protocol as a whole: every facet, every library, the
oracle, the swappers, every strategy shape, the rewards module and governance — under
normal use, under concurrent use, and under attack.

It is deliberately a **separate document** from `testing-plan.md`. That one describes the
suite that exists (222 unit/fuzz + 39 fork + 8 invariants, strategy-focused). This one
describes what is still missing, and it is scoped by a different question:

> Not "does the code do what it says", but **"can a user lose money that is theirs"** —
> in any ordering, at any time, with any counterparty misbehaving.

---

## 0. The stance: specification first, implementation second

The single most important rule in this plan, and the reason it is written before any
code:

**Every assertion must be derived from what the protocol OUGHT to do, never from what
the contracts currently do.**

A test written by reading a function and asserting its current output is a change
detector, not a test. It passes on a buggy contract and fails on a fixed one. The
existing suite already caught three real bugs precisely where it asserted an outcome
("a harvest must not be able to freeze rebalancing") rather than a behaviour ("claim
reverts when the distributor is empty").

Three practices enforce this:

1. **Write the property before opening the file.** §3 is the specification. Each test
   cites the property number it defends. A test that cites no property is a change
   detector and should be deleted.
2. **When a test fails, the contract is the first suspect, not the test.** Every
   adjustment to an assertion must be justified in one written sentence explaining why
   the ORIGINAL expectation was wrong about the protocol, not merely inconvenient.
3. **Prove the tests bite.** Mutation testing (§10) — if a mutant survives, the suite
   does not actually constrain that line, whatever coverage says.

### What the big protocols do, and what we take from each

| Source | Practice worth copying |
|---|---|
| **Yearn V3** | Every strategy tested through the same shared conformance suite, so a new strategy inherits the whole battery on day one. Property tests around "report/harvest never mints value". |
| **Yearn (post-2020 incidents)** | Explicit tests for the *dependency* failing — a venue that pauses, an oracle that lies, a reward distributor that runs dry — not just the happy path. |
| **Morpho / Euler** | Invariant suites with a handler that includes ADMIN actions, not just user actions. Most vault bugs live in reconfiguration, not in deposit. |
| **Balancer / Curve audits** | Rounding-direction tests as first-class citizens; "who eats the wei" asserted per operation. |
| **Sherlock / Code4rena findings corpus** | First-depositor inflation, donation, reentrancy through callback tokens, and cap-bypass-via-allowance recur across nearly every vault. All four are in §5. |
| **OpenZeppelin ERC-4626 test suite** | The conversion round-trip matrix (deposit→redeem, mint→withdraw) fuzzed over the full input domain. |

---

## 1. Threat model

### 1.1 Actors and what each can do

| Actor | Capabilities | Trusted for |
|---|---|---|
| **User** | deposit, mint, withdraw, redeem, emergencyWithdraw (paused only), transfer shares, approve | nothing |
| **Anyone** | `settle()`, `sync()`, direct token transfer to the vault, deploy contracts, flash loans | nothing |
| **Keeper** | harvest, harvestAll, tend, tendAll, deployIdle, rebalance | liveness only — **never** with user funds |
| **Guardian** | pauseVault, pauseProtocol | halting only — cannot unpause, cannot move value |
| **Governance (Timelock)** | every AdminFacet setter, strategy lifecycle, `execOnStrategy`, `Vault.setFacet`, unpause | economic parameters, subject to timelock delay |
| **Strategy** | whatever its own code does with the allocation it holds | **NOTHING — assume hostile** |
| **Venue (Aave, Curve, …)** | can pause, freeze, lose money, run out of rewards, change ABI | nothing |
| **Oracle** | can be stale, wrong, manipulated, or absent | nothing without staleness + sanity checks |
| **Swap venue** | can sandwich, revert, return dust | nothing beyond the caller's `minOut` |

### 1.2 The safety boundary

Stated as one sentence per actor, these are what the entire adversarial suite (§5) exists
to defend:

- **A compromised STRATEGY can lose at most its own allocation.** It can never touch
  idle, another strategy's position, another vault, or a user's shares.
- **A compromised KEEPER can waste gas and delay yield.** It can never move value to any
  address other than the vault or one of the vault's own strategies, and its worst-case
  bleed through repeated rebalance/tend must be measurable and bounded.
- **A compromised GUARDIAN can halt the protocol.** It can never move value, never
  unpause, and never block `emergencyWithdraw`.
- **A compromised ORACLE cannot mint NAV.** It can at worst make a strategy unpriceable,
  which must degrade to a circuit break, never to a mispriced deposit or exit.
- **A malicious USER cannot extract more than their pro-rata share** at any point in any
  ordering, including within a single block and including as the first or last depositor.
- **GOVERNANCE is the one trusted role — and its blast radius must still be enumerated**,
  because "trusted" is a statement about the timelock's delay, not about omnipotence.

### 1.3 Explicit non-goals

Stated so the suite does not pretend to cover them: economic soundness of a chosen
strategy, venue insolvency, chain reorgs, governance token capture, and off-chain keeper
infrastructure. These are risk-management concerns, not correctness ones.

---

## 2. Test taxonomy — what each layer is FOR

| Layer | Catches | Cannot catch |
|---|---|---|
| Unit (mocked) | Logic errors, boundary conditions, access control, revert reasons | Wrong ABI assumptions, real venue behaviour |
| Fuzz (stateless) | Rounding, overflow, decimal handling across input domains | Sequence-dependent bugs |
| Invariant (stateful, handler-driven) | Sequence-dependent accounting drift, reconfiguration bugs | Anything the handler cannot express |
| Adversarial/scenario | Named attacks, deliberately constructed hostile setups | Unknown-unknowns |
| E2E lifecycle | Cross-module interaction over long timelines | Single-block races |
| Fork | Wrong ABI, real venue quirks, real liquidity | Failure modes you cannot induce on mainnet |
| Differential | Divergence from a reference implementation of the maths | Anything outside the modelled subset |
| Mutation | **Tests that do not actually assert anything** | Real bugs directly |

The adversarial and invariant layers are where this plan spends most of its effort,
because that is where vault money is actually lost in practice.

---

## 3. The specification — every property the protocol must satisfy

This is the contract-independent oracle. Numbered so every test can cite one.

### 3.1 Solvency and conservation (the ones that matter most)

- **S1** `Σ previewRedeem(balanceOf(u)) for all u ≤ totalAssets()` — the vault never owes
  more than it has.
- **S2** `idleBalance ≤ baseAsset.balanceOf(vault)` — the ledger never claims custody it
  does not have.
- **S3** `totalAssets() == idleBalance + Σ positionValue(healthy) + Σ lastValue(broken)`
  after any settle.
- **S4** Value out ≤ value in: `Σ withdrawals + currentNAV ≤ Σ deposits + Σ venue gains
  + Σ donations − Σ venue losses` (within rounding).
- **S5** No sequence of user operations, in any order, in any number of blocks, increases
  the caller's claim faster than pro-rata NAV growth.
- **S6** `shareToken.totalSupply() == Σ all holder balances` including treasury.

### 3.2 Share maths and rounding

- **M1** deposit rounds shares DOWN; mint rounds assets UP; withdraw rounds shares UP;
  redeem rounds assets DOWN. Every rounding favours the vault.
- **M2** `deposit(x)` then immediate `redeem(shares)` returns **≤ x**, never more.
- **M3** `mint(s)` then immediate `withdraw(assets)` burns **≥ s**, never fewer.
- **M4** Round-tripping never leaves the caller better off, at any NAV, any supply, any
  decimals (6/8/18), including supply == 0 and NAV == 0.
- **M5** The first depositor cannot be forced to receive 0 shares for a material deposit
  by any prior donation.
- **M6** No repeated small operation extracts a positive amount from other holders
  (the wei-grinding attack).

### 3.3 Deposit path

- **D1** Shares are priced against a NAV refreshed in the same call.
- **D2** A deposit never changes any other holder's claim (pps before ≈ pps after).
- **D3** Caps (TVL, per-block flow, min deposit) are enforced and cannot be bypassed by
  splitting across addresses, transactions in one block, or `mint` vs `deposit`.
- **D4** A fee-on-transfer or rebasing base token cannot make `idleBalance` exceed real
  custody.
- **D5** `msg.value` must exactly equal the entry fee; ETH accounting never mixes with
  base-asset accounting.
- **D6** A deposit that discovers a broken strategy must not be priced against a NAV the
  vault has just declared untrustworthy.

### 3.4 Withdrawal path and THE QUEUE

- **W1** The queue drains **idle first**, then strategies in registration (priority)
  order, index 0 first.
- **W2** A broken strategy is skipped entirely, never divested from.
- **W3** A strategy whose venue reverts contributes 0 and does not take the withdrawal
  down (`tryDivestFrom`).
- **W4** The queue never over-divests: it stops as soon as the requested amount is
  covered.
- **W5** A withdrawal either pays in full or reverts — never a partial burn with partial
  payout.
- **W6** After a withdrawal, `idleBalance` and `navCheckpoint` both decrease by exactly
  the amount paid.
- **W7** Withdrawal order between users does not change any user's entitlement (no
  first-mover advantage in normal operation).
- **W8** A withdrawal on behalf of another (allowance path) burns from `owner`, pays
  `receiver`, and consumes allowance exactly once.
- **W9** `maxWithdraw`/`maxRedeem` never over-promise: a withdrawal of exactly
  `maxWithdraw(u)` must succeed whenever the vault is unpaused and liquid.
- **W10** Harvest-before-pricing: a withdrawer is priced after pending yield is realized,
  so they neither donate nor steal harvest value.

### 3.5 Strategy operations

- **T1** `deployIdle` never deploys into a disabled or broken strategy.
- **T2** `deployIdle`/`rebalance` never change price-per-share beyond real venue costs.
- **T3** `harvest` credits the vault by its measured balance delta, never by a returned
  claim.
- **T4** A failing harvest on one strategy never blocks another strategy's harvest, a
  withdrawal, or a strategy's retirement.
- **T5** `tend` moves no base in or out of the vault.
- **T6** Repeated keeper operations have a **bounded, measurable** cost to holders — and
  that bound must be documented.

### 3.6 NAV, the circuit breaker, and fees

- **N1** A suspicious value jump freezes the strategy at its last known-good value and
  never trusts the new reading.
- **N2** A permissionless caller can never re-anchor the breaker, trip it, or crystallize
  a fee.
- **N3** The breaker cannot be evaded by walking a value up in sub-threshold steps
  **without paying for each step** — and the cost of doing so must be quantified.
- **N4** A broken strategy is excluded from new deployments and from the withdrawal queue,
  but its last value still counts in NAV.
- **N5** Clearing a break requires a governance-confirmed anchor within tolerance of the
  live reading; it can never mint NAV.
- **N6** The performance fee is charged only on a NEW high-water mark, never twice on the
  same peak, never on a dip-and-recover.
- **N7** Fee shares dilute proportionally and never reduce any holder's asset claim below
  their pre-profit claim.
- **N8** A deposit or withdrawal, by itself, never crystallizes a fee.
- **N9** An unset treasury defers the fee; it never bricks deposits or withdrawals.

### 3.7 Emergency

- **E1** `emergencyWithdraw` is available to every holder whenever the vault is paused.
- **E2** It prices against POST-unwind NAV, so the exiter bears the exit cost they caused.
- **E3** It burns only the shares actually paid for; a shortfall never forfeits the
  remainder.
- **E4** It never reverts merely because one strategy cannot be unwound.
- **E5** Pausing blocks deposits and normal withdrawals for everyone simultaneously — no
  partial freeze that lets some exit.
- **E6** A tiny emergency exit must not be able to force a full unwind of the entire
  vault (griefing bound).

### 3.8 Access control

- **A1** Every state-changing function has exactly one intended caller class, and every
  other class reverts.
- **A2** Role changes take effect immediately and completely.
- **A3** Governance transfer is atomic and total; the old governance retains nothing.
- **A4** No facet function is reachable by an unintended selector; `setFacet` cannot be
  used to bypass a role check.
- **A5** `execOnStrategy` cannot move capital in a way that bypasses vault accounting.

### 3.9 Oracle

- **O1** A stale price is never used.
- **O2** A zero, negative, or incomplete round is never used.
- **O3** An unconfigured token reverts rather than defaulting to zero.
- **O4** An oracle failure degrades to a circuit break or a skipped reward — never to a
  mispriced deposit, exit, or swap floor.
- **O5** Every swap floor derives from the oracle, never from the venue's own quote.
- **O6** No single-block price movement (spot, flash-loaned) can change a valuation.

### 3.10 Rewards module

- **R1** A user's ARTHA accrual depends only on their own shares, time, and the rate.
- **R2** A rate change applies the old rate to the old period and the new rate to the new
  one — never retroactively.
- **R3** Staking/unstaking never changes another user's accrual.
- **R4** The vault cannot pay out more ARTHA than it holds; a shortfall degrades, never
  reverts a user's unstake.
- **R5** `emergencyUnstake` always returns the user's shares, even when paused, even when
  ARTHA is exhausted.
- **R6** `rescue` can never remove staked share tokens or ARTHA that is owed.

### 3.11 Governance

- **G1** No proposal can execute before the timelock delay has elapsed.
- **G2** A proposal below quorum or below threshold cannot execute.
- **G3** Voting power is snapshotted; tokens bought after the snapshot do not vote.
- **G4** The full path (propose → vote → queue → execute) genuinely reconfigures the vault.
- **G5** Cancellation and the guardian's role are separated from execution.

---

## 4. Module-by-module test matrices

Each row is at least one test. `[E]` marks a case the current suite does not cover.

### 4.1 `LibVaultMath` — share conversion

| Case | Assert |
|---|---|
| supply 0, NAV 0 | first deposit mints `assets · 10^offset`; no revert |
| supply 0, NAV > 0 (donation + sync) `[E]` | deposit still mints non-zero shares for a material deposit (M5) |
| supply > 0, NAV 0 (total loss) `[E]` | deposit does not divide by zero; existing holders get nothing back |
| 6 / 8 / 18-decimal base, fuzzed `[E]` | M1–M4 hold for every decimal |
| deposit→redeem round trip, fuzzed | returns ≤ input (M2) |
| mint→withdraw round trip, fuzzed `[E]` | burns ≥ input (M3) |
| 1 wei deposit, 1 wei redeem `[E]` | never returns more than paid |
| NAV near `uint256` limits `[E]` | `mulDiv` does not overflow |
| repeated 1-wei deposit/redeem × 1000 `[E]` | attacker's balance strictly decreases (M6) |

### 4.2 `DepositFacet`

| Case | Assert |
|---|---|
| happy path | D1, D2, event fields, share balance |
| `receiver == 0`, `assets == 0`, below min | revert with the right reason |
| exactly at TVL cap / 1 wei over | boundary is inclusive as documented |
| per-block cap split across 3 senders in one block `[E]` | cumulative cap enforced (D3) |
| per-block cap: `mint` vs `deposit` `[E]` | both consume the same budget |
| cap-exempt address | skips both caps |
| entry fee: exact / over / under / zero-when-disabled | `BAD_ETH_FEE` on any mismatch (D5) |
| ETH fee accounting `[E]` | `collectedEthFees` tracks exactly; base accounting untouched |
| fee-on-transfer base token `[E]` | reverts `TRANSFER_MISMATCH`; idle never inflated (D4) |
| rebasing base token `[E]` | idle never exceeds custody |
| deposit while a strategy is broken | reverts `PAUSED`, mints nothing (D6) |
| deposit in the same block as a harvest `[E]` | depositor captures no part of the harvest (W10 mirror) |
| reentrant token calling deposit again `[E]` | `nonReentrant` holds; no double mint |
| `navCheckpoint += received` outside a refresh `[E]` | a later refresh produces the same NAV — no desync |

### 4.3 `WithdrawFacet` and the queue — **deepest matrix, as requested**

Queue ordering:

| Case | Assert |
|---|---|
| idle covers it entirely | no strategy touched at all (W1) |
| idle partially covers | remainder taken from index 0 first (W1) |
| index 0 insufficient | spills to index 1, then 2, in order (W1) |
| index 0 broken | skipped entirely, index 1 used (W2) |
| index 0 venue reverts | contributes 0, index 1 covers, withdrawal succeeds (W3) |
| index 0 partially liquid `[E]` | takes what it can, remainder from index 1 (W3, W4) |
| every strategy illiquid | reverts `INSUFFICIENT_LIQUIDITY`, no shares burned (W5) |
| order after `removeStrategy` from the middle `[E]` | remaining strategies keep relative order |
| order after `migrateStrategy` `[E]` | replacement takes the LAST slot — assert the priority change is intended |
| requested exactly equals total available `[E]` | succeeds, leaves 0 |
| over-divest check `[E]` | after the loop, freed ≥ requested but the loop stopped at the first sufficient point (W4) |

Pricing and accounting:

| Case | Assert |
|---|---|
| harvest-before-price | withdrawer's pps includes pending yield (W10) |
| `withdraw` vs `redeem` asymmetry `[E]` | `withdraw` harvests before the first refresh, `redeem` after — both must price identically for equivalent requests |
| `maxSharesBurned` / `minAssetsOut` | slippage guards revert as intended |
| `maxWithdraw(u)` exactly `[E]` | always succeeds when unpaused and liquid (W9) |
| allowance path | burns from owner, pays receiver, spends allowance once (W8) |
| allowance path with insufficient allowance | reverts before any state change |
| **withdraw cap keyed on `msg.sender` not `owner`** `[E]` | **whale splits a large exit across N approved senders in one block — assert the per-block cap still binds, or record the bypass as a finding (D3)** |
| two users withdrawing in one block | neither is advantaged (W7) |
| withdrawal during a venue loss `[E]` | loss is shared pro-rata, not borne by the last exiter |
| `navCheckpoint -= assets` vs recomputed NAV `[E]` | a subsequent settle produces the same figure (W6) |

### 4.4 `StrategyFacet`

| Case | Assert |
|---|---|
| `deployIdle` respects weights, idle target, disabled, broken | T1, allocation exactness |
| `deployIdle` with idle below target | no-op |
| `deployIdle` with a single strategy at 100% `[E]` | no rounding leak |
| `rebalance` two-pass (pull then deploy) | converges to targets; T2 |
| `rebalance` when one venue reverts on divest `[E]` | does not silently mis-allocate |
| `rebalance` with a harvest failure | must not revert the whole call (T4 — fixed, keep the regression) |
| **`rebalance` called 50× in a row** `[E]` | **quantify the pps bleed; assert it is bounded and document the figure (T6)** |
| `harvest` on unknown / broken strategy | reverts |
| `harvest` measured-delta accounting | T3, including a strategy that returns a lie |
| `tend` moves no base | T5 |
| `tendAll` with one reverting strategy | others still tend |
| `settle` permissionless, unanchored | N2 |
| `settle` spammed `[E]` | cannot trip a breaker or move the anchor |

### 4.5 `AdminFacet`

| Case | Assert |
|---|---|
| every setter: bounds, events, effect | A1, A2 |
| `addStrategy`: vault mismatch, asset mismatch, duplicate, max count | reverts |
| `addStrategy` at `MAX_STRATEGIES_PER_VAULT` `[E]` | the 6th is rejected |
| `setTargets`: not 100%, missing a strategy, unknown strategy | reverts |
| `removeStrategy`: harvest-first, dust floor, unrecoverable | reverts rather than stranding |
| `removeStrategy` on a broken strategy `[E]` | skips harvest, still removes |
| `migrateStrategy`: value preserved, weight carried, new strategy reverts on invest `[E]` | atomic — all or nothing |
| `clearStrategyCircuitBreak`: in-band, out-of-band, unreadable position | N5 |
| `execOnStrategy`: reaches setters, blocks IStrategy movers, unknown target, non-governance, bubbles reverts | A5 |
| **`execOnStrategy` → `RotationStrategy.forceStance`** `[E]` | **a strategy's OWN fund-moving function is reachable. Assert value is conserved and the vault re-prices correctly; document that the blocklist is not a "no funds move" guarantee** |
| **`execOnStrategy` → `rescue` of a position token** `[E]` | must revert (`PROTECTED_TOKEN`) |
| `transferGovernance` | A3 — old governance loses everything |
| governance transfer to a contract that cannot call back `[E]` | document the bricking risk |

### 4.6 `EmergencyFacet`

| Case | Assert |
|---|---|
| available only when paused | E1 + the documented rationale |
| post-unwind repricing | E2 — the exiter bears their own exit cost |
| partial payout burns proportional shares | E3 |
| one strategy cannot be unwound | E4 — still pays what it can |
| **1-wei emergency exit with all strategies liquid** `[E]` | **`_gather` must not escalate to a full unwind; assert bounded divest only (E6)** |
| **1-wei emergency exit with the bounded divest failing** `[E]` | **escalation unwinds everything — quantify and record as a griefing bound** |
| pause blocks deposit + withdraw simultaneously | E5 |
| guardian cannot unpause; governance can | A1 |
| `sync` credits a donation once, not twice | idle == custody after |
| `sync` before the first deposit `[E]` | inflation-attack surface (M5) |

### 4.7 `LibVaultNav` and the circuit breaker

| Case | Assert |
|---|---|
| first-ever read (lastValue 0) | never flagged |
| jump just under / just over threshold | boundary exact (N1) |
| reverting `positionValue` | breaker trips, vault pauses, NAV keeps last value |
| broken strategy in every downstream path | N4 (deploy, drain, harvest, rebalance) |
| anchored vs unanchored refresh | N2 |
| **walk-up attack** `[E]` | **advance a value in sub-threshold steps across N deposits; assert each step costs the attacker real capital and quantify the cost (N3)** |
| **auto-pause rolled back inside `deposit`** `[E]` | **assert the documented behaviour explicitly so it cannot regress silently** |
| breaker on a strategy tracked at 0 | flags but does not pause |

### 4.8 `LibVaultFee` — high-water mark

| Case | Assert |
|---|---|
| profit above the mark | fee minted once, mark raised (N6) |
| dip and recover to the same peak | no second fee (N6) |
| new peak above the old | fee only on the increment |
| `feeBps == 0` | mark still raises (so a later fee is not retroactive) |
| treasury unset | fee deferred, nothing bricks (N9) |
| **fee dilution vs holder claim** `[E]` | **no holder's asset claim falls below their pre-profit claim (N7)** |
| **100 deposits with no yield** `[E]` | **HWM does not ratchet, no fee minted (N8)** |
| mark seeded at genesis pps | fee is reachable at all (the documented scale fix) |
| fee at `MAX_PERFORMANCE_FEE_BPS` | bounded, no overflow |

### 4.9 `LibVaultCap`, `VaultShareToken`, `Vault` router

| Case | Assert |
|---|---|
| flow caps: same block cumulative, next block reset, exempt | D3 |
| cap boundary at exactly `cap` | inclusive |
| share token: mint/burn only by vault | A1 |
| share token: transfer, approve, permit if present `[E]` | standard ERC-20 conformance |
| router: unknown selector | `FUNCTION_NOT_FOUND` |
| `setFacet` repoints a selector `[E]` | governance-only; A4 |
| **`setFacet` to a malicious facet** `[E]` | **enumerate the blast radius explicitly — this is the top of the trust hierarchy** |
| `receive()` ETH | accounted or refused, never stranded silently |

### 4.10 Oracle — `PriceFeed`, `ChainlinkSource`, `PythSource`

| Case | Assert |
|---|---|
| stale beyond `maxStaleTime` | reverts (O1) |
| `updatedAt == 0`, `startedAt == 0`, future timestamp | reverts (O2) |
| `answeredInRound < roundId` | reverts (O2) |
| price 0 or negative | reverts (O2) |
| unconfigured token | reverts, never 0 (O3) |
| `maxStaleTime` below the 600s floor | setter rejects |
| Pyth: confidence interval, exponent, stale `[E]` | equivalent guarantees to Chainlink |
| Chainlink vs Pyth divergence `[E]` | document that sources never cross-check; assert the caller's choice is honoured |
| feed swapped by admin mid-flight `[E]` | no stale cached value survives |
| oracle down during NAV refresh | O4 — breaker, not mispricing |
| oracle down during harvest | reward skipped, not sold blind (O4) |
| oracle down during a rotation tend | rotation refuses rather than swapping blind |

### 4.11 Swappers

| Case | Assert |
|---|---|
| `minOut` enforced on measured delta, every swapper | O5 |
| Uniswap V3 path endpoints validated | wrong path reverts, not silently misroutes |
| Uniswap V2 path validated | same |
| Curve: pool coins vs requested pair `[E]` | mismatch cannot silently deliver nothing |
| Balancer: assetIn/assetOut honoured `[E]` | same |
| **Aggregator: arbitrary calldata to the pinned router** `[E]` | **payload claiming a huge output but delivering little → reverts on measured `minOut`; payload targeting a different token → reverts** |
| `RoutedSwapper`: unregistered pair, governance-only setters, re-route without touching strategies `[E]` | full matrix |
| swapper returns MORE than expected `[E]` | surplus is credited, never stranded |
| swap fee at exactly `maxSlippageBps` / 1 bp over | boundary exact |

### 4.12 Strategy conformance suite (run against EVERY strategy)

Following Yearn's model: one abstract suite, each strategy plugs in. Every strategy must
pass all of it, so a new strategy inherits the battery.

| Case | Assert |
|---|---|
| invest → correct custodian holds the receipt | vault for aToken/4626/hold/LST/PT; strategy for Comet/Convex/rotation |
| `positionValue` after gain, after loss, at exactly 0 | tracks the venue |
| `divest(x)` returns ≥ x−dust, never more than requested | W-series support |
| `divest(huge)` | returns everything available, no revert |
| `emergencyWithdraw` with a broken swap route | partial, never revert |
| every `onlyVault` function | reverts for everyone else |
| `harvest` with no rewards | returns 0, no revert |
| `harvest` with a reverting claim | best-effort (T4) |
| `harvest` with an unpriced reward | skipped, NAV unaffected |
| **reentrancy: venue calls back into the vault mid-divest** `[E]` | **`nonReentrant` holds across the vault↔strategy boundary** |
| dust amounts (1 wei) in and out `[E]` | no revert, no value creation |

### 4.13 Rewards module (`UserRewardVault` / `System` / `Manager`)

| Case | Assert |
|---|---|
| accrual independent of other stakers | R1 |
| rate change mid-position | old rate for old period (R2) |
| stake/unstake does not disturb others | R3 |
| ARTHA exhausted at claim | R4 — degrades, does not brick |
| `emergencyUnstake` while paused, while ARTHA is empty | R5 |
| `rescue` on a registered share token | reverts (R6) |
| `rescue` on ARTHA beyond excess | reverts (R6) |
| stake with a fee-on-transfer share token `[E]` | measured-received guard holds |
| double registration, unregistered vault | reverts |
| **shares staked here while the vault pauses** `[E]` | **user can still exit the reward vault and then emergency-exit the main vault** |

### 4.14 Governance

| Case | Assert |
|---|---|
| full propose → vote → queue → execute against the vault `[E]` | G4 — really reconfigures |
| execute before delay | reverts (G1) |
| below quorum / below threshold | cannot execute (G2) |
| votes bought after snapshot | do not count (G3) |
| delegation and re-delegation `[E]` | power moves correctly |
| cancellation path `[E]` | G5 |
| timelock role separation (proposer/executor/canceller) `[E]` | A1 |
| ARTHA cap enforced on mint `[E]` | cannot exceed cap |
| **governance-executed `addStrategy` with a hostile strategy** `[E]` | **the timelock delay is the only defence — assert it applies, and document that it is the trust assumption** |

---

## 5. The adversarial suite — attacks, spelled out

Each is a named test file with a hostile contract, not a parameter tweak.

### 5.1 Malicious strategy (`test/attack/MaliciousStrategy.t.sol`)

The single most important file in the plan. A `EvilStrategy` implementing `IStrategy`
hostilely, registered normally, then:

| Attack | Must hold |
|---|---|
| reports `positionValue` = `type(uint256).max` | breaker trips; NAV uses last value; no one can redeem against the lie |
| inflates `positionValue` by 2× each refresh | breaker trips before any redemption at the inflated price |
| deflates to 0 suddenly | breaker trips; holders are not raced out |
| reverts on `positionValue` | breaker trips, vault pauses, emergency exit still works |
| reverts on `divest` | queue skips it; other strategies serve the withdrawal |
| reverts on `emergencyWithdraw` | `_tryFullExit` swallows it; other strategies still unwind |
| returns without transferring on `divest` | measured-delta accounting credits 0, not the claim |
| transfers LESS than claimed | vault credits only what arrived |
| **reenters `deposit` during `invest`** | `nonReentrant` blocks it |
| **reenters `withdraw` during `divest`** | blocked; no double payout |
| **reenters `harvest` during `harvest`** | blocked |
| **tries to pull the vault's OTHER receipt tokens** | it has no allowance — approvals are transient and scoped to its own receipt |
| **tries to spend the transient receipt allowance for more than its own position** | assert the allowance is reset to 0 after every call |
| consumes all gas in `positionValue` | try/catch bounds it; NAV still computes |
| returns a fake `receiptToken()` (another strategy's) | the vault must not grant it an allowance it can abuse |
| **holds base and lies that it is deployed** | cannot double-count against idle |

### 5.2 Oracle manipulation (`test/attack/OracleManipulation.t.sol`)

| Attack | Must hold |
|---|---|
| flash-loan the DEX spot price, then deposit | no valuation uses spot; NAV unchanged (O6) |
| feed reports 100× the true price | strategy value jumps → breaker trips before anyone redeems |
| feed reports 1/100× | same, in the other direction |
| feed goes stale mid-operation | reverts cleanly; no deposit priced against it |
| feed reports a valid-but-wrong price within breaker tolerance `[E]` | **quantify the extractable value; this is the residual risk and must be written down** |
| reward token price manipulated upward | pending-reward NAV inflates → assert the 2% haircut and breaker bound the damage |
| **rotation strategy: manipulate the pair price to force a rotation** | cooldown + oracle-only pricing + `minOut` bound the loss; quantify worst case |
| oracle admin swaps a feed to a malicious one `[E]` | enumerate blast radius; document the trust assumption |

### 5.3 Inflation, donation, first depositor

| Attack | Must hold |
|---|---|
| donate before the first deposit, then `sync` | first depositor still receives fair shares (M5) |
| donate 1 wei then huge, classic 4626 inflation | virtual offset defeats it; quantify the residual |
| first depositor deposits 1 wei, then donates | second depositor is not rounded to 0 |
| donate directly to a STRATEGY `[E]` | value accrues to holders or is rescuable; never stranded |
| donate the RECEIPT token to the vault `[E]` | counted on next refresh, lifts all holders |

### 5.4 Sandwich and MEV

| Attack | Must hold |
|---|---|
| sandwich a harvest swap | bounded by the oracle floor; quantify |
| sandwich a rotation swap | same |
| deposit immediately before a harvest, withdraw after | captures ≈ nothing (pending rewards already in NAV) |
| front-run a `deployIdle` | no advantage |
| back-run a venue loss | loss already shared; no advantage |

### 5.5 Reentrancy matrix

Cross-product of {ERC-777/callback base token, malicious receiver, malicious strategy,
malicious venue} × {deposit, mint, withdraw, redeem, emergencyWithdraw, harvest, tend,
deployIdle, rebalance}. Every cell must be blocked by `nonReentrant` or provably safe.

### 5.6 Griefing and DoS

| Attack | Must hold |
|---|---|
| spam `settle()` every block | cannot trip a breaker or move an anchor |
| spam `sync()` | cannot inflate anything |
| dust deposits to bloat state `[E]` | no unbounded loop; gas stays sane |
| force a breaker trip to pause the vault `[E]` | requires real capital; quantify |
| **keeper bleeds via repeated `rebalance`** | bounded, quantified, documented (T6) |
| **keeper bleeds via repeated `tend`** | cooldown binds; quantify |
| register 5 strategies then make all revert `[E]` | emergency exit still functions |
| a strategy that makes `removeStrategy` impossible `[E]` | governance still has a path out |

### 5.7 Key-compromise blast radius

One test per role, asserting the boundary in §1.2 exactly. Each produces a written
statement of maximum loss, which becomes the security documentation.

---

## 6. Concurrency and interleaving

### 6.1 Same-block ordering

For each pair (A, B) from {deposit, withdraw, redeem, emergencyWithdraw, harvest,
deployIdle, rebalance, tend, settle, sync, addStrategy, removeStrategy, migrateStrategy,
setTargets, setDisabled, setCaps, setIdleTarget, pause, unpause}: run A then B, and B then
A, in the same block. Assert no ordering makes any user better or worse off than the
other ordering, beyond real venue costs.

That is 19×19; the mechanical way to cover it is a **bounded exhaustive-permutation
test** over a reduced action set (8 actions, all orderings of length 3 = 512 sequences)
plus the invariant suite for longer sequences.

### 6.2 Named interleavings the existing suite does not cover `[E]`

- `removeStrategy` while a withdrawal is mid-queue (via a reentrant venue)
- `migrateStrategy` between the harvest and the pricing inside one withdrawal
- `pause` landing between `refreshNav` and `_drain`
- `setTargets` between `rebalance`'s pull pass and its deploy pass
- governance executing a timelocked change in the same block as a large redemption
- reward-vault stake/unstake in the same block as a main-vault pause
- two users emergency-exiting in the same block during a shortfall (E3 fairness)

---

## 7. End-to-end lifecycle scenarios

Long, multi-actor narratives, each asserting the full property set at every step.

1. **Cradle to grave** — deploy → first deposit → add 3 strategies → deploy idle → 6
   months of yield with monthly harvest → reweight → migrate one → a venue loss → a
   breaker trip → pause → emergency exits → unpause → remove all strategies → last holder
   redeems → supply 0, NAV dust.
2. **Bank run** — 20 holders, 60% redeem in one block, venues partially illiquid; assert
   the queue is fair and nobody is advantaged by ordering.
3. **Hostile takeover attempt** — governance compromised at t; enumerate what it can and
   cannot do before the timelock elapses.
4. **Venue collapse** — one strategy's venue goes to zero over a week; assert loss lands
   pro-rata and the vault survives.
5. **Rotation through a full cycle** — BTC +40% then −35% then +20%, with deposits and
   withdrawals throughout; assert base-per-share grew and no depositor was diluted by
   another's timing.
6. **Multi-vault isolation** `[E]` — two vaults sharing facets and a strategy TYPE;
   assert storage and custody never cross.
7. **Governance-driven reconfiguration** — every admin change executed through the real
   timelock rather than a prank.

---

## 8. Invariant suite v2

Extend the handler with what it currently lacks:

- add/remove/migrate strategies mid-run (currently only reweight/disable)
- oracle price moves and oracle outages
- venue illiquidity and venue reverts (currently registered but not targeted)
- the malicious strategy from §5.1 as a registered participant
- reward-module stake/unstake
- allowance-based withdrawals by third parties
- a fourth actor that only ever attacks

Assert all of §3 continuously, plus:

- **I1** no actor's cumulative withdrawn ever exceeds their cumulative deposited + their
  pro-rata share of realized yield
- **I2** `pricePerShare` never decreases except on a real venue loss or a charged fee
- **I3** the strategy list never contains duplicates and never exceeds the max
- **I4** every allowance the vault grants a strategy is 0 outside a call
- **I5** the sum of all reward-vault positions equals its staked share balance

Run at high depth (`runs = 1000`, `depth = 500`) in CI nightly, lower in PR CI.

---

## 9. Fork and differential

- Extend fork coverage to every strategy family, not just the lending ones.
- **Differential testing** `[E]`: a Python/Solidity reference model of the share maths and
  the NAV/fee accounting; fuzz identical operation sequences against both and assert
  agreement. This is how a subtle rounding or ordering bug in the real implementation
  surfaces without having to guess where it is.
- Historical replay `[E]`: pin blocks around known stress events (March 2020, June 2022
  stETH, March 2023 USDC depeg) and run the vault through them.

---

## 10. Proving the tests actually bite

Coverage is necessary and badly insufficient. Gates:

1. **Line/branch coverage ≥ 95%** on `src/` excluding pure-doc files.
2. **Mutation testing** (`vertigo-rs` or `slither-mutate`) with **≥ 85% mutants killed**.
   Every surviving mutant is triaged: either a missing test or a documented equivalent
   mutant. This is the real measure of whether the suite constrains behaviour.
3. **Every property in §3 cited by at least one test.** A coverage matrix in CI maps
   property → test; an uncited property fails the build.
4. **Slither + Aderyn clean** or every finding triaged in writing.
5. **Halmos symbolic checks** `[E]` on the share-maths library — bounded proof of M1–M4
   rather than fuzz sampling.

---

## 11. Execution order

The order is chosen so each phase de-risks the next.

| Phase | Work | Why first |
|---|---|---|
| 1 | Property catalogue (§3) as an executable checklist + coverage matrix | everything else cites it |
| 2 | Share-maths fuzz + differential model (§4.1, §9) | accounting errors invalidate every other test |
| 3 | Withdrawal-queue matrix (§4.3) | the deepest gap, and where user funds actually leave |
| 4 | `MaliciousStrategy` suite (§5.1) | the stated top priority — funds safe under a hostile strategy |
| 5 | Oracle manipulation (§5.2) | second attack surface |
| 6 | Facet/library matrices (§4.2, §4.4–4.9) | breadth |
| 7 | Reentrancy matrix + griefing (§5.5, §5.6) | needs the hostile contracts from 4–5 |
| 8 | Rewards + governance (§4.13, §4.14) | independent modules, parallelizable |
| 9 | Interleaving + permutation (§6) | needs all actions working |
| 10 | E2E lifecycles (§7) | integration on top of proven parts |
| 11 | Invariant v2 (§8) | reuses every handler built above |
| 12 | Mutation + gates (§10) | measures everything before it |

## 12.5 Status — what is built

| Phase | Suite | Tests |
|---|---|---|
| 1 | property catalogue (§3), cited by every test name | — |
| 2 | `test/property/ShareMath.t.sol` | 31 |
| 3 | `test/queue/WithdrawalQueue.t.sol` | 27 |
| 4 | `test/attack/MaliciousStrategy.t.sol` + `EvilStrategy.sol` | 26 |
| 5 | `test/attack/OracleManipulation.t.sol` | 27 |
| 6 | `test/facets/PerformanceFee.t.sol` | 17 |
| 7 | `test/attack/Reentrancy.t.sol` + `Griefing.t.sol` | 25 |
| 8 | `test/modules/Governance.t.sol` + `Rewards.t.sol` | 48 |
| 9 | `test/e2e/Interleaving.t.sol` — 512 exhaustive orderings | 4 |
| 10 | `test/e2e/Lifecycle.t.sol` | 8 |
| 11 | `test/invariant/` — hostile actor + strategy lifecycle in the handler | 11 |
| 12 | `script/mutation.py` | 14 mutants |

Plus the pre-existing strategy suites (unit + fork) from `testing-plan.md`.

## 13. Findings log

### 🔴 HIGH — a registered strategy could drain every other strategy's position (FIXED)

**Found by** `test/attack/MaliciousStrategy.t.sol`, phase 4.

`divestFrom` / `tryDivestFrom` / `fullExit` / `EmergencyFacet._tryFullExit` each granted a
strategy an UNLIMITED allowance over whatever token its own `receiptToken()` named:

```solidity
address receipt = IStrategy(strategy).receiptToken();
if (receipt != address(0)) IERC20(receipt).forceApprove(strategy, type(uint256).max);
```

That declaration is self-reported, and `addStrategy` validated only `vault()` and
`asset()`. A strategy naming a token it did not own — another strategy's aToken, 4626
share, LST or PT — received an allowance over the VAULT'S ENTIRE HOLDING of it and
transferred it out during its own `divest`. Proven end to end: the attacker finished the
transaction holding 45,000 USDC of a second strategy's venue shares, with the user's
withdrawal completing normally so nothing rolled back.

This broke the system's primary safety boundary — "a compromised strategy can lose at
most its own allocation" — turning it into "a compromised strategy drains the vault".

**Fix:** `LibStrategyRegistry._requireExclusiveReceipt`, enforced from both `addStrategy`
and `migrateStrategy`. A non-zero declared receipt may not equal the base asset, the
share token, or any other registered strategy's receipt. `address(0)` (internal-ledger
venues: Compound III, Convex, the rotation strategies) is exempt, since nothing is ever
approved for those. `migrateStrategy` excludes the outgoing strategy, so migrating
between two adapters over the same venue still works.

**Bonus:** the same check closes a latent NAV bug with no malice involved — two honest
strategies sharing a receipt (two wrappers over one 4626, two Aave adapters on one
market) would EACH have reported the vault's whole balance as their position,
double-counting it into `totalAssets`.

### Confirmed NOT vulnerable

- **Declaring the base asset as the receipt** — stealing idle desyncs `idleBalance` from
  real custody, so the final payout transfer reverts and the whole transaction rolls
  back. Now also rejected at registration.
- **Value lies** (max uint, 2x, zero, revert, gas bomb) — all trip the circuit breaker
  before any redemption at the false price.
- **Reentrancy** — deposit-during-invest, withdraw-during-divest and harvest-during-harvest
  are all blocked by `nonReentrant`.
- **Underpaying / not paying on divest** — measured-delta accounting credits only what
  actually arrived.
- **Oracle manipulation** — inflated, collapsed and dead feeds all trip the breaker;
  deposits and redemptions against a false price revert; swap floors hold.

### 🔴 HIGH — a freshly registered strategy could brick the vault permanently (FIXED)

**Found by** the phase-11 invariant suite once a hostile strategy was allowed to register
mid-run. Pinned by `test_N1_freshlyAddedStrategyReportingHugeValueCannotBrickTheVault`.

`LibVaultNav._isSuspiciousJump` exempted the first-ever reading:

```solidity
if (lastValue == 0) return false;   // "first-ever read is never flagged"
```

So a strategy registered but not yet funded had its FIRST `positionValue()` accepted
unconditionally. Two consequences, the second fatal:

1. **NAV poisoning** — any number the strategy liked went straight into `totalAssets`.
2. **Permanent brick** — a reading near `type(uint256).max` overflows the checked
   `totalAssets += newValue` inside `_refreshNav`. Every state-changing entry point calls
   `refreshNav`: deposit, withdraw, redeem, harvest, deployIdle, rebalance,
   `emergencyWithdraw` — **and `removeStrategy` itself**. The vault would revert on every
   path with no way to remove the strategy that caused it. Unrecoverable.

**Fix:** two guards in `_isSuspiciousJump`.

- An absolute ceiling of `type(uint128).max`. No real position is worth more than 2^128
  of any token, and the ceiling keeps the NAV summation below the overflow boundary
  regardless of what any venue reports.
- `lastValue == 0` now means "never funded" — `investInto` stamps `lastValue` the moment
  capital is deployed — so ANY positive reading from such a strategy is unexplained by
  anything the vault did, and is flagged rather than trusted. A direct donation of
  receipt tokens is the one benign case this catches; it freezes at zero and governance
  adopts the real figure via `clearStrategyCircuitBreak`.

### 🟢 MEDIUM — `rescue` could withdraw ARTHA earned but not settled (FIXED)

**Found by** `test/modules/Rewards.t.sol`, phase 8. Pinned by
`test_R6_GAP_rescueCanTakeArthaThatIsAccruedButNotYetSettled`.

`UserRewardVault.rescue` protects staker funds with:

```solidity
uint256 owed = outstandingArtha();          // totalArthaMinted - totalArthaClaimed
uint256 excess = bal > owed ? bal - owed : 0;
require(amount <= excess, "EXCEEDS_EXCESS");
```

But `totalArthaMinted` only grows inside `_settle`, which runs on stake / unstake /
claim. A staker who has simply held a position for months has accrued real, owed ARTHA
that `outstandingArtha()` still reports as **zero**. The manager can therefore rescue the
entire ARTHA balance, after which those stakers hit `NO_ARTHA_LIQUIDITY` on claim.

Demonstrated: alice stakes, 100 days pass, `pendingArtha` is non-zero while
`outstandingArtha()` is 0, the full balance is rescued, and alice's claim then reverts.

This is a TRUSTED-role action, so it is a footgun rather than an open exploit — but the
excess check exists precisely to make this impossible, and it does not.

**Fix:** option 1, tracked exactly rather than approximated. `UserRewardSystem` now keeps
two running sums per vault — `_totalStaked` and `_weightedDebt` (`Σ shares × rewardDebt`)
— which give the whole vault's unsettled accrual in O(1):

```
unsettled = (totalStaked × accNow − Σ shares·rewardDebt) / 1e18
```

That is exactly `Σ _accruedSince(user)` without iterating users. `outstandingArtha()` now
returns settled debt plus unsettled accrual, clamped to the programme's remaining budget
(the same clamp `_settle` applies). Both sums are maintained at the four places a
position changes — `_settle`, `stake`, `unstake`, `emergencyUnstake` — through
`_restampDebt` / `_addShares` / `_removeShares`, so no write to `shares` or `rewardDebt`
can bypass them.

### Behaviours documented rather than changed

- **Double rounding makes `withdraw(exactly what you paid for)` impossible.** Mint rounds
  assets up and withdraw rounds shares up, so a minter is always ~1 wei of shares short of
  withdrawing their exact cost. Correct and intended; `redeem` is the exact-exit path.
- **A donation to an EMPTY vault is absorbed by the virtual-share offset** rather than
  reaching the first depositor. Anyone seeding a vault by donating should know the seed
  does not reach users until supply grows. Donations to a SEEDED vault do reach holders.
- **A large donation makes small first deposits revert** with `ZERO_SHARES` rather than
  minting zero. Safe (OZ-4626 behaviour), and irrational to attempt: the donation funds
  whoever deposits next.
- **`migrateStrategy` moves the replacement to the BACK of the withdrawal queue**, since
  it is removed and re-pushed. Intentional or not, it changes drain priority.
- **The per-block withdraw cap is global, not per-caller** — the `msg.sender` key only
  selects the exemption. An exempt caller can therefore drain a non-exempt owner's shares
  without consuming the cap.

## 12. Deliverables

- `test/property/` — the executable property catalogue and coverage matrix
- `test/attack/` — MaliciousStrategy, OracleManipulation, Reentrancy, Inflation, Griefing,
  KeyCompromise
- `test/queue/` — the withdrawal-queue matrix
- `test/facets/` — per-facet deep matrices
- `test/modules/` — rewards, governance
- `test/e2e/` — the seven lifecycle scenarios
- `test/differential/` — reference model and comparison harness
- `test/invariant/` — v2 handler and expanded properties
- `docs/security-properties.md` — §3 as the living specification
- `docs/blast-radius.md` — §5.7 results: maximum loss per compromised role
