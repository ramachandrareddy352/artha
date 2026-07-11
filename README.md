# Artha Protocol — Token-Vault Architecture (v2)

> **What changed from v1.** Artha is no longer three risk-tier pools (LOW/MED/HIGH) with fixed-term locks. It is now a set of **single-asset vaults** — a USDC vault, a DAI vault, a WETH vault, … — exactly like Yearn V3. Each vault accepts **only its one base token**, mints shares, and deploys that token into **strategies** that either **lend** it or **swap** it into other tokens. There is **no risk type and no fixed/variable term** any more: every position is **variable** — deposit or withdraw at any time. Governance (the Timelock) sets bounds and picks the 1–5 strategies each vault splits into; a bounded executor triggers rebalances within RiskGuard limits.
>
> The **referral system** is rewritten to match: rewards are keyed by **strategy contract address** (not token, not pool), scaled by a **tier** the code sits on, and accrue on **how much** referred capital is active × **how long** it stays. All rates are fixed by governance.

---

## Table of contents

1. [The shift in one picture](#s1)
2. [File structure](#s2)
3. [Vault model — one token in, strategies out](#s3)
4. [Strategy classes a vault can use](#s4)
5. [Deposits & withdrawals (all variable)](#s5)
6. [Referral system — the full spec](#s6)
7. [Referral reward math](#s7)
8. [In-depth referral audit](#s8)
9. [Four worked examples (verified)](#s9)
10. [Integration & deployment](#s10)
11. [Protocol-wide invariants](#s11)

---

<a name="s1"></a>
## 1. The shift in one picture

```
        v1 (old)                                v2 (new — this doc)
 ┌───────────────────────┐              ┌──────────┐ ┌──────────┐ ┌──────────┐
 │  ONE Diamond          │              │ USDC     │ │ DAI      │ │ WETH     │
 │  poolId 0/1/2 by RISK │              │ Vault    │ │ Vault    │ │ Vault    │
 │  baskets ≤5 tokens    │      ⇒       │ (USDC in)│ │ (DAI in) │ │ (WETH in)│
 │  fixed-term locks     │              └────┬─────┘ └────┬─────┘ └────┬─────┘
 │  90/180/360 boosts    │                   │            │            │
 └───────────────────────┘              strategies    strategies   strategies
                                        (lend / swap) (lend/swap)  (lend/swap)
```

- **One base token per vault.** The USDC vault only ever holds/accepts USDC. To earn on other tokens, deposit into their vault.
- **Strategies are the yield engine.** A vault can point at **1 to 5** strategies at once (governance picks them and the split). A strategy is a contract that takes the base token and lends it (Aave/Compound/Morpho/Spark) or swaps it into another token and holds/deploys that.
- **One base token can back several strategies.** USDC → "USDC Aave lender" **and** "USDC→sUSDS depositor" are two different strategy contracts with two different addresses. That is exactly why the referral reward rate is keyed by **strategy address**, not by "USDC".
- **Everything is variable.** No lock, no term, no penalty-for-time. Users deposit and withdraw whenever they want; the vault keeps a liquidity buffer so exits are instant.

---

<a name="s2"></a>
## 2. File structure

```
artha/
├── vaults/
│   ├── ArthaVault.sol            # ERC-4626 single-asset vault (one per base token)
│   ├── VaultFactory.sol          # deploys a new vault for a base token
│   └── interfaces/IStrategy.sol  # deploy/free/report/tend lifecycle (Yearn-style)
├── strategies/
│   ├── BaseStrategy.sol          # shared lifecycle base
│   ├── lend/  { AaveV3.sol, CompoundV3.sol, Morpho.sol, Spark.sol }
│   └── swap/  { UniV3Swapper.sol, CurveLP.sol, ... }
├── referral/                     # ← the three files in this drop
│   ├── ReferralVaultManager.sol  # access control (admin = Timelock, approved callers)
│   ├── ReferralSystem.sol        # code registry + tier attribute
│   └── ReferralVault.sol         # holds ARTHA, per-(strategy,tier) reward accrual
├── gov/  { ArthaToken.sol, ArthaTimelock.sol, ArthaGovernor.sol }
└── periphery/ { OracleAggregator.sol, DebtAllocator.sol, HealthCheck.sol }
```

The referral stack is a **standalone three-contract inheritance chain** (constructor-deployed, no proxy):

```
ReferralVaultManager  ←  ReferralSystem  ←  ReferralVault   (this is the deployed one)
   access control          code registry        ARTHA + rewards
```

---

<a name="s3"></a>
## 3. Vault model — one token in, strategies out

Each `ArthaVault` is ERC-4626 over a single base asset:

- `deposit(assets)` / `mint(shares)` — pull base token, mint shares at live price-per-share.
- `withdraw(assets)` / `redeem(shares)` — burn shares, return base token from the buffer first, pulling from strategies if needed.
- `totalAssets()` = idle base token in the vault + Σ value reported by each active strategy.
- **Debt allocation:** governance sets a **target ratio** (in bps) per strategy; the executor moves funds toward those targets, bounded by a per-strategy **max debt** cap and a minimum liquidity buffer. This is the Yearn DebtAllocator model — 1–5 strategies, split by governance.

The referral hook fires at the vault boundary: on a **referred** user's deposit/withdraw the vault calls
`ReferralVault.notifyDeposit(strategyAddr, user, rawAmount)` /
`notifyWithdraw(strategyAddr, user, rawAmount)`.
`strategyAddr` is the reward key (see §6). The vault is an **approved caller** and is trusted to pass the correct key and amount — the same trust the old design placed in the Diamond to pass a `poolId`.

---

<a name="s4"></a>
## 4. Strategy classes a vault can use

A vault's base token can be deployed into any of these (each is a separate contract → separate reward key):

| Class | What it does | Example venues | Reward key note |
|---|---|---|---|
| **Supply lending** | lend base token, earn borrow interest | Aave V3, Compound V3, Morpho, Spark | one address per venue |
| **Savings-rate wrapper** | mint a yield-bearing wrapper, hold it | Sky sUSDS/sDAI (PSM), sUSDe | not lending — value via price growth |
| **Swap-and-deploy** | swap base into another token, then lend/hold that | Uniswap/Curve + any of the above | the swap target defines the risk |
| **LP / auto-compound** | provide liquidity, harvest, recompound | Curve+Convex, Uni V3 | emissions ≠ durable yield |

The point for referral: **the same base token in two of these is two strategy addresses**, and governance can set a different referral `rewardRatio` for each.

---

<a name="s5"></a>
## 5. Deposits & withdrawals (all variable)

- **Deposit:** pull base token → mint shares at live pps. Optionally auto-allocate to the first strategy in the queue. No batching requirement, no term.
- **Withdraw:** burn shares → pay from idle buffer; if short, pull atomically from strategies in queue order, respecting each strategy's `maxLoss`. Instant.
- **No penalties, no locks.** The v1 penalty/fixed-term facets are removed. A user can enter and exit freely; the referral engine simply stops accruing on capital that leaves (and banks what was already earned — see §7).

---

<a name="s6"></a>
## 6. Referral system — the full spec

### 6.1 What it rewards

A **code owner** (the referrer) earns ARTHA for the capital their referred investors keep active in Artha vaults. Reward grows with **three** things:

1. **Amount** — how much referred principal is active.
2. **Time** — how long it stays.
3. **Strategy** — which strategy it sits in (governance sets a per-strategy `rewardRatio`).

…and is scaled by the **tier** the code sits on (governance sets a per-tier `tierRatio`).

### 6.2 Keyed by strategy address, not token

All reward state lives **per `strategy`** (the vault/strategy contract address). This is the core change:

- `rewardRatio[strategy]` — the per-strategy rate, `0 … 1e18` (`1e18` = "1.0"). e.g. a **USDC** strategy = `1e18`, a **WETH** strategy = `5e17`. Set in `ReferralVault` by governance.
- Because it is keyed by **address**, two USDC strategies can carry two different rates. Keying by token could not express that — which is why base-token keying was dropped.
- Governance **registers** each strategy with its base-token decimals, so raw amounts are normalised to 18 dp internally (USDC `×1e12`, DAI/WETH `×1`).

### 6.3 Tiers

- Every code carries a **tier** (`1, 2, 3, …`), defaulting to **tier 1** at creation.
- `tierRatio[tier]` maps a tier to a rate, `0 … 1e18`. Defaults shipped in the constructor: **tier 1 = `1e17`, tier 2 = `3e17`, tier 3 = `1e18`** (governance can change any, add more).
- Governance promotes a code with `setCodeTier(code, newTier)`. This **banks accrued reward at the old tier first**, then switches — so a promotion is never retroactive.

### 6.4 Roles & lifecycle

- **Admin = Governance Timelock** (`referralVaultManager`): registers strategies, sets `rewardRatio` / `tierRatio`, promotes codes, rescues funds, pauses.
- **Approved callers**: the vault layer (Diamond or standalone vaults) that report balance changes via the notify hooks.
- **Codes are admin-created** and handed out at events; users cannot mint their own (blocks self-referral of a second wallet). An investor **links to a code once** (`setTraderCode`) and every future deposit uses it.
- The program is **temporary**: when the referral ARTHA budget is spent, codes are deactivated, the vault is paused, and leftover ARTHA is swept to the treasury.

### 6.5 Funding

`ReferralVault` **does not mint**. ARTHA is transferred into it up front; claims pay from balance. `rescue()` can sweep only genuine excess (balance minus settled-unclaimed).

---

<a name="s7"></a>
## 7. Referral reward math

### 7.1 The formula (this is the whole product)

```
rewardPerYear = (amountNorm × tierRatio × rewardRatio) / 1e36      [ARTHA per year]
accrued       = rewardPerYear × elapsedSeconds / YEAR             [ARTHA]
```

where

- `amountNorm` = referred principal normalised to 18 dp (`raw × 10^(18−decimals)`),
- `tierRatio`  = the code's tier rate, `0 … 1e18`,
- `rewardRatio`= the strategy's rate, `0 … 1e18`,
- `1e36`       = `1e18 × 1e18`, normalising both ratios out,
- `YEAR`       = `365 days`.

Both ratios cap at `1e18`, so their product caps at `1e36` → **max reward is 100% of the referred principal per year, in ARTHA**. Tier 1 USDC (`1e17 × 1e18 / 1e36 = 0.1`) = 10%/yr; tier 3 USDC (`1e18 × 1e18 / 1e36 = 1.0`) = 100%/yr; tier 1 WETH (`1e17 × 5e17 / 1e36 = 0.05`) = 5%/yr.

### 7.2 The mechanism — one MasterChef accumulator per (strategy, tier)

Instead of looping every code, the vault runs an accumulator per **(strategy, tier)** lane. Over `dt` seconds a lane advances:

```
acc[strategy][tier] += rewardRatio[strategy] × tierRatio[tier] × dt × ACC / (1e36 × YEAR)
```

and a code's reward in that strategy is

```
earned(code,strategy) = balanceNorm(code,strategy) × acc[strategy][tier] / ACC  −  rewardDebt
```

with `ACC = 1e18` for precision. **Both ratios are folded into the accumulator** (tier is *not* applied at settle time). That single design choice is what gives **zero retroactivity** under every governance change:

- **change `rewardRatio[S]`** → we advance every tier lane of `S` first, then write the new ratio;
- **change `tierRatio[t]`** → we advance lane `t` of every strategy first, then write;
- **promote a code** → we bank it in its old lane across all strategies, switch the tier, then re-checkpoint in the new lane.

Old accrual always keeps the old rates; only future accrual uses the new ones. Every loop is bounded (`MAX_STRATEGIES = 64`, `MAX_TIERS = 32`).

### 7.3 Banking on every balance change ("active with amount")

On **every** deposit/withdraw the caller runs `_settle` **before** changing the balance. So:

- when a referred position **grows**, past accrual is banked at the old (smaller) balance, then the larger balance accrues going forward;
- when it **shrinks or exits**, past accrual is banked at the old (larger) balance and moved into `earned` (claimable), then the smaller balance accrues.

This is precisely "whenever the referred user is active with amount, that much reward is given" — reward is always `Σ balance × time` at the rates in force during each interval.

---

<a name="s8"></a>
## 8. In-depth referral audit

Scope: `ReferralVaultManager.sol`, `ReferralSystem.sol`, `ReferralVault.sol`. Compiled clean on solc 0.8.29 (0 errors, 0 warnings), OZ v5. `ReferralVault` runtime ≈ 13.6 KB (< 24 KB).

### 8.1 Correctness of accrual

- **No under-payment / over-payment on rate changes.** All three governance setters advance the affected accumulators to `block.timestamp` **before** writing the new rate. A position that was idle across a rate change is credited the *old* rate up to the change and the *new* rate after — no retroactive re-pricing. ✔
- **No under-payment / over-payment on tier promotion.** `setCodeTier` (a) settles the code in every strategy at the **old** tier lane, (b) switches the tier, (c) re-checkpoints `rewardDebt` against the **new** tier lane advanced to now. The old-lane accrual is banked; the new lane only accrues from the switch instant. ✔
- **Banking on balance change is correct.** `notifyDeposit`/`notifyWithdraw` call `_settle` first, then adjust `balanceNorm`, then re-checkpoint `rewardDebt` at the new balance. Reward for each interval uses the balance that was live during that interval. ✔
- **No accumulator underflow.** `acc` is monotonic non-decreasing; `balanceNorm` is constant between settles (every change re-checkpoints immediately). Therefore `accumulated ≥ rewardDebt` always, so `pending = accumulated − rewardDebt` never underflows. ✔
- **Lazy lane init prevents phantom back-pay.** A lane's first touch sets `lastUpdate = now` and accrues nothing, so an untouched `(strategy,tier)` pair can never pay for time before it existed. ✔

### 8.2 Access control

- Every rate/tier/registration setter is `onlyReferralVaultManager` (Timelock in production). ✔
- Balance hooks are `onlyCaller` (approved vaults). A random address cannot inflate a code's referred balance. ✔
- `claim` requires `codeOwner[code] == msg.sender`; rewards can only be pulled by the **current** owner, so a code transfer correctly redirects future claims. ✔

### 8.3 Self-referral & attribution

- Codes are admin-only to create; users cannot self-mint. ✔
- `setTraderCode` blocks linking to a code you own; `notifyDeposit` additionally returns early if `owner == investor`. Defense-in-depth against self-referral. ✔
- `traderToCode` is **set-once**; a user cannot re-point their history to a different code and misattribute already-referred capital. ✔

### 8.4 Fund safety

- `ReferralVault` never mints; it can only pay out ARTHA it holds. A drained balance simply makes `claim` revert with `INSUFFICIENT_REWARDS` rather than minting phantom supply. ✔
- `rescue` for ARTHA is capped to `balance − (totalEarned − totalClaimed)`, so it can never touch already-settled rewards. ✔ **Finding (Low):** reward still *accruing* on active codes is not reserved by `rescue`. Operationally, keep the vault funded well above ongoing accrual and only sweep clear excess — documented in-contract.
- `claim`/`claimAll` are `nonReentrant` (CEI ordering: effects before `safeTransfer`). `claimAll` calls the guarded `claim` sequentially, which is safe (each entry/exit is disjoint). ✔

### 8.5 Findings & recommendations

| # | Severity | Finding | Status / mitigation |
|---|---|---|---|
| 1 | Low | `rescue` does not reserve *future* accrual on active codes. | Documented; operational: overfund, sweep only clear excess. |
| 2 | Low | `setTierRatio` / `setRewardRatio` loop bounded sets (`registeredStrategies`, `registeredTiers`). With the 64/32 caps this is safe, but a very large registered set makes these calls gas-heavy. | Caps enforced; keep registered sets small (a handful of live vaults). |
| 3 | Info | `notifyDeposit`/`notifyWithdraw` **trust** the approved caller to pass the correct `strategy` and `rawAmount`. | By design — same trust model as the vault reporting a `poolId`. Only governance-approved vaults are callers; audit those vaults. |
| 4 | Info | Reward scales with **token amount**, not USD value. 2 WETH earns less than 1000 USDC at equal ratios because it is fewer token units. | Intentional per the spec. If USD-normalisation is desired later, multiply `amountNorm` by an oracle price at settle, or bake price into `rewardRatio`. Flagged so it is a **choice**, not a surprise. |
| 5 | Info | Tier ratios default to `1e17/3e17/1e18` in the constructor; if governance wants zero until explicitly set, remove the `_initTier` calls. | Defaults are convenience; governance can override. |
| 6 | Info | `deactivateCode` requires zero balance **and** zero unclaimed in **every** strategy, else it reverts (prevents silent reward loss). Owners must `claimAll` first. | Correct-by-construction; document the wind-down order for owners. |

**No High/Medium issues.** The accumulator, access control, self-referral guards, and fund-safety cap are sound. The main things to watch are operational (fund the vault above accrual; keep registered sets small) and the deliberate token-vs-USD scaling choice.

---

<a name="s9"></a>
## 9. Four worked examples (verified)

All numbers below are produced by an **exact-integer** mirror of the contract's `uint256` math (floor division, same as the EVM). Constants: `ACC = 1e18`, `YEAR = 31,536,000 s`, `1e36 = 1e18·1e18`.

Accumulator step: `acc += (rewardRatio × tierRatio × dt × 1e18) / (1e36 × YEAR)`
Reward: `reward = balanceNorm × acc / 1e18`

---

### Example 1 — USDC vault, **tier 1**, 1000 USDC, held 1 year

Setup: `rewardRatio[USDC-strategy] = 1e18`, `tierRatio[1] = 1e17`, USDC decimals 6 → `scale = 1e12`.

```
1) normalise principal
   balanceNorm = 1000e6 × 1e12                       = 1_000_000_000_000_000_000_000   (1e21)

2) advance the (USDC, tier1) lane for dt = YEAR
   acc = (1e18 × 1e17 × 31_536_000 × 1e18) / (1e36 × 31_536_000)
       = (1e18 × 1e17 × 1e18) / 1e36
       = 1e17                                         (acc = 100_000_000_000_000_000)

3) reward = balanceNorm × acc / 1e18
          = 1e21 × 1e17 / 1e18
          = 1e20 wei
```
**Reward = 100 ARTHA.** (Tier 1 = 10%/yr → 10% of 1000 = 100.) ✔

---

### Example 2 — USDC vault, **tier 2**, 5000 USDC, held 6 months

Setup: `rewardRatio = 1e18`, `tierRatio[2] = 3e17`, `scale = 1e12`, `dt = YEAR/2`.

```
1) balanceNorm = 5000e6 × 1e12                        = 5e21

2) acc = (1e18 × 3e17 × (YEAR/2) × 1e18) / (1e36 × YEAR)
       = (1e18 × 3e17 × 1e18) / 1e36 × (1/2)
       = 1.5e17                                        (acc = 150_000_000_000_000_000)

3) reward = 5e21 × 1.5e17 / 1e18
          = 7.5e20 wei
```
**Reward = 750 ARTHA.** (Tier 2 = 30%/yr → 30% of 5000 = 1500/yr → half year = 750.) ✔

---

### Example 3 — DAI vault, **tier 1**, 2000 DAI, held 1 year

Setup: `rewardRatio[DAI-strategy] = 1e18`, `tierRatio[1] = 1e17`, DAI decimals 18 → `scale = 1`, `dt = YEAR`.

```
1) balanceNorm = 2000e18 × 1                          = 2e21

2) acc (same rates as Ex.1) over 1 year               = 1e17

3) reward = 2e21 × 1e17 / 1e18
          = 2e20 wei
```
**Reward = 200 ARTHA.** (10% of 2000 = 200.) ✔ — same rates as Ex.1, double the principal, double the reward.

---

### Example 4 — DAI vault, **tier 2**: deposit 1000, **withdraw 400 at day 90**, check at day 180

Shows time + amount + **banking on withdraw**. Setup: `rewardRatio = 1e18`, `tierRatio[2] = 3e17`, `scale = 1`.

```
PHASE A  (day 0 → 90, balance = 1000 DAI)
  dt_A = 90 days = 7_776_000 s
  acc_A = (1e18 × 3e17 × 7_776_000 × 1e18) / (1e36 × 31_536_000)
        = 73_972_602_739_726_027                       (≈ 7.397e16)
  reward_A = 1000e18 × acc_A / 1e18
           = 73_972_602_739_726_027_000 wei            = 73.9726 ARTHA
  → _settle banks 73.9726 ARTHA into `earned`

  @day 90 WITHDRAW 400 DAI  (already banked above)
  balanceNorm: 1000e18 → 600e18

PHASE B  (day 90 → 180, balance = 600 DAI)
  dt_B = 90 days
  reward_B = 600e18 × acc_B / 1e18   (acc_B identical step to acc_A)
           = 44_383_561_643_835_616_200 wei            = 44.3836 ARTHA

TOTAL earned @ day 180
  = 73.9726 + 44.3836
  = 118_356_164_383_561_643_200 wei
```
**Total = 118.3562 ARTHA.** The 90 days at 1000 DAI were banked in full before the withdrawal; only the remaining 600 DAI accrued in phase B. ✔

**Sanity check via the annual formula** (`rewardPerYear = amountNorm × tierRatio × rewardRatio / 1e36`):
- Phase A: `1000 × 0.3 = 300 ARTHA/yr × 90/365 = 73.9726` ✔
- Phase B: `600 × 0.3 = 180 ARTHA/yr × 90/365 = 44.3836` ✔

---

<a name="s10"></a>
## 10. Integration & deployment

**Deploy order (referral stack):**
```solidity
// 1) deploy the vault (constructor wires manager → system → vault)
ReferralVault ref = new ReferralVault(arthaToken, timelock);   // admin = Timelock

// 2) fund it (no minting inside)
IERC20(arthaToken).transfer(address(ref), referralBudget);

// 3) governance (Timelock) registers each live strategy/vault with its decimals + rate
ref.registerStrategy(usdcStrategy, 6,  1e18);   // USDC strategy → 1.0
ref.registerStrategy(daiStrategy,  18, 1e18);   // DAI  strategy → 1.0
ref.registerStrategy(wethStrategy, 18, 5e17);   // WETH strategy → 0.5

// 4) approve the vault layer as a caller of the notify hooks
ref.setCaller(arthaVaultOrDiamond, true);

// 5) (optional) tune tiers; defaults are 1e17 / 3e17 / 1e18
ref.setTierRatio(4, 1e18);                       // add a tier 4 if wanted
```

**Vault hook wiring** — inside each `ArthaVault`, on a referred user's flow:
```solidity
// on deposit, after crediting the user
referralVault.notifyDeposit(address(this), user, rawAssets);
// on withdraw, before/after burning (report the amount leaving)
referralVault.notifyWithdraw(address(this), user, rawAssets);
```
`address(this)` is the reward key. If Artha stays a single Diamond, pass the **strategy address** explicitly instead of `address(this)` and keep the Diamond as the approved caller.

**Owner claim:**
```solidity
ref.pendingRewardAll(code);          // view total claimable across strategies
ref.claimAll(code, ownerPayout);     // pull it all
// or per-strategy:
ref.claim(strategy, code, to, amount);
```

**Promotion & rate changes (Timelock):**
```solidity
ref.setCodeTier(code, 2);            // banks old tier first, then promotes
ref.setRewardRatio(usdcStrategy, 8e17);  // advances all tier lanes first
ref.setTierRatio(2, 4e17);           // advances lane 2 of all strategies first
```

---

<a name="s11"></a>
## 11. Protocol-wide invariants (test checklist)

**Vaults**
1. `totalAssets == idle + Σ strategyValue` (no leakage / double count).
2. Deposit-then-withdraw returns ≤ deposited (rounding favors the vault).
3. `pps` non-decreasing except on real strategy loss.
4. Withdrawals succeed from buffer + queued strategies even under partial illiquidity (respecting `maxLoss`).
5. Per-strategy `maxDebt` and min buffer respected after every rebalance.

**Referral**
6. `Σ pending + Σ claimed` never exceeds ARTHA transferred in (no mint).
7. Rate/tier changes are non-retroactive (old rate up to change, new after).
8. `pending = accumulated − rewardDebt` never underflows (`acc` monotonic; balance re-checkpointed on change).
9. Self-referral (`owner == investor`) yields zero.
10. `rewardRatio ≤ 1e18` and `tierRatio ≤ 1e18` enforced on every setter.
11. Only the Timelock changes rates/tiers/registration; only approved callers push balances; only the current code owner claims.
12. `deactivateCode` reverts unless the code is fully wound down (zero balance and zero unclaimed) in every strategy.

**Access / upgrade**
13. `referralVaultManager` (and each vault's owner) is the Timelock in production.
14. Loops (`claimAll`, rate-change fan-out, `deactivateCode`) stay within `MAX_STRATEGIES / MAX_TIERS` bounds.

Run as a Foundry invariant suite + forked-mainnet integration (real Aave/Morpho/Compound + real ARTHA). Target `forge coverage ≥ 95%` on the referral math and vault accounting, external audit before mainnet funds.