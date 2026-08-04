# Artha Protocol — Security Audit Report (v2)

**Date:** 2026-08-04
**Commit:** `d73bd68` ("manual audit is done")
**Auditor:** AI security review (Claude)

**In scope**
`src/Vault.sol`, `src/VaultShareToken.sol`, `src/facets/**` (Deposit, Withdraw, Strategy, Admin, Emergency, View), `src/libraries/**` (VaultStorage, LibVaultNav, LibVaultMath, LibVaultFee, LibVaultCap, LibStrategyRegistry), `src/rewards/**`, `src/oracle/**`, `src/governance/**`, and the vault↔strategy **boundary** (`IStrategy`, `BaseStrategy`).

**Out of scope (per client instruction)**
Concrete strategy implementations under `src/strategies/usdc/**`, `src/strategies/common/**`, `src/strategies/swap/**`, and all of `strategies_pending/**`. **Assumption: every strategy behaves correctly and honestly.** Findings below therefore never rely on a buggy strategy — where a finding involves a strategy it is because the *vault* mis-handles a **correct** strategy's output, or because an *unprivileged third party* can perturb a correct strategy from the outside.

**Test coverage:** `test/` and `script/` are **empty**. Zero tests across ~3,000 lines of in-scope vault code. This is factored into every likelihood rating.

---

## 1. Verdict on the four reported issues

| # | Your claim | Verdict |
|---|---|---|
| 1 | `removeStrategy`/`migrateStrategy` call `harvest()`, base reaches the vault, but idle is not credited — only the transfer happens | ✅ **VALID — High.** See **H-01**. Confirmed by state trace; atomically exploitable in a single block. |
| 2 | `emergencyWithdraw` should only be callable when the protocol is paused | ✅ **VALID — High.** See **H-02**. It is worse than you framed it: it is permissionless *and* unpaused *and* bypasses the withdraw flow cap, and a dust-share holder can force a full unwind of every strategy. |
| 3 | After a full exit the NAV is not fetched — is that a problem? | ⚠️ **PARTIALLY VALID.** `refreshNav()` *is* called after `fullExit` on all three paths (`AdminFacet.removeStrategy:65`, `AdminFacet.migrateStrategy:70`, `EmergencyFacet.emergencyWithdraw:89`), so the literal claim does not hold. But that refresh is **wrong** on two paths for reasons adjacent to your instinct: it runs against a NAV that is missing the harvest proceeds (**H-01**), and in `emergencyWithdraw` the refresh happens *after* the caller was already priced and paid, so the unwind loss lands on everyone else (**H-03**). |
| 4 | After `invest()`, dust returned to the vault is not accounted (not added to idle, not adjusted on the strategy) | ❌ **INVALID as stated** — but you found a real bug next to it. `LibStrategyRegistry.investInto` accounts by **balance-delta** (`spent = beforeBal - afterBal`, [LibStrategyRegistry.sol:56-64](src/libraries/LibStrategyRegistry.sol#L56-L64)), so returned dust reduces `spent` and therefore *stays* in idle and is *not* added to `strategyLastValue`. Correct. **However** that delta is computed against the strategy's *entire* base balance, not this call's leftover, so any base token sitting in the strategy corrupts it — see **M-01** (griefing DoS + forced circuit-breaker trip). |

---

## 2. Severity summary

| Severity | Count |
|---|---|
| Critical | 1 |
| High | 8 |
| Medium | 17 |
| Low | 12 |
| Informational | 6 |

**Systemic themes**

1. **Two ledgers that can silently disagree.** `idleBalance` (hand-maintained) vs. the vault's real ERC-20 balance; `navCheckpoint` (hand-adjusted with `+=`/`-=`) vs. a real `refreshNav()`. Every place that writes one without the other is a bug or a latent one. H-01, M-02, M-14 all live here.
2. **Exit-path pricing is computed before the exit's cost is known.** Both `withdraw`/`redeem` and `emergencyWithdraw` price the caller against pre-unwind NAV and pay them in full, so unwind cost is socialized onto everyone who stays. H-03, M-02.
3. **The circuit breaker limits the *rate* of change, and an unprivileged caller controls the *cadence*.** `settle()` is permissionless, so the attacker, not the protocol, decides how often `lastValue` re-anchors. H-06, H-07.
4. **A stalled strategy is not contained.** A broken strategy keeps its stale value in NAV (H-04); a strategy that reverts on `divest` bricks *every* normal withdrawal because `_drain` has no `try/catch` (H-05).
5. **Privileged setters are individually validated but not jointly validated.** `setIdleTargetBps` and `setTargets` can each be used to break the "weights + idle == 100%" invariant that the rest of the code documents as guaranteed (M-03, M-04, M-05).

---

## 3. Critical

### [CRITICAL] C-01 — `StrategyFacet.harvest(address)` never checks that the strategy is registered → a keeper can mint idle out of nothing and drain the vault

- **Location:** [src/facets/StrategyFacet.sol:28-35](src/facets/StrategyFacet.sol#L28-L35)
- **Confidence:** Confirmed.

```solidity
function harvest(address strategy) external onlyKeeper nonReentrant returns (uint256 realized) {
    VaultStorage.Layout storage s = VaultStorage.vaultLayout();
    require(!s.strategyBroken[strategy], "STRATEGY_BROKEN");   // <-- the ONLY check
    realized = IStrategy(strategy).harvest();
    if (realized != 0) s.idleBalance += realized;              // trusts a return value
    LibVaultNav.refreshNav();
}
```

There is no `_isKnown(s, strategy)` check, and `realized` is taken **on trust** rather than measured as a balance delta. `strategyBroken` on an unknown address is `false`, so the guard passes for any address.

**Exploit (keeper key only — no governance needed):**

1. Keeper deploys `Evil` with `harvest() { return 10_000_000e6; }` — it transfers nothing.
2. `harvest(address(Evil))` → `s.idleBalance += 10_000_000e6`. NAV and PPS inflate by that amount.
3. Keeper redeems their (small, pre-existing) share position. `convertToAssetsDown` prices against the inflated NAV, and `WithdrawFacet._drain` pays it out of **real** idle and by divesting **real** strategies.
4. Repeat until the vault's real assets are gone.

**Impact.** Total loss of vault funds from a *keeper* key. The keeper role is documented as least-privilege ("keeps NAV fresh and capital where it should be") and is expected to be a hot automation key — it must not be able to reach user principal. This is a privilege escalation from operational to custodial.

**Fix.**

```solidity
require(LibStrategyRegistry.isKnown(strategy), "UNKNOWN_STRATEGY");  // expose _isKnown
// and measure, do not trust:
uint256 before = IERC20(s.baseAsset).balanceOf(address(this));
IStrategy(strategy).harvest();
realized = IERC20(s.baseAsset).balanceOf(address(this)) - before;
s.idleBalance += realized;
```

Apply the same balance-delta discipline to `_harvestAll` and `WithdrawFacet._harvestAllActive`.

---

## 4. High

### [HIGH] H-01 — `removeStrategy` / `migrateStrategy` discard the harvest return value: base lands in the vault untracked, NAV is understated, and the gap is atomically extractable *(your issue #1)*

- **Location:** [src/libraries/LibStrategyRegistry.sol:174-178](src/libraries/LibStrategyRegistry.sol#L174-L178), [src/libraries/LibStrategyRegistry.sol:208-212](src/libraries/LibStrategyRegistry.sol#L208-L212)
- **Confidence:** Confirmed (state traced).

```solidity
if (!s.strategyBroken[strategy]) {
    try IStrategy(strategy).harvest() {} catch { revert("HARVEST_FAILED"); }   // return DROPPED
}
```

`BaseStrategy.harvest()` claims rewards, swaps to base, `safeTransfer`s the realized base **to the vault**, and returns the amount ([BaseStrategy.sol:130-136](src/strategies/BaseStrategy.sol#L130-L136)). Every other caller credits it — `StrategyFacet.harvest:32`, `StrategyFacet._harvestAll:138`, `WithdrawFacet._harvestAllActive:101`. These two do not. The tokens are in the vault; `idleBalance` does not know about them; `refreshNav()` derives NAV from `idleBalance`, so NAV is short by exactly the harvested amount.

**Traced state** (idle 100, strategy 900, NAV 1000, harvest realizes 50):

| step | vault real balance | `idleBalance` | `navCheckpoint` |
|---|---|---|---|
| before | 100 | 100 | 1000 |
| after `harvest()` | **150** | 100 | 1000 |
| after `fullExit()` | 1050 | 1000 | 1000 |
| after `refreshNav()` | 1050 | 1000 | **1000** ← short by 50 |

**Exploit.** Timelock payloads are public for `minDelay` seconds *and* `EXECUTOR_ROLE == address(0)` (open execution), so the attacker can execute the `removeStrategy` operation themselves and bundle everything into one block:

1. Execute the queued `removeStrategy` / `migrateStrategy`.
2. `deposit(D)` — priced at the understated PPS, so the attacker over-mints.
3. `sync()` (permissionless, [EmergencyFacet.sol:47](src/facets/EmergencyFacet.sol#L47)) → `idleBalance` catches up to the real balance, NAV jumps by the harvested amount.
4. `redeem()` — the attacker captures `D/(D+NAV) × harvested`.

With a whale-sized `D` (bounded only by `depositCapPerBlock`, which defaults to 0 = uncapped) the attacker takes nearly the whole harvest. Existing holders are diluted by the same amount.

**Secondary impact on `migrateStrategy`:** `investInto(to, freed)` is called with `freed` from `fullExit` only, so the harvested base is also **not redeployed** — it silently becomes permanent idle drag until someone calls `sync()`.

**Fix.** Credit it, exactly as every other call site does:

```solidity
if (!s.strategyBroken[strategy]) {
    try IStrategy(strategy).harvest() returns (uint256 realized) {
        if (realized != 0) s.idleBalance += realized;
    } catch { revert("HARVEST_FAILED"); }
}
```

Better: call `LibVaultNav.sync()` at the top of `removeStrategy` and `migrateStrategy` as a belt-and-braces reconciliation, and add the invariant test `idleBalance == baseAsset.balanceOf(vault)` after **every** state-changing entry point.

---

### [HIGH] H-02 — `emergencyWithdraw` is permissionless, un-paused, and uncapped: a dust-share holder can force a full unwind of every strategy at will *(your issue #2)*

- **Location:** [src/facets/EmergencyFacet.sol:54-92](src/facets/EmergencyFacet.sol#L54-L92)
- **Confidence:** Confirmed.

`emergencyWithdraw` carries **only** `nonReentrant`. It has no `whenPaused`, no `onlyGuardian`, and — unlike `WithdrawFacet._burnAndPay` — it never calls `LibVaultCap.checkAndConsumeWithdraw`. Three separate problems:

**(a) Griefing / yield destruction.** The gather loop unwinds a *whole* strategy per iteration, regardless of how small the shortfall is:

```solidity
if (s.idleBalance < entitlement) {
    for (uint256 i; i < n && s.idleBalance < entitlement; i++) _tryFullExit(s, strats[i]);
}
```

`_tryFullExit` calls `IStrategy.emergencyWithdraw()`, which is the **no-slippage-bound, no-harvest escape hatch**. So:

1. Attacker holds 1 wei of shares.
2. Attacker first drains idle with a normal `withdraw()` (or simply waits for a moment when `idleBalance == 0`, which is the steady state whenever `idleTargetBps` is small and the keeper has just deployed).
3. Attacker calls `emergencyWithdraw(1, self, self)`. `entitlement` is ~0 but `idleBalance` is 0, so `0 < entitlement` is false only if entitlement is exactly 0 — for any non-zero entitlement the loop runs and **fully unwinds `strategies[0]`**.
4. Repeat next block with the next dust share. Every strategy can be walked out of the vault.

Cost to the attacker: gas. Cost to the protocol: the vault sits 100% idle, earns nothing, and eats venue exit costs on every forced unwind. The keeper's `deployIdle` re-deploys, and the attacker unwinds again — an indefinite grind.

**(b) Withdraw flow cap is bypassed entirely.** `withdrawCapPerBlock` is the documented "defense against a single-block attack or a bank-run cascade" ([LibVaultCap.sol:10-16](src/libraries/LibVaultCap.sol#L10-L16)). `emergencyWithdraw` never consults it, so any whale can exit their full position in one block by routing through the emergency path. The cap protects nothing.

**(c) Pause is bypassed.** This is *partly* intentional (a guaranteed exit during an emergency) — but combined with (a) it means that during the very emergency the guardian paused for, any address can keep force-unwinding strategies while governance is stuck behind a 2-day timelock to unpause.

**Fix.** Your proposed fix is the right one, plus two more:

```solidity
function emergencyWithdraw(uint256 shares, address receiver, address owner)
    external nonReentrant whenPaused returns (uint256 assetsReceived)
```

1. Add `whenPaused` — the guaranteed exit only exists once an emergency has been declared.
2. Bound the unwind to the shortfall: divest `entitlement - idleBalance` from each strategy in priority order (`LibStrategyRegistry.divestFrom`), and only escalate to `_tryFullExit` if the bounded path cannot produce the amount.
3. Either apply `checkAndConsumeWithdraw`, or explicitly document that the emergency path is deliberately uncapped and lower `withdrawCapPerBlock`'s claimed guarantee in the docs.

---

### [HIGH] H-03 — `emergencyWithdraw` prices the caller *before* the unwind and burns their full shares even on a shortfall → unwind losses socialized, caller's residual value confiscated

- **Location:** [src/facets/EmergencyFacet.sol:64-89](src/facets/EmergencyFacet.sol#L64-L89)
- **Confidence:** Confirmed. *(This is the substantive version of your issue #3.)*

Ordering:

```solidity
LibVaultNav.refreshNav();                                  // 1. price against PRE-unwind NAV
uint256 entitlement = LibVaultMath.convertToAssetsDown(shares);
VaultShareToken(s.shareToken).burn(owner, shares);         // 2. burn ALL shares
... _tryFullExit(...) ...                                  // 3. unwind — cost realized HERE
assetsReceived = min(s.idleBalance, entitlement);           // 4. pay
LibVaultNav.refreshNav();                                  // 5. NAV finally reflects the loss
```

**Loss socialization.** `entitlement` is computed at step 1 from marked-to-market `positionValue()`. The unwind at step 3 realizes exit fees / slippage / venue haircuts. The caller is paid the *pre-loss* entitlement in full (step 4), so **100% of the unwind cost lands on the holders who stayed**. Because H-02 makes this permissionless, it is a standing first-mover advantage: whoever calls `emergencyWithdraw` first exits at marks, everyone else pays for it. This is the bank-run primitive the old report flagged as H-02, now reachable without any strategy actually failing.

**Confiscation on shortfall.** If the gather comes up short (`assetsReceived < entitlement`), the *full* `shares` were already burned at step 2. The caller permanently loses `entitlement - assetsReceived` of value, which stays in the vault and accrues to everyone else. The header says this is deliberate ("NEVER reverts on shortfall") but the design is one-sided — a partial payout should burn a *proportional* number of shares.

**Fix.**

```solidity
// after gathering, before burning:
assetsReceived = s.idleBalance < entitlement ? s.idleBalance : entitlement;
uint256 sharesToBurn = Math.mulDiv(shares, assetsReceived, entitlement, Math.Rounding.Ceil);
VaultShareToken(s.shareToken).burn(owner, sharesToBurn);
```

and re-price `entitlement` **after** the unwind (`refreshNav()` again at step 3.5) so the caller absorbs the cost of the exit they triggered.

---

### [HIGH] H-04 — A circuit-broken or read-reverting strategy keeps its stale value in NAV while `_drain` refuses to touch it → redemption becomes first-come-first-served

- **Location:** [src/libraries/LibVaultNav.sol:78-102](src/libraries/LibVaultNav.sol#L78-L102), [src/facets/WithdrawFacet.sol:117-123](src/facets/WithdrawFacet.sol#L117-L123)
- **Confidence:** Confirmed. *(Carried forward from v1 H-02; still present after the refactor.)*

`refreshNav` deliberately falls back to `strategyLastValue` in all three degraded cases (already broken / suspicious jump / read reverted). If the strategy genuinely **lost** value, NAV is now overstated by the shortfall. `_drain` then skips that strategy:

```solidity
if (s.strategyBroken[strat]) continue;
```

So each redeemer burns shares priced at an inflated PPS and is paid in **real** assets out of idle and the still-healthy strategies. Early exiters leave whole; the entire shortfall concentrates on whoever is last.

Note the asymmetry that makes this *self-triggering*: `_isSuspiciousJump` trips on movement **in either direction** ([LibVaultNav.sol:116-121](src/libraries/LibVaultNav.sol#L116-L121)). A genuine loss larger than `strategyMaxDeltaBps` is exactly the event that freezes the value at its pre-loss level. The breaker's fail-safe converts a contained loss into an unfair race.

**Fix.** When a strategy is broken, either (a) mark its value as **unavailable** and exclude it from the NAV used for *redemption* pricing while still reporting it separately, or (b) socialize immediately by writing NAV down to a conservative floor and letting governance write it back up after investigation. Option (a) plus a pro-rata "locked share" claim is the standard resolution. At minimum, `pause()` should be auto-triggered on `StrategyCircuitBroken` so the guardian window is not a race.

---

### [HIGH] H-05 — One strategy whose `divest` reverts bricks **all** normal withdrawals: `_drain` has no `try/catch`

- **Location:** [src/facets/WithdrawFacet.sol:111-124](src/facets/WithdrawFacet.sol#L111-L124), [src/libraries/LibStrategyRegistry.sol:70-84](src/libraries/LibStrategyRegistry.sol#L70-L84)
- **Confidence:** Confirmed.

```solidity
for (uint256 i; i < n && remaining != 0; i++) {
    address strat = strats[i];
    if (s.strategyBroken[strat]) continue;
    uint256 freed = LibStrategyRegistry.divestFrom(strat, remaining);   // <-- no try/catch
    remaining -= freed < remaining ? freed : remaining;
}
```

`divestFrom` makes three unguarded external calls (`receiptToken()`, `forceApprove`, `divest()`). Any revert propagates and kills the entire withdrawal.

The trap is that **`refreshNav`'s `catch` branch does not set `strategyBroken`** ([LibVaultNav.sol:98-101](src/libraries/LibVaultNav.sol#L98-L101)) — it just emits `StrategyReadReverted` and keeps the stale value. So a venue that is paused/frozen (Aave freeze, Compound pause, Euler pause — all normal, non-buggy venue states that a *correct* strategy will faithfully revert on) leaves the strategy **not flagged broken**, `_drain` walks into it, and every `withdraw`/`redeem` in the vault reverts. Users' only remaining exit is `emergencyWithdraw`, which is the lossy path (H-03).

**Fix.** Wrap the divest in `try/catch` and `continue` on failure, and make the `catch` in `refreshNav` set `strategyBroken = true` (or a distinct `strategyStalled` flag) so `_drain` skips it deterministically:

```solidity
try this.divestFromExternal(strat, remaining) returns (uint256 freed) {
    remaining -= freed < remaining ? freed : remaining;
} catch { emit StrategyDivestFailed(strat); }
```

---

### [HIGH] H-06 — The circuit breaker bounds the *rate* of change, and `settle()` lets an unprivileged caller choose the cadence → the threshold can be walked past in steps

- **Location:** [src/libraries/LibVaultNav.sol:88-96](src/libraries/LibVaultNav.sol#L88-L96), [src/facets/StrategyFacet.sol:43-46](src/facets/StrategyFacet.sol#L43-L46)
- **Confidence:** Confirmed (logic), High (economic feasibility depends on the venue).

`_isSuspiciousJump` compares `newValue` against `strategyLastValue`, and on acceptance **ratchets** `strategyLastValue = newValue`. There is no absolute anchor and no time component. `settle()` is permissionless, callable every block, and does exactly one thing: re-anchor.

Consequence: the breaker limits movement *per refresh*, not *per unit time* or *in total*. An attacker who can move `positionValue()` by anything under `strategyMaxDeltaBps` — and `positionValue()` is oracle-dependent via `BaseStrategy._pendingRewardsValue()` ([BaseStrategy.sol:148-150](src/strategies/BaseStrategy.sol#L148-L150), [BaseStrategy.sol:168-182](src/strategies/BaseStrategy.sol#L168-L182)) — can call `settle()` after each sub-threshold move and walk NAV to an arbitrary value in `k` steps, never once tripping the breaker.

Conversely, an attacker who wants to *trip* the breaker just refrains from calling `settle()` and waits for legitimate accrual to exceed the threshold in one gap. With `strategyMaxDeltaBps` set tight (say 100 = 1%), a strategy left unrefreshed across a normal yield period trips on **honest growth** and freezes (H-04). The parameter is caught between "tight enough to stop manipulation" and "loose enough to survive real accrual", and nothing in the code resolves that tension.

**Fix.** Anchor the breaker to something the caller does not control:
- Rate-limit per unit **time**, not per call: `limit = lastValue × maxDeltaBps × elapsed / (BPS × window)`, with `lastRefreshAt` stored per strategy.
- Never let a *permissionless* call ratchet `strategyLastValue` upward — let `settle()` compute NAV but only allow keeper/governance paths to re-anchor the breaker baseline.
- Cap the *absolute* deviation from the last keeper-confirmed value, not just the per-step deviation.

---

### [HIGH] H-07 — `clearStrategyCircuitBreak` does not re-anchor `strategyLastValue`, so the breaker re-trips on the next refresh; there is no admin path to reset it

- **Location:** [src/libraries/LibStrategyRegistry.sol:160-165](src/libraries/LibStrategyRegistry.sol#L160-L165), [src/facets/AdminFacet.sol:59-61](src/facets/AdminFacet.sol#L59-L61)
- **Confidence:** Confirmed.

```solidity
function clearCircuitBreak(address strategy) internal {
    ...
    s.strategyBroken[strategy] = false;    // that is all it does
}
```

The breaker tripped precisely *because* `|positionValue - lastValue| > maxDelta`. Clearing the flag without moving `lastValue` leaves that inequality intact, so the very next `refreshNav()` — including one triggered by any user's `deposit`, or by anyone calling `settle()` in the same block — re-trips it. **There is no function anywhere in the codebase that writes `strategyLastValue` to an administratively chosen value.**

The only escape is `removeStrategy`, which forces the strategy out of the vault entirely and (see M-06) writes off the position without a real dust check. Governance therefore has no way to say "we investigated, the 20% drop is real, resume normal operation" — the strategy is permanently unusable.

**Fix.** Add an explicit re-anchor, timelocked and event-emitting:

```solidity
function clearCircuitBreak(address strategy, uint256 confirmedValue) internal {
    require(_isKnown(s, strategy), "UNKNOWN_STRATEGY");
    s.strategyLastValue[strategy] = confirmedValue;   // governance-confirmed anchor
    s.strategyBroken[strategy] = false;
    emit StrategyCircuitCleared(strategy, confirmedValue);
}
```

Guard `confirmedValue` against `positionValue()` within a sanity band so a fat-finger cannot mint NAV.

---

### [HIGH] H-08 — `UserRewardVault.setRewardRate` is unbounded: one bad value permanently bricks the staking contract and locks every staked share

- **Location:** [src/rewards/UserRewardVault.sol:267-270](src/rewards/UserRewardVault.sol#L267-L270), [src/rewards/UserRewardSystem.sol:128-158](src/rewards/UserRewardSystem.sol#L128-L158)
- **Confidence:** Confirmed.

`setRewardRate` has no upper bound. The index advances as `accRewardPerShare += rewardRate * elapsed` and is read on **every** path:

```solidity
function _currentAcc(address _vault) internal view returns (uint256) {
    uint256 elapsed = block.timestamp - e.rateCheckpoint;
    return e.accRewardPerShare + e.rewardRate * elapsed;   // 0.8.x checked math
}
```

Set `rewardRate` near `type(uint256).max`. One second later `rewardRate * elapsed` overflows and reverts. `_currentAcc` is called by `_accruedSince` → `_settle`, which is the first statement of `stake`, `unstake`, **and** `claimArtha`. All three revert forever.

The recovery path is also dead: `setRewardRate(0)` first calls `_advanceAcc`, which itself computes `e.accRewardPerShare += e.rewardRate * elapsed` and reverts with the same overflow. **The state is unrecoverable** — every share staked in that vault is permanently locked in the contract, and accrued ARTHA is permanently unclaimable.

Note this needs no malice — a units mistake (ARTHA-per-share-per-**year** pasted into a per-**second** field, or a `1e18`-scaling slip) is sufficient.

**Fix.**

```solidity
uint256 public constant MAX_REWARD_RATE = 1e18;  // 1 ARTHA per share per second — already absurd
require(rewardRate_ <= MAX_REWARD_RATE, "RATE_TOO_HIGH");
```

Additionally add an `emergencyUnstake(vault)` that skips `_settle` entirely, so principal is never hostage to accrual math.

---

## 5. Medium

### [MEDIUM] M-01 — Stray base token in a strategy corrupts `investInto`'s balance-delta: anyone can DoS `deployIdle`/`rebalance`/`migrateStrategy` or force a circuit-breaker trip *(adjacent to your issue #4)*

- **Location:** [src/libraries/LibStrategyRegistry.sol:51-65](src/libraries/LibStrategyRegistry.sol#L51-L65), [src/strategies/BaseStrategy.sol:110-119](src/strategies/BaseStrategy.sol#L110-L119)
- **Confidence:** Confirmed (arithmetic re-derived).

`BaseStrategy.invest` returns its **entire** base balance as "dust", not just this call's leftover:

```solidity
uint256 dust = asset.balanceOf(address(this));
if (dust != 0) asset.safeTransfer(vault, dust);
```

`investInto` then infers what was deployed from the vault's balance delta. Any base token an outsider sends directly to the strategy address is indistinguishable from un-deployed leftover.

**Case A — accounting desync + forced breaker trip.** Attacker sends `20` base to the strategy. Keeper deploys `600`:

| | value |
|---|---|
| `spent` measured | `580` |
| actually deployed to venue | `600` |
| `strategyLastValue` credited | `580` ← understated by 20 |
| next `refreshNav()` reads | `600` |
| `diff` vs `lastValue` | `20` |

If `20 > 580 × strategyMaxDeltaBps / 10_000` the **circuit breaker trips on a perfectly healthy strategy** — which then cascades into H-04 (frozen NAV) and H-07 (unclearable). With `strategyMaxDeltaBps = 100` (1%), tripping a 580-unit deploy costs the attacker ~6 units.

**Case B — outright DoS.** Attacker sends `S` base to the strategy where `S > toDeploy`. Then `afterBal > beforeBal` and

```solidity
uint256 spent = beforeBal - base.balanceOf(address(this));   // underflow -> revert
```

`deployIdle`, `rebalance`, and `migrateStrategy` all revert. Capital cannot be deployed at all. The attacker's cost is the donated amount, which is only recovered on a later successful invest — but they can re-donate every block.

**Fix.** Measure the leftover from *this* call, in the strategy:

```solidity
function invest(uint256 assets) external onlyVault nonReentrant {
    uint256 before = asset.balanceOf(address(this));
    asset.safeTransferFrom(vault, address(this), assets);
    _invest(assets);
    uint256 bal = asset.balanceOf(address(this));
    uint256 leftover = bal > before ? bal - before : 0;   // never return pre-existing balance
    if (leftover != 0) asset.safeTransfer(vault, leftover);
}
```

and make `investInto` saturating rather than underflowing (`spent = beforeBal > afterBal ? beforeBal - afterBal : 0`), plus `LibVaultNav.sync()` afterward to fold any surplus back into idle.

---

### [MEDIUM] M-02 — Withdrawal slippage is socialized: `withdraw`/`redeem` price the caller pre-divest and decrement `navCheckpoint` by the payout, not by the realized loss

- **Location:** [src/facets/WithdrawFacet.sol:111-129](src/facets/WithdrawFacet.sol#L111-L129), [src/libraries/LibStrategyRegistry.sol:79-83](src/libraries/LibStrategyRegistry.sol#L79-L83)
- **Confidence:** Confirmed.

`shares` is fixed from pre-divest NAV, then `_drain` divests, then:

```solidity
s.idleBalance -= assets;
s.navCheckpoint -= assets;      // assumes the vault lost exactly `assets` of value
```

But `divestFrom` credits `freed` to idle and decrements `strategyLastValue` by the *same* `freed` — while the venue position actually shrank by `freed + exitCost`. Net: the vault lost `assets + exitCost` but `navCheckpoint` fell by only `assets`.

Worked example (idle 0, strategy 1000, NAV 1000, 5% venue exit fee, user redeems 100):

- `divestFrom(strat, 100)` burns receipts worth 105 to deliver 100 → `freed = 100`, `lastValue = 900`, real position 895.
- `navCheckpoint = 900`, truth = 895. **Overstated by 5.**
- Any withdrawal in the same block prices against 900. The 5 is only recognized on the next `refreshNav`, at which point it is borne entirely by the remaining holders.

**Fix.** Re-run `refreshNav()` after `_drain` and before finalizing, or charge the realized shortfall to the withdrawer by re-pricing shares against post-divest NAV. At minimum, replace `s.navCheckpoint -= assets` with a fresh `refreshNav()`.

---

### [MEDIUM] M-03 — `setIdleTargetBps` bypasses the weights-sum invariant that `setTargets` enforces

- **Location:** [src/facets/AdminFacet.sol:95-99](src/facets/AdminFacet.sol#L95-L99) vs. [src/libraries/LibStrategyRegistry.sol:145-149](src/libraries/LibStrategyRegistry.sol#L145-L149)
- **Confidence:** Confirmed.

`setTargets` documents and enforces `Σ strategyWeightBps + idleTargetBps == BPS_DENOMINATOR`. `setIdleTargetBps` writes the same field with only `bps <= MAX_IDLE_BPS`:

```solidity
function setIdleTargetBps(uint16 bps) external onlyGovernance {
    require(bps <= MAX_IDLE_BPS, "IDLE_TOO_HIGH");
    VaultStorage.vaultLayout().idleTargetBps = bps;    // no sum check
}
```

Start from weights `9_500` + idle `500` = 10 000. Call `setIdleTargetBps(1_000)` → total 10 500. `deployIdle` now has per-strategy targets summing to 95% of NAV *and* an idle target of 10%, i.e. it is asked to allocate 105% of the vault. It silently under-fills (the loop is bounded by `available`), so the actual allocation depends on strategy ordering rather than on the configured weights. Setting it to `0` leaves 5% of the vault permanently unallocated with no signal.

**Fix.** Either delete `setIdleTargetBps` (governance already restates the full split via `setTargets`) or make it re-validate:

```solidity
uint256 sum = bps;
for (uint256 i; i < s.strategies.length; i++) sum += s.strategyWeightBps[s.strategies[i]];
require(sum == BPS_DENOMINATOR, "WEIGHTS_NOT_100");
```

---

### [MEDIUM] M-04 — `setTargets` accepts duplicate strategies, leaving other strategies' weights stale while still passing the 100% check

- **Location:** [src/libraries/LibStrategyRegistry.sol:124-151](src/libraries/LibStrategyRegistry.sol#L124-L151)
- **Confidence:** Confirmed.

The function checks `strategies_.length == registered.length` and that each entry is known, but **never checks uniqueness**. With registered `= [A, B]`, the call `setTargets([A, A], [5000, 4000], 1000)` passes every check (`sum == 10_000`), sets `A`'s weight to 4 000 (the second write wins), and leaves **`B`'s old weight untouched**.

If `B` previously held 5 000, effective allocation is now `4 000 + 5 000 + 1 000 = 10 000`… by coincidence. Any other prior value for `B` breaks the invariant silently, in either direction, with no revert and a `TargetsSet` event that looks correct.

**Fix.** Enforce uniqueness (a bitmap over registered indices is cheapest at `MAX_STRATEGIES_PER_VAULT = 5`):

```solidity
uint256 seen;
for (uint256 i; i < strategies_.length; i++) {
    uint256 idx = _indexOf(s, strategies_[i]);   // reverts if unknown
    require(seen & (1 << idx) == 0, "DUPLICATE_STRATEGY");
    seen |= 1 << idx;
    ...
}
```

---

### [MEDIUM] M-05 — `removeStrategy` never restates weights, silently breaking the "allocate exactly 100%" invariant

- **Location:** [src/libraries/LibStrategyRegistry.sol:170-193](src/libraries/LibStrategyRegistry.sol#L170-L193)
- **Confidence:** Confirmed.

`delete s.strategyWeightBps[strategy]` removes weight `W` from the split; nothing re-adds it. Afterwards `Σ weights + idleTargetBps == 10_000 - W`. The vault permanently under-deploys `W` bps until governance separately calls `setTargets`, and nothing forces or reminds them to. Note `addStrategy` *does* require a full restatement, so the asymmetry is clearly unintentional.

**Fix.** Require a full restatement on removal too — `removeStrategy(address strategy, uint256 dustFloor, address[] calldata allStrategies, uint16[] calldata allWeightsBps, uint16 idleTargetBps)` — mirroring `addStrategy`.

---

### [MEDIUM] M-06 — `removeStrategy` on a **broken** strategy skips the residual check entirely, and `dustFloor` is caller-chosen and unbounded

- **Location:** [src/libraries/LibStrategyRegistry.sol:182-184](src/libraries/LibStrategyRegistry.sol#L182-L184)
- **Confidence:** Confirmed.

```solidity
uint256 remaining = s.strategyBroken[strategy] ? 0 : IStrategy(strategy).positionValue();
uint256 dust = remaining <= dustFloor ? remaining : 0;
require(remaining == 0 || remaining <= dustFloor, "UNRECOVERABLE_BALANCE");
```

Two problems:

1. **Broken ⇒ `remaining = 0` unconditionally.** The `UNRECOVERABLE_BALANCE` guard is skipped for exactly the strategies most likely to *have* an unrecoverable balance. A broken strategy holding its full position is removed with no warning, `strategyLastValue` is deleted, and NAV instantly drops by the full position value — a step-function loss for every holder, with the receipt tokens still sitting in the vault but no longer readable or redeemable by any registered strategy.
2. **`dustFloor` is an arbitrary caller parameter.** `removeStrategy(S, type(uint256).max)` write-offs any position. It is `onlyGovernance`, but it is a single-transaction, no-second-check path to destroying value; it should not be expressible.

Also note `fullExit` at line 180 is **not** wrapped in `try/catch`, so a strategy whose venue is frozen reverts here and can never be removed at all (see M-17).

**Fix.** Read `positionValue()` in a `try/catch` even when broken; bound `dustFloor` to a small absolute constant or a bps of NAV; and emit a distinct `StrategyWrittenOff(strategy, amount)` event when the residual is non-trivial so the loss is at least legible on-chain.

---

### [MEDIUM] M-07 — `harvestMaxImpactBps` is dead configuration: validated, stored, settable, and never read

- **Location:** declared [VaultStorage.sol:86](src/libraries/VaultStorage.sol#L86); validated [Vault.sol:83](src/Vault.sol#L83); set [Vault.sol:108](src/Vault.sol#L108), [AdminFacet.sol:144-148](src/facets/AdminFacet.sol#L144-L148)
- **Confidence:** Confirmed (grep across `src/` returns zero read sites).

There is no harvest-impact circuit breaker. `StrategyFacet.harvest` and `_harvestAll` accept any `realized` value with no bound on how much it may move NAV. Operators reading `vaultConfig`/`setHarvestMaxImpactBps` will reasonably believe a protection exists that does not. Combined with C-01 (unvalidated `realized`) this is the missing second line of defense.

**Fix.** Implement it, or delete the field and its setter. Implementation:

```solidity
uint256 navBefore = s.navCheckpoint;
... harvest ...
uint256 maxImpact = (navBefore * s.harvestMaxImpactBps) / BPS_DENOMINATOR;
require(realized <= maxImpact, "HARVEST_IMPACT_TOO_HIGH");
```

---

### [MEDIUM] M-08 — Performance fee is charged on unrealized marks and **anyone** can choose the moment of crystallization

- **Location:** [src/libraries/LibVaultFee.sol:48-80](src/libraries/LibVaultFee.sol#L48-L80), [src/facets/StrategyFacet.sol:43-46](src/facets/StrategyFacet.sol#L43-L46)
- **Confidence:** Confirmed.

`chargePerformanceFee` runs inside every `refreshNav()`, and `settle()` is permissionless and callable every block. The fee is computed from `pricePerShare()`, which is derived from `positionValue()` — a **mark**, not a realization.

Consequence: any address can time `settle()` to a local NAV peak (right after a large harvest, at a favorable oracle tick for `_pendingRewardsValue`, at the top of a reward-token price move) and permanently mint treasury shares against a gain that subsequently evaporates. The HWM ratchets to that peak and never comes back down, so holders eat a permanent dilution for profit that was never realized. The treasury has an obvious incentive to do this; so does anyone holding treasury-correlated exposure.

Related: the fee is minted as **dilution** while the HWM is set to the **pre-dilution** PPS ([LibVaultFee.sol:58](src/libraries/LibVaultFee.sol#L58) before [line 78](src/libraries/LibVaultFee.sol#L78)). Post-mint PPS is strictly below the new mark, so the next fee requires recovering the dilution gap first. That direction favors users, so it is not a loss — but it means the effective fee rate is below the configured one, which should be documented.

**Fix.** Gate crystallization: either restrict `settle()` to keepers, or decouple the fee from `refreshNav` and crystallize on a keeper-only, rate-limited cadence (e.g. at most once per `feePeriod`). A TWAP or time-weighted HWM would remove the timing edge entirely.

---

### [MEDIUM] M-09 — `setStrategyDisabled` does not wind down capital, and `rebalance` will not drain a disabled strategy

- **Location:** [src/libraries/LibStrategyRegistry.sol:153-158](src/libraries/LibStrategyRegistry.sol#L153-L158), [src/facets/StrategyFacet.sol:90-99](src/facets/StrategyFacet.sol#L90-L99)
- **Confidence:** Confirmed.

`strategyDisabled` is only consulted in `deployIdle` and in `rebalance`'s **pass 2** (deploy). Pass 1 (drain excess) pulls only when `current > target`, and a disabled strategy retains its non-zero `strategyWeightBps` — so its `target` is non-zero and its capital stays put indefinitely.

Governance intending "stop using this venue, it looks risky" must issue **two** actions: `setStrategyDisabled(S, true)` *and* `setTargets(...)` with `S`'s weight at 0. Under a timelock, the gap between believing the venue is disabled and its capital actually being withdrawn can be days. The flag's name and the header comment ("blocks new deploys only") disagree with operator expectation.

**Fix.** Have `setDisabled(strategy, true)` zero the weight and redistribute it to `idleTargetBps` (bounded by `MAX_IDLE_BPS`) or to the remaining strategies pro-rata, so a single action actually stops the exposure.

---

### [MEDIUM] M-10 — `Vault.setFacet` does not require the target to have code: a mistyped facet turns `deposit`/`withdraw` into silent no-ops

- **Location:** [src/Vault.sol:193-196](src/Vault.sol#L193-L196), [src/Vault.sol:208-220](src/Vault.sol#L208-L220)
- **Confidence:** Confirmed.

```solidity
function setFacet(bytes4 selector, address facet) external onlyGovernance {
    VaultStorage.vaultLayout().selectorToFacet[selector] = facet;   // no code check
}
```

`delegatecall` to an address with no code **succeeds** and returns empty data. The fallback's `require(facet != address(0))` only catches the zero address. Point `withdraw.selector` at an EOA and every `withdraw()` call returns successfully having done nothing — no revert, no event, user believes they withdrew. Point `deposit.selector` at an EOA and `deposit()` "succeeds" minting nothing.

**Fix.**

```solidity
require(facet == address(0) || facet.code.length > 0, "NOT_A_CONTRACT");
```

and keep `address(0)` as the explicit "remove selector" sentinel (the fallback already reverts on it).

---

### [MEDIUM] M-11 — `transferGovernance` is single-step

- **Location:** [src/facets/AdminFacet.sol:169-174](src/facets/AdminFacet.sol#L169-L174)
- **Confidence:** Confirmed.

A single transaction moves the sole authority over strategies, fees, caps, roles, ETH fee withdrawal, and `setFacet`. A wrong address — a non-timelock contract, a chain-specific address that does not exist on this chain, a typo — permanently and irrecoverably bricks all governance of the vault. `setTreasury` has the same shape but the blast radius is smaller.

**Fix.** Two-step: `pendingGovernance` + `acceptGovernance()` callable only by the pending address.

---

### [MEDIUM] M-12 — Pyth prices read via `getPriceUnsafe` with no confidence-interval check

- **Location:** [src/oracle/sources/PythSource.sol:10-19](src/oracle/sources/PythSource.sol#L10-L19)
- **Confidence:** Confirmed. *(Carried forward from v1 M-01; unchanged.)*

`IPyth.Price.conf` is never read. Pyth publishes `conf` precisely so consumers can reject prices during periods of publisher disagreement or thin liquidity — the moments an attacker cares about. `getPriceUnsafe` additionally skips Pyth's own staleness logic (the manual `publishTime` check partially compensates, but not the confidence dimension).

Because `positionValue()` includes oracle-priced `_pendingRewardsValue()`, a wide-confidence Pyth read feeds straight into NAV and PPS.

**Fix.**

```solidity
require(p.conf != 0 && (uint256(p.conf) * BPS) / uint256(uint64(p.price)) <= maxConfBps, "PRICE_UNCERTAIN");
```

with `maxConfBps` per-token configurable (50–200 bps typical).

---

### [MEDIUM] M-13 — Chainlink reads lack `minAnswer`/`maxAnswer` bounds, an L2 sequencer-uptime check, and a `decimals()` read

- **Location:** [src/oracle/sources/ChainlinkSource.sol:9-24](src/oracle/sources/ChainlinkSource.sol#L9-L24)
- **Confidence:** Confirmed. *(Carried forward from v1 M-02/M-03/L-01.)*

Three gaps, all standard:

1. **No circuit-breaker bounds.** Aggregators clamp at `minAnswer`/`maxAnswer`. During a crash beyond the floor the feed keeps reporting the floor as a *fresh, valid* answer. This is the Venus/BNB pattern.
2. **No sequencer-uptime feed.** On any L2 (and the docs discuss L2 block times at length, so an L2 deployment is clearly contemplated), all Chainlink feeds go stale together during a sequencer outage and resume with a burst. Without the `L2 Sequencer Uptime Feed` + grace period, the first post-restart block prices against pre-outage data.
3. **Assumes 8 decimals.** `getChainlinkPrice` returns `uint256(price)` verbatim and the interface comment says feeds "MUST already report 8-decimal USD prices". Nothing enforces it. Registering a non-8-decimal feed (most ETH-denominated pairs are 18) silently mis-prices by `10^10` — straight into `_valueInAsset` and therefore into NAV.

**Fix.** Add per-token `minPrice`/`maxPrice` bounds to `ChainlinkConfig` and require `price` strictly inside them; add the sequencer feed with a grace period on L2 deployments; read and assert `AggregatorV3Interface(feed).decimals() == 8` in `setChainlinkConfig`.

---

### [MEDIUM] M-14 — Read-only reentrancy: `navCheckpoint` and share supply are transiently inconsistent across external calls

- **Location:** [src/facets/WithdrawFacet.sol:120-128](src/facets/WithdrawFacet.sol#L120-L128), [src/facets/EmergencyFacet.sol:70-86](src/facets/EmergencyFacet.sol#L70-L86)
- **Confidence:** Confirmed (mechanism), Medium (impact depends on external integrators).

`nonReentrant` correctly blocks re-entering any *state-changing* facet function — the lock is in shared vault storage, so it is cross-facet. But `ViewFacet` is entirely unguarded, and its reads are the natural integration surface.

Two inconsistency windows:

- **`_drain`:** `divestFrom` makes external calls while `navCheckpoint` still reflects pre-divest value (the divest loss is not yet booked). `pricePerShare()` read during a strategy callback is **overstated**.
- **`emergencyWithdraw`:** shares are burned at [line 70](src/facets/EmergencyFacet.sol#L70), then `_tryFullExit` makes external calls at [lines 76-78](src/facets/EmergencyFacet.sol#L76-L78) while `navCheckpoint` is still pre-burn. Supply is down, NAV is not. `pricePerShare()` read in that window is **inflated**, by up to the full ratio of the exiting position.

Any lending market, AMM, or aggregator using this vault's share token as collateral and pricing it via `ViewFacet.pricePerShare()` can be manipulated in that window.

**Fix.** Add a `nonReentrantView` modifier (`require(s.reentrancyStatus != 2)`) to `pricePerShare`, `totalAssets`, `preview*`, `maxWithdraw`, `maxRedeem`, `availableLiquidity`, and `vaultConfig` — the standard Curve-style remediation.

---

### [MEDIUM] M-15 — Unlimited receipt-token approval to strategies, triggerable by an unprivileged caller

- **Location:** [src/libraries/LibStrategyRegistry.sol:75](src/libraries/LibStrategyRegistry.sol#L75), [src/libraries/LibStrategyRegistry.sol:92](src/libraries/LibStrategyRegistry.sol#L92), [src/facets/EmergencyFacet.sol:98](src/facets/EmergencyFacet.sol#L98)
- **Confidence:** Confirmed.

```solidity
if (receipt != address(0)) IERC20(receipt).forceApprove(strategy, type(uint256).max);
```

The approval is correctly reset to 0 afterward on every path (including `_tryFullExit`'s `catch`), so the window is one call deep. But it is `type(uint256).max` when the required amount is knowable and bounded, and — because `emergencyWithdraw` is permissionless (H-02) — **any address can open that window on every strategy, at any time, for free.** The vault's entire receipt-token holding is exposed for the duration.

Strategies are trusted by assumption here, so this is not a live exploit. It is an unnecessary blast radius: a single strategy upgrade bug converts into total loss of that venue's position rather than a bounded loss.

**Fix.** Approve the receipt amount actually required (or `balanceOf(vault)` for a full exit) instead of `max`, and combine with H-02's `whenPaused` gate so the window cannot be opened by anyone.

---

### [MEDIUM] M-16 — `rebalance` hard-reverts if any single strategy's harvest fails

- **Location:** [src/facets/StrategyFacet.sol:79-83](src/facets/StrategyFacet.sol#L79-L83), [src/facets/StrategyFacet.sol:131-144](src/facets/StrategyFacet.sol#L131-L144)
- **Confidence:** Confirmed.

`_harvestAll(s, true)` reverts the whole call on the first failing harvest. One venue with a paused reward distributor — a routine, non-buggy state — disables **all** rebalancing for the vault. Weights drift and cannot be corrected until governance removes or breaks the offending strategy (both timelocked). `deployIdle` still works, so this is degradation rather than a freeze, but it removes the only tool for correcting over-allocation.

**Fix.** Emit `HarvestFailed(strategy)` and continue, or accept failures for strategies already flagged `disabled`, or add a `rebalanceSkipping(address[] calldata skip)` keeper variant.

---

### [MEDIUM] M-17 — `fullExit` is unguarded in `removeStrategy`/`migrateStrategy`: a frozen venue makes a strategy permanently unremovable

- **Location:** [src/libraries/LibStrategyRegistry.sol:88-98](src/libraries/LibStrategyRegistry.sol#L88-L98), called at [line 180](src/libraries/LibStrategyRegistry.sol#L180) and [line 213](src/libraries/LibStrategyRegistry.sol#L213)
- **Confidence:** Confirmed.

`fullExit` calls `IStrategy(strategy).emergencyWithdraw()` with no `try/catch` (contrast `EmergencyFacet._tryFullExit`, which does guard it). A venue in a paused/frozen state makes both `removeStrategy` and `migrateStrategy` revert. The strategy is stuck in the registry, its stale `strategyLastValue` keeps counting in NAV (H-04), and governance has no path to evict it. Migration away from a compromised venue — exactly when you need it — is the case that fails.

**Fix.** Guard it, and allow removal with an explicit, event-emitting write-off when the exit cannot complete:

```solidity
uint256 freed;
try IStrategy(strategy).emergencyWithdraw() returns (uint256 f) {
    freed = f; s.idleBalance += f;
} catch { emit StrategyExitFailed(strategy); require(force, "EXIT_FAILED"); }
s.strategyLastValue[strategy] = 0;
```

---

## 6. Low

| ID | Finding | Location |
|---|---|---|
| **L-01** | **ETH sent via `receive()` is permanently locked.** `withdrawEthFees` is bounded by `collectedEthFees`, which only increases via `_collectEntryFee`. Any ETH arriving through `receive()` or a self-destruct is unrecoverable by anyone. | [Vault.sol:222](src/Vault.sol#L222), [AdminFacet.sol:126-134](src/facets/AdminFacet.sol#L126-L134) |
| **L-02** | **Exact `msg.value == entryFeeWei` reverts in-flight deposits on any fee change.** No refund of excess. Since timelock execution is open (`EXECUTOR_ROLE = address(0)`), anyone can time the `setEntryFee` execution to grief pending deposits. Accept `msg.value >= fee` and refund the remainder. | [DepositFacet.sol:90-96](src/facets/DepositFacet.sol#L90-L96) |
| **L-03** | **`migrateStrategy` silently reorders the withdrawal queue.** `_removeFromList` carefully preserves priority order ("a plain swap-with-last would silently reorder the withdrawal queue"), then `list.push(to)` appends the replacement at the **end** — so a migrated strategy drops to lowest drain priority. Insert at the original index. | [LibStrategyRegistry.sol:217-224](src/libraries/LibStrategyRegistry.sol#L217-L224) |
| **L-04** | **Per-block flow caps are keyed on `msg.sender`.** Trivially bypassed by splitting across EOAs within one block. Combined with H-02(b) (emergency path ignores the cap entirely), `withdrawCapPerBlock` provides close to no real bank-run protection. Track cumulative flow per block regardless of caller. | [LibVaultCap.sol:22-60](src/libraries/LibVaultCap.sol#L22-L60) |
| **L-05** | **Fee-on-transfer and rebasing base assets are unsupported, contrary to the comment.** `_pullAndCredit`'s comment describes handling FoT, but `require(received == assets, "TRANSFER_MISMATCH")` rejects it outright. A rebasing base asset breaks `idleBalance` entirely (only `sync()` catches positive rebases; negative rebases leave `idleBalance` above real custody, making transfers revert). Document the restriction and validate at construction where possible. | [DepositFacet.sol:104-116](src/facets/DepositFacet.sol#L104-L116) |
| **L-06** | **`_availableLiquidity` reverts wholesale if any strategy's `maxWithdraw()` reverts**, so `availableLiquidity`, `maxWithdraw`, and `maxRedeem` all break when one venue is down — exactly when a frontend most needs them. Wrap in `try/catch`. | [ViewFacet.sol:81-90](src/facets/ViewFacet.sol#L81-L90) |
| **L-07** | **`preview*` reads the stale `navCheckpoint`** while the corresponding state-changer calls `refreshNav()` first. Previews can differ from execution in either direction, so they are not safe to use for slippage bounds — which is what a preview is for. Either refresh in a `staticcall`-safe way or rename to `previewCached*`. | [ViewFacet.sol:45-59](src/facets/ViewFacet.sol#L45-L59) |
| **L-08** | **First-depositor donation griefing.** With `nav = 0, supply = 0`, an attacker donates `X` base and calls `sync()`; the first real depositor of `A` gets `A × 10^6 / (X+1)` shares, which rounds to 0 (revert `ZERO_SHARES`) whenever `X > A × 10^6`. The `DECIMALS_OFFSET = 6` defense makes this expensive (10^6× the victim's deposit) but not impossible for a tiny seeding deposit. Seed the vault with a burned first deposit at deployment. | [LibVaultMath.sol:38-42](src/libraries/LibVaultMath.sol#L38-L42) |
| **L-09** | **Fees deferred while `treasury == address(0)` are lost permanently.** `chargePerformanceFee` raises the HWM *before* the treasury check, so the skipped fee can never be recovered once the mark has ratcheted past it. The comment says "no profit is lost, only the fee is deferred" — the fee is in fact forfeited. Move the `treasury == address(0)` check above the HWM write. | [LibVaultFee.sol:58-66](src/libraries/LibVaultFee.sol#L58-L66) |
| **L-10** | **NAV is oracle-dependent through unclaimed rewards.** `positionValue() = _positionValue() + _pendingRewardsValue()`, and the latter is oracle-priced with a fixed 2% haircut. This puts oracle risk directly into deposit/withdraw pricing for a component that is not yet realized. Consider excluding pending rewards from redemption pricing, or making the haircut configurable per strategy. | [BaseStrategy.sol:148-150](src/strategies/BaseStrategy.sol#L148-L150) |
| **L-11** | **`UserRewardVault` has no `unregisterVault`**, `registeredVaults` grows monotonically, and `rescue()` linearly scans it via `_isRegisteredShareToken`. Not a live risk at current scale, but it is an unbounded loop in an admin path with no cap. | [UserRewardVault.sol:250-260](src/rewards/UserRewardVault.sol#L250-L260), [UserRewardVault.sol:377-383](src/rewards/UserRewardVault.sol#L377-L383) |
| **L-12** | **`baseDecimals` is stored but never used** outside `vaultConfig`. All share math is decimals-independent by design (`SHARE_DECIMALS = 18` fixed). Harmless, but it invites a future contributor to assume it participates in conversions. | [VaultStorage.sol:82](src/libraries/VaultStorage.sol#L82) |

---

## 7. Informational

- **I-01 — Not ERC-4626, despite 4626-shaped naming.** `deposit(uint256,address,uint256)` / `withdraw(uint256,address,address,uint256)` have different selectors from the standard, and `asset()`, `totalSupply()`, `convertToShares`, `convertToAssets`, `maxDeposit`, `maxMint` are absent from the vault surface. Integrators auto-detecting 4626 will silently fail. Either implement the full interface (with the slippage variants as extensions) or drop the 4626 vocabulary from the docs.
- **I-02 — `settle`, `harvest`, `harvestAll`, `sync`, and `emergencyWithdraw` all run while paused.** Only `deposit`/`mint`/`withdraw`/`redeem`/`deployIdle`/`rebalance` carry `whenNotPaused`. Performance fees therefore keep crystallizing during an emergency. Decide deliberately which of these should survive a pause and document it.
- **I-03 — The breaker conflates "read reverted" with "value moved sharply".** The revert path does *not* set `strategyBroken` while the jump path does; both fall back to `strategyLastValue`. These are different failure modes needing different responses (see H-05). Split into `strategyBroken` and `strategyStalled`.
- **I-04 — Zero tests.** `test/` and `script/` are empty. Every High and Medium above is a path no test exercises. The single highest-leverage remediation in this report is a Foundry suite; see §10.
- **I-05 — Stale documentation.** `README.md` (214 KB) and `docs/facets/*.md` describe the previous Diamond architecture (`DiamondCutFacet`, `VaultAdminFacet`, `VaultHarvestFacet`, `ReferralVault`) that no longer exists in `src/`. The v1 audit report's line references no longer resolve. Regenerate or delete.
- **I-06 — `BaseStrategy` emits requested rather than actual amounts.** `emit Invested(assets)` reports the approved amount, not the amount actually deployed after dust return. Off-chain accounting built on this event will drift from `strategyLastValue`.

---

## 8. Cross-role interaction analysis

You asked specifically about admin/keeper/user ordering hazards. This section enumerates them.

### 8.1 Governance action → user in flight

| Governance action | Effect on a pending user tx | Severity |
|---|---|---|
| `setEntryFee` | `require(msg.value == entryFeeWei)` is **exact** → every in-flight `deposit`/`mint` reverts. Timelock execution is open, so anyone can time this. | L-02 |
| `setCaps` (raises `minDeposit`) | In-flight deposits below the new floor revert. | Accepted |
| `setCaps` (lowers `withdrawCapPerBlock`) | In-flight withdrawals revert; users reroute to `emergencyWithdraw`, which ignores the cap and takes the lossy path. | H-02(b) |
| `setPerformanceFee` | Correctly crystallizes at the OLD rate first via `refreshNav()`. **No issue** — this ordering is right. | ✅ |
| `setTreasury` | Does not crystallize first, but the HWM ratchets on every refresh so pending fees were already minted. **No issue.** | ✅ |
| `removeStrategy` / `migrateStrategy` | NAV is understated for the rest of the block. A user depositing in that window over-mints; a user withdrawing under-receives. Attacker-extractable. | **H-01** |
| `setStrategyDisabled` | User-visible behaviour unchanged; capital does **not** leave the venue. Operators may believe otherwise. | M-09 |
| `setIdleTargetBps` | Silently breaks the 100% allocation invariant; subsequent `deployIdle` allocates by list order rather than by weight. | M-03 |
| `clearStrategyCircuitBreak` | Re-trips on the next `refreshNav()`, which any user deposit will trigger — so the clear appears to work and then reverts to broken within one block. | **H-07** |
| `setFacet` (wrong address) | `deposit`/`withdraw` become silent no-ops rather than reverting. | M-10 |

### 8.2 Keeper action → user in flight

| Keeper action | Interaction | Severity |
|---|---|---|
| `deployIdle` | Drains idle to `idleTargetBps`. A user withdrawing immediately after must divest, paying venue exit costs that are socialized. | M-02 |
| `deployIdle` / `rebalance` | Calls `refreshNav()` first, which may **trip the breaker mid-call**; the loop then skips the newly broken strategy. Correct, but the NAV used for targets is the pre-trip value. | Minor |
| `rebalance` | Hard-reverts on any harvest failure → the whole rebalance is unavailable. | M-16 |
| `harvest(arbitrary address)` | Mints `idleBalance` from a trusted return value with no registry check. | **C-01** |
| Any keeper op | All are `nonReentrant` against user ops via shared storage. **No cross-facet reentrancy.** | ✅ |

### 8.3 User action → protocol state

| User action | Interaction | Severity |
|---|---|---|
| `emergencyWithdraw` with dust shares | Forces a full, unbounded, slippage-free unwind of `strategies[0]` whenever idle is short. Repeatable every block. | **H-02** |
| `emergencyWithdraw` (any size) | Prices pre-unwind, pays in full, socializes the exit cost. Burns full shares on shortfall. | **H-03** |
| `settle()` | Permissionless NAV re-anchor → controls breaker cadence (H-06) and fee-crystallization timing (M-08). | **H-06**, M-08 |
| `sync()` | Permissionless. Only ever *increases* idle by already-received tokens, so it is safe in isolation — but it is the second half of the H-01 extraction. | H-01 |
| `withdraw`/`redeem` | Prices pre-divest; `navCheckpoint -= assets` under-books the realized loss. | M-02 |
| Donate base to a **strategy** | Corrupts `investInto`'s delta → DoS or forced breaker trip. | **M-01** |
| Donate base to the **vault** | Safe. Untracked until `sync()`, then credited to all holders. | ✅ |
| Donate **receipt tokens** to the vault | Raises `positionValue()`. If the jump exceeds `strategyMaxDeltaBps`, it trips the breaker on a healthy strategy → freeze + H-04. | H-06 |

### 8.4 Reentrancy posture

- **State-changing reentrancy: sound.** `VaultModifiers.nonReentrant` uses the shared `VaultStorage` slot, so the lock is genuinely cross-facet — a strategy callback cannot re-enter `deposit` from inside `withdraw`. Verified across all six facets.
- **Read-only reentrancy: exposed.** `ViewFacet` is entirely unguarded and has two windows where NAV and supply disagree. See M-14.

---

## 9. Invariants — status

| # | Invariant | Holds? | Broken by |
|---|---|---|---|
| 1 | `idleBalance == baseAsset.balanceOf(vault)` after every entry point | ❌ | **H-01** (harvest proceeds untracked) |
| 2 | `navCheckpoint == idleBalance + Σ positionValue()` after every entry point | ❌ | **H-01**, **M-02** (`navCheckpoint -= assets` under-books loss), H-04 (frozen values) |
| 3 | `Σ strategyWeightBps + idleTargetBps == BPS_DENOMINATOR` | ❌ | **M-03**, **M-04**, **M-05** |
| 4 | `strategyLastValue[s] ≈ s.positionValue()` for every healthy strategy | ❌ | **M-01** (stray base) |
| 5 | Rounding always favors the vault / existing holders | ✅ | Verified across all four `LibVaultMath` conversions |
| 6 | Shares burned are proportional to assets received | ❌ | **H-03** (full burn on partial payout) |
| 7 | A withdrawer bears the cost of their own exit | ❌ | **M-02**, **H-03** |
| 8 | The performance fee cannot reach back over pre-rate-change gains | ✅ | `setPerformanceFee` crystallizes at the old rate first |
| 9 | HWM ratchets monotonically and a dip-then-recover is not re-charged | ✅ | Verified |
| 10 | No cross-facet state reentrancy | ✅ | Shared-storage lock verified |
| 11 | Keeper cannot reach user principal | ❌ | **C-01** |
| 12 | Every strategy in `strategies[]` is removable | ❌ | **M-17** |
| 13 | Staked principal is always withdrawable | ❌ | **H-08** |

---

## 10. Status of the v1 (2026-07-19) report

| v1 ID | Status |
|---|---|
| H-01 — HWM seeded 10^6 too high, fee never crystallizes | ✅ **FIXED.** [Vault.sol:112](src/Vault.sol#L112) now seeds `PPS_SCALE / 10**DECIMALS_OFFSET`. Verified. |
| H-02 — Stale-NAV redemption race | ⚠️ **PARTIALLY FIXED.** `emergencyWithdraw` now calls `refreshNav()` first (v1 M-05 resolved), but the freeze-at-`lastValue` behaviour and `_drain`'s skip of broken strategies are unchanged. Re-filed as **H-04**. |
| M-01 — Pyth confidence | ❌ **OPEN.** Re-filed as **M-12**. |
| M-02 — Chainlink min/max bounds | ❌ **OPEN.** Re-filed as **M-13**. |
| M-03 — L2 sequencer feed | ❌ **OPEN.** Re-filed as **M-13**. |
| M-04 — Withdrawal-cooldown venues trap funds | ❌ **OPEN**, and now worse: `fullExit` is unguarded, so such a venue makes the strategy unremovable. Re-filed as **M-17**. |
| M-05 — `emergencyWithdraw` prices against a stale checkpoint | ✅ **FIXED.** `refreshNav()` added at [EmergencyFacet.sol:64](src/facets/EmergencyFacet.sol#L64). The *ordering* problem that remains is distinct and re-filed as **H-03**. |
| L-01 — Feed decimals assumed | ❌ **OPEN.** Folded into **M-13**. |
| L-02 — No `totalStaked` denominator | ➖ **BY DESIGN**, documented at length in `UserRewardSystem`. The real risk in that contract is the unbounded rate — **H-08**. |
| L-03 — ReferralVault dead integration | ✅ **RESOLVED** by removal; `ReferralVault` no longer exists in `src/`. |
| L-04 — Cross-vault commingled custody | ✅ **RESOLVED** by the one-vault-one-storage refactor. |
| L-05 — Untracked donations | ✅ **FIXED** for the base asset via `LibVaultNav.sync()`. Still open for **ETH** — re-filed as **L-01**. |
| I-01…I-04, G-01 | ❌ **OPEN.** I-01 (stale docs) is now worse — `README.md` and `docs/facets/**` describe an architecture that no longer exists. |

---

## 11. Remediation priority

**Before any deployment**

1. **C-01** — add the registry check and balance-delta measurement to `harvest(address)`. One-line class of fix, prevents total loss from a hot key.
2. **H-01** — credit the harvest return in `removeStrategy` / `migrateStrategy`.
3. **H-02** — add `whenPaused` to `emergencyWithdraw` and bound the unwind to the shortfall.
4. **H-08** — bound `setRewardRate`.
5. **M-10** — `require(facet.code.length > 0)` in `setFacet`.

**Before mainnet, with tests**

6. **H-03** — proportional burn + post-unwind repricing.
7. **H-05** — `try/catch` around `divestFrom` in `_drain`; flag the strategy on a reverting `positionValue()`.
8. **H-07** — re-anchor `strategyLastValue` when clearing the breaker.
9. **M-01** — measure this-call leftover in `BaseStrategy.invest`; make `investInto` saturating.
10. **M-03/M-04/M-05** — restore the weights invariant across all three mutation paths.
11. **M-14** — `nonReentrantView` on `ViewFacet`.
12. **M-12/M-13** — oracle hardening.

**Design decisions to settle before launch**

13. **H-04 / H-06** — the breaker's semantics. A rate limiter whose cadence is set by an unprivileged caller is not a security control. Decide whether a broken strategy's value counts toward redemption pricing, and pick a time-based anchor.
14. **M-08** — whether the performance fee may be crystallized against unrealized marks by an arbitrary caller.
15. **M-02 / H-03** — whether exit cost is borne by the exiter or socialized. Pick one and enforce it on **both** exit paths.

**Test suite (I-04) — minimum set**

- Invariant: `idleBalance == baseAsset.balanceOf(vault)` after every entry point. *(Catches H-01, M-01.)*
- Invariant: `navCheckpoint == idleBalance + Σ positionValue()` after every entry point. *(Catches H-01, M-02.)*
- Invariant: `Σ strategyWeightBps + idleTargetBps == 10_000`. *(Catches M-03, M-04, M-05.)*
- Invariant: PPS is non-decreasing across any single user's `deposit → withdraw` round trip absent real yield loss. *(Catches M-02, H-03.)*
- Fork test: strategy with a real venue exit fee → assert the withdrawer, not the vault, pays it.
- Fork test: paused venue → assert `withdraw` still succeeds for other strategies. *(H-05.)*
- Fuzz: `harvest(address)` with arbitrary addresses. *(C-01.)*
- Fuzz: donate `X` base to a strategy, then `deployIdle`. *(M-01.)*
- Scenario: dust-share `emergencyWithdraw` with `idleBalance == 0`. *(H-02.)*
- Scenario: trip the breaker, `clearStrategyCircuitBreak`, then any deposit. *(H-07.)*
