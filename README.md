# Artha Protocol — Diamond (EIP-2535) Architecture Plan

> Complete rewrite as an **upgradeable Diamond** with the **AppStorage** pattern (same family as your perpetuals project). Every domain — the 3 pools, referral, penalty, fees, staking, strategies, rewards — is an independently upgradeable **facet** sharing one storage struct. AI proposes, governance sets bounds, a **bounded admin executor** triggers daily processing within RiskGuard limits, the Diamond custodies.

Organized like your Compound/Uniswap deep-dives: each module is **Concept → Math/derivation → AppStorage fields → Facet functions → Worked example → Invariants/checks**.

---

## Table of Contents

0. [Why a Diamond, the trust model & file structure](#m0)
1. [AppStorage — the shared storage layout](#m1)
2. [Diamond infrastructure & upgrade safety](#m2)
3. [Pool logic facet — shares, ERC-4626 math, inflation defense](#m3)
4. [NAV facet — pricing a multi-asset pool](#m4)
5. [Deposits (end-of-day batch) & withdrawals (instant)](#m5)
6. [Allocation & RiskGuard facets](#m6)
7. [Strategy facets — lending, the Diamond holds positions](#m7)
8. [Swap facet & slippage](#m8)
9. [Reward facet — `accArthaPerShare` engine](#m9)
10. [Emission facet — 16-year annual halving](#m10)
11. [Fee facet — management + performance with high-water mark](#m11)
12. [Penalty facet — early exit & split](#m12)
13. [Fixed-term facet (90/180/360)](#m13)
14. [Referral facet — tiers + discount share (from your contract)](#m14)
15. [Staking facet — ARTHA → monthly USDC from last month's fees](#m15)
16. [Governance, timelock, ownership & the bounded executor](#m16)
17. [Oracle & circuit breaker](#m17)
18. [Protocol-wide invariants](#m18)
19. [Default parameters & token distribution](#m19)
20. [Build order](#m20)

> **Base asset:** plan assumes **USDC** for deposits, fee collection, and staking rewards (one currency avoids a conversion leg on every flow). If you require USDT deposits, add an entry-zap (USDT→USDC) at the deposit boundary and keep all internal accounting in USDC.

---

<a name="m0"></a>
## Module 0 — Why a Diamond, Trust Model & File Structure

### Why EIP-2535 here

You want every logic block independently upgradeable (referral, penalty, fees, staking, the 3 pools, strategies). A Diamond gives you:

- **One address, many facets.** The Diamond's `fallback` `delegatecall`s into the facet that owns the called selector, so all facets execute against the **Diamond's** storage and the Diamond holds all funds.
- **Surgical upgrades** via `diamondCut` (Add / Replace / Remove selectors) — replace just the `FeeFacet` without touching the rest.
- **No 24KB size limit** problem — logic is split across facets.

The cost is that **upgradeability is the biggest trust vector**: whoever can call `diamondCut` can replace any logic and drain the protocol. Therefore `diamondCut` MUST sit behind **Timelock + multisig** with a delay (Module 16). This is non-negotiable.

### Trust model — the one rule

```
AI proposes  →  Governance sets BOUNDS (whitelist, weights, caps) via Timelock
            →  Admin executor TRIGGERS daily batch / rebalance (bounded by RiskGuard)
            →  Diamond custodies; no address moves funds outside RiskGuard caps
```

The "admin" that "starts the investment" is an `EXECUTOR_ROLE` **multisig**. It controls *when* the end-of-day batch runs (which defeats batch front-running and the inflation attack) but every effect is bounded on-chain. It cannot change a single bound — that path is Governance→Timelock only.

### Single-Diamond, `poolId`-keyed design

One contract address cannot expose three independent ERC-20 share tokens, and shared state (referral/fees/staking) wants one home. So:

- **One protocol Diamond.** Pools are `poolId ∈ {0=LOW, 1=MEDIUM, 2=HIGH}`.
- **Internal share accounting** in AppStorage: `shares[poolId][user]`, `totalShares[poolId]`.
- Optional **satellite ERC-20** per pool (mint/burn gated to the Diamond) if you later want transferable, composable shares.

### File structure

```
artha-diamond/
├── src/
│   ├── Diamond.sol                      # the proxy (fallback → delegatecall facet)
│   ├── upgrade/
│   │   ├── DiamondCutFacet.sol          # add/replace/remove selectors (TIMELOCKED)
│   │   ├── DiamondLoupeFacet.sol        # introspection (facets, selectors)
│   │   └── OwnershipFacet.sol           # owner == Timelock
│   ├── libraries/
│   │   ├── LibDiamond.sol               # diamond storage (facet→selector map) [EIP-2535 slot]
│   │   ├── LibAppStorage.sol            # AppStorage struct + accessor (slot 0)
│   │   ├── LibShares.sol                # share math (mint/redeem, virtual offset)
│   │   ├── LibReward.sol                # accArthaPerShare helpers
│   │   ├── LibNav.sol                   # totalAssets composition
│   │   └── LibAccess.sol                # role checks (reads AppStorage roles)
│   ├── facets/
│   │   ├── PoolFacet.sol                # 3 pools: deposit-request, withdraw, share views
│   │   ├── BatchFacet.sol               # end-of-day deposit settlement (executor-triggered)
│   │   ├── NavFacet.sol                 # totalAssets / pricePerShare per pool
│   │   ├── AllocationFacet.sol          # rebalance within RiskGuard bounds
│   │   ├── RiskGuardFacet.sol           # caps, buffer floor, slippage, drift (config + validate)
│   │   ├── StrategyFacet.sol            # route to Aave/Compound/Morpho; Diamond holds receipts
│   │   ├── SwapFacet.sol                # aggregator adapter + oracle slippage floor
│   │   ├── RewardFacet.sol              # ARTHA reward index per pool
│   │   ├── EmissionFacet.sol            # 16-year halving schedule
│   │   ├── FeeFacet.sol                 # mgmt + perf fee, high-water mark
│   │   ├── PenaltyFacet.sol             # early-exit penalty + 10/20/70 split
│   │   ├── FixedTermFacet.sol           # 90/180/360 lock boosts
│   │   ├── ReferralFacet.sol            # tiers + discountShare (your uploaded design)
│   │   ├── StakingFacet.sol             # stake ARTHA → monthly USDC from fees
│   │   ├── CircuitBreakerFacet.sol      # pause + graduated de-risk
│   │   └── AdminFacet.sol               # governance setters (TIMELOCKED) + executor triggers
│   └── external/                        # NOT facets — standalone contracts
│       ├── ArthaToken.sol               # ERC20, hard cap 1B (Diamond is minter)
│       ├── ArthaGovernor.sol            # OZ Governor (votes on ARTHA/veARTHA)
│       ├── ArthaTimelock.sol            # owns the Diamond; delays diamondCut + config
│       └── OracleAggregator.sol         # Chainlink + Pyth, staleness/divergence (read-only)
├── test/ { unit/  integration(forked-L2)/  invariant/ }
├── script/ { DeployDiamond.s.sol  CutFacets.s.sol  Configure.s.sol }
└── foundry.toml
```

**Singletons stay external** (ArthaToken, Governor, Timelock, Oracle) because they either need their own identity/supply (token) or are read-only (oracle) or must *own* the Diamond (timelock). Everything else is an upgradeable facet.

---

<a name="m1"></a>
## Module 1 — AppStorage: The Shared Storage Layout

### Concept

In the AppStorage pattern, **every facet declares the same `AppStorage` struct as its first state variable**, so it occupies storage starting at slot 0. All facets read/write the *same* layout via `LibAppStorage.diamondStorage()`. Per-pool data is held in mappings keyed by `poolId` (Solidity forbids mappings inside structs that live in arrays/memory, so we flatten per-pool fields into top-level mappings).

### The struct

```solidity
// LibAppStorage.sol
enum RiskTier { LOW, MEDIUM, HIGH }

struct AppStorage {
    // ----- global config -----
    address usdc;                 // base asset
    address artha;                // reward/governance token
    address oracle;               // OracleAggregator
    address swapAggregator;       // approved router
    address treasury;
    address emergencyFund;

    // ----- roles (read by LibAccess) -----
    mapping(address => bool) isExecutor;     // bounded admin (multisig) that triggers batches
    mapping(address => bool) isGuardian;     // pause / emergency
    address governance;                       // == Timelock; only setter of bounds

    // ----- pools (keyed by poolId) -----
    uint256 poolCount;                        // = 3
    mapping(uint256 => bool)      poolActive;
    mapping(uint256 => RiskTier)  poolTier;
    mapping(uint256 => address[]) poolBasket;        // ≤5 tokens
    mapping(uint256 => uint256)   idleUsdc;          // un-deployed USDC in pool
    mapping(uint256 => address[]) poolStrategies;    // deployed positions

    // ----- shares (ERC-4626 internal accounting) -----
    mapping(uint256 => uint256) totalShares;
    mapping(uint256 => mapping(address => uint256)) shares;
    uint8 decimalsOffset;                            // = 6 (inflation defense)

    // ----- daily deposit batching -----
    uint256 currentDay;                              // day index = block.timestamp / 1 days
    mapping(uint256 => mapping(uint256 => uint256)) pendingDeposit;        // [poolId][day] => USDC
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) userPendingDeposit;
    mapping(uint256 => mapping(uint256 => uint256)) sharesPerAsset;        // [poolId][day], 1e18, settled
    mapping(uint256 => mapping(uint256 => bool))    daySettled;

    // ----- RiskGuard limits (per pool) -----
    mapping(uint256 => uint16) maxWeightBps;   // per token cap (e.g. 4000)
    mapping(uint256 => uint16) minBufferBps;   // liquidity buffer floor (e.g. 1000)
    mapping(uint256 => uint16) maxSlippageBps; // per swap (e.g. 100)
    mapping(uint256 => uint16) rebalanceBandBps;
    mapping(uint256 => uint16) maxMemeBps;
    mapping(uint256 => mapping(address => uint16)) targetWeightBps;
    mapping(address => bool) whitelisted;
    mapping(address => bool) isMemeClass;

    // ----- rewards (ARTHA index per pool) -----
    mapping(uint256 => uint256) accArthaPerShare;    // 1e12
    mapping(uint256 => uint256) lastRewardUpdate;
    mapping(uint256 => uint256) totalEffectiveShares; // includes boosts
    mapping(uint256 => mapping(address => uint256)) effectiveShares;
    mapping(uint256 => mapping(address => uint256)) rewardDebt;
    uint256 constantPrecision;                       // 1e12 (set once)

    // ----- emission (16y halving) -----
    uint256 emissionStart;
    uint256 yearOneEmission;       // 100M
    uint256 rewardBudget;          // 200M
    uint256 totalEmitted;
    mapping(uint256 => uint16) poolEmissionShareBps; // split across pools

    // ----- fees + HWM (per pool) -----
    mapping(uint256 => uint16)  mgmtFeeBps;          // 200
    mapping(uint256 => uint16)  perfFeeBps;          // 1500
    mapping(uint256 => uint256) highWaterMark;       // pps, 1e18
    mapping(uint256 => uint256) lastMgmtAccrual;
    uint16 feeToStakingBps;                          // share of fees → staking
    uint16 feeToEmergencyBps;                        // share of fees → emergency fund

    // ----- penalty -----
    uint16 penaltyBps;             // 100 (1%)
    uint16 penToProtocolBps;       // 1000
    uint16 penToEmergencyBps;      // 2000
    uint16 penToUsersBps;          // 7000
    mapping(uint256 => uint256) minHoldPeriod;       // per pool, normal positions
    mapping(uint256 => mapping(address => uint256)) depositTimestamp;

    // ----- fixed-term locks -----
    struct LockView { uint256 shares; uint8 term; uint256 unlockTime; uint16 boostBps; }
    mapping(uint256 => mapping(address => LockView[])) locks;  // [poolId][user]
    mapping(uint8 => uint16)  termBoostBps;          // 1=>12500, 2=>15000, 3=>20000
    mapping(uint8 => uint256) termDuration;          // 90/180/360 days

    // ----- referral (your design, in AppStorage) -----
    mapping(uint16 => uint32) tierRebates;           // tierId => rebate (PPM, 1e6=100%)
    mapping(bytes32 => bytes32) codeOwnerPacked;     // see ReferralFacet (owner+tier+share)
    mapping(bytes32 => address) codeOwner;
    mapping(bytes32 => uint16)  codeTier;
    mapping(bytes32 => uint32)  codeDiscountShare;   // 0..1e6
    mapping(address => bytes32) ownerToCode;
    mapping(address => bytes32) traderToCode;
    mapping(address => uint256) referrerArthaEarned;
    mapping(address => uint256) referralVolume;      // cumulative invested via code (for tier promo)
    uint32 referralBaseRatePPM;                      // base referral ARTHA rate
    mapping(uint256 => uint32) poolReferralMultPPM;  // pool/risk multiplier

    // ----- staking (ARTHA → USDC, monthly) -----
    uint256 accUsdcPerStake;       // 1e12
    uint256 totalStakedEffective;
    mapping(address => uint256) stakedAmount;
    mapping(address => uint256) stakeLockEnd;
    mapping(address => uint16)  stakeBoostBps;       // veARTHA
    mapping(address => uint256) stakeUsdcDebt;
    uint256 currentMonth;
    uint256 monthlyUsdcPot;        // = last month's fees × feeToStakingBps
    uint256 feesCollectedThisMonth;

    // ----- circuit breaker -----
    bool paused;
    mapping(uint256 => uint256) peakPps;
    uint16 drawdownTriggerBps;     // 2500
    uint16 defensiveBufferBps;     // 3000
    uint256 deriskEpochs;
}
```

### The accessor (every facet uses this)

```solidity
library LibAppStorage {
    function diamondStorage() internal pure returns (AppStorage storage s) {
        assembly { s.slot := 0 }     // AppStorage occupies slot 0 onward
    }
}

abstract contract Modifiers {
    AppStorage internal s;           // <-- first state var in every facet => slot 0
    modifier onlyGovernance() { require(msg.sender == s.governance, "NOT_GOV"); _; }
    modifier onlyExecutor()   { require(s.isExecutor[msg.sender], "NOT_EXEC"); _; }
    modifier onlyGuardian()   { require(s.isGuardian[msg.sender], "NOT_GUARDIAN"); _; }
    modifier whenNotPaused()  { require(!s.paused, "PAUSED"); _; }
}
```

### Upgrade-safety rule (critical)

When you upgrade a facet and need new state, you may **only append** new fields to the END of `AppStorage` (and adding new `mapping` keys is always safe). **Never reorder, insert between, or change the type of existing fields** — that shifts every subsequent slot and corrupts storage. Treat AppStorage like an append-only ledger of fields. This is the #1 way Diamonds get bricked.

### Invariants

- `AppStorage` is declared identically (same field order) by `LibAppStorage` and inherited by every facet via `Modifiers`.
- `decimalsOffset > 0`, `constantPrecision == 1e12`, `poolCount == 3` after init.
- No facet declares any *other* state variable before `AppStorage s` (would collide with slot 0).

---

<a name="m2"></a>
## Module 2 — Diamond Infrastructure & Upgrade Safety

### Concept

`LibDiamond` holds the **facet registry** (which facet address serves which 4-byte selector) at a dedicated EIP-2535 storage slot (`keccak256("diamond.standard.diamond.storage")`), kept separate from AppStorage's slot 0. The Diamond's `fallback` looks up the selector and `delegatecall`s the facet.

### The proxy

```solidity
contract Diamond {
    constructor(address owner, address diamondCutFacet) {
        LibDiamond.setContractOwner(owner);                 // owner = Timelock
        // register diamondCut(...) selector → diamondCutFacet
    }
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 pos = LibDiamond.DIAMOND_STORAGE_POSITION;
        assembly { ds.slot := pos }
        address facet = ds.selectorToFacet[msg.sig];
        require(facet != address(0), "NO_SELECTOR");
        assembly {
            calldatacopy(0, 0, calldatasize())
            let r := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch r case 0 { revert(0, returndatasize()) } default { return(0, returndatasize()) }
        }
    }
    receive() external payable {}
}
```

### The upgrade function (timelocked)

```solidity
contract DiamondCutFacet {
    function diamondCut(
        IDiamond.FacetCut[] calldata cuts,   // {facet, action(Add/Replace/Remove), selectors[]}
        address init, bytes calldata initData
    ) external {
        LibDiamond.enforceIsContractOwner();  // owner == Timelock (delay enforced upstream)
        LibDiamond.diamondCut(cuts, init, initData);
    }
}
```

### Upgrade safety checklist

- `diamondCut` callable **only** by the Timelock; the Timelock enforces a delay (e.g. 48h) so users can exit before a malicious upgrade lands.
- **AppStorage append-only** (Module 1).
- New facet must not re-declare an existing selector unintentionally (Loupe + tests catch collisions).
- An `init` contract may run one-time migration logic on upgrade (e.g. set a new field's default) — run via `delegatecall` so it writes AppStorage.
- Keep `DiamondLoupeFacet` so anyone can audit which code serves which selector at any time.

### Invariants

- Every active selector resolves to a deployed facet (`facet != address(0)`).
- Owner of LibDiamond == Timelock.
- Removing a selector makes calls to it revert (no orphaned logic).

---

<a name="m3"></a>
## Module 3 — Pool Logic Facet (Shares, ERC-4626 Math, Inflation Defense)

### Concept

`PoolFacet` implements ERC-4626-style accounting per `poolId` using **internal balances** in AppStorage. Deposits are *requested* (batched, Module 5); withdrawals are *instant* (Module 5). Share math and the inflation defense live in `LibShares`.

### Math

`A` = pool `totalAssets` (USDC value of everything, Module 4), `S` = `totalShares[poolId]`.

$$ \text{pps} = \frac{A}{S}, \qquad s_{\text{mint}} = \frac{d \cdot (S + 10^{\text{offset}})}{A + 1}, \qquad a_{\text{out}} = \frac{s \cdot A}{S} $$

The **virtual offset** (`offset = 6`) neutralizes the first-depositor / donation inflation attack: seeding 1 wei then donating can't round a victim's mint to 0 because the `+10^6` term dominates. (Same defense as OZ ERC4626.)

### AppStorage fields used

`totalShares`, `shares`, `idleUsdc`, `decimalsOffset` (Module 1).

### Facet functions

```solidity
contract PoolFacet is Modifiers {
    function requestDeposit(uint256 poolId, uint256 usdcAmount, bytes32 refCode) external whenNotPaused;
    function withdraw(uint256 poolId, uint256 shareAmount, bool asUsdc) external;  // instant (Module 5)
    function balanceOfShares(uint256 poolId, address u) external view returns (uint256);
    function pricePerShare(uint256 poolId) external view returns (uint256);   // delegates to NavFacet/LibNav
    function convertToShares(uint256 poolId, uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 poolId, uint256 shares) external view returns (uint256);
}
```

### Worked example

Pool `A = 90,000`, `S = 80,000`, `offset = 6` → `pps ≈ 1.125`.
Alice's `9,000` USDC (settled at day-end): `s = 9,000 × (80,000 + 1e6) / (90,000 + 1) ≈ 9,000 × 1,080,000 / 90,001 ≈ 107,999` ... — note with offset the raw share count scales with the virtual term; what matters is her **proportional** claim equals `9,000/90,000 = 10%` of post-deposit value. (Use OZ's exact rounding; the offset only blocks the attack, it doesn't change fair proportions at realistic sizes.)

### Invariants

- `Σ shares[poolId][u] == totalShares[poolId]`.
- Deposit-then-withdraw returns `≤` deposited (rounding favors pool).
- `pps` non-decreasing except on real loss.
- `decimalsOffset > 0` enforced.

---

<a name="m4"></a>
## Module 4 — NAV Facet (Pricing a Multi-Asset Pool)

### Concept

`totalAssets` for a pool = idle USDC + basket tokens priced via oracle + value deployed in lending strategies. Bounded loop over ≤5 basket tokens + strategies.

### Math

$$ A_{\text{pool}} = \text{idleUsdc} + \sum_{i=1}^{n}\frac{q_i p_i}{10^{d_i}} + \sum_{j=1}^{m} V_j^{\text{strat}} $$

`p_i` from `OracleAggregator` (USDC-denominated, scaled); `V_j^strat` reported by each strategy facet (Module 7).

### Facet functions

```solidity
contract NavFacet is Modifiers {
    function totalAssets(uint256 poolId) public view returns (uint256 usdcValue);
    function pricePerShare(uint256 poolId) external view returns (uint256);
}
```

### Worked example

idle 10,000 + WBTC 0.5×60,000 (=30,000) + wstETH 10×3,000 (=30,000) + aUSDC strat 20,000 = **90,000**. With `S=80,000` → `pps=1.125`.

### Invariants

- Every `p_i` fresher than `maxOracleDelay`, else revert.
- `poolBasket[poolId].length ≤ 5`.
- A token deployed to a strategy is valued by the strategy, **not** double-counted as idle.

---

<a name="m5"></a>
## Module 5 — Deposits (End-of-Day Batch) & Withdrawals (Instant)

### Concept (your core requirement)

- **Deposits do NOT swap on entry.** `requestDeposit` escrows USDC into the pool's pending bucket for the current day. **At day end, the admin executor** triggers `settleDay`, which validates the target allocation (RiskGuard), performs **one batched swap** for the whole day's USDC into the basket, records the day's `sharesPerAsset`, and credits shares. Admin-triggered timing defeats batch front-running and the inflation attack.
- **Withdrawals are instant.** `withdraw` prices the user's shares at **live NAV**, pulls liquidity (buffer first, then atomic strategy withdrawals), and either transfers the **pro-rata basket in-kind** (no swap) or **swaps to USDC in the same tx** (withdrawer pays slippage + gas). Shares burn immediately.

### Math — fair day-batch settlement

At `settleDay` (pre-settlement snapshot `A`, `S`), aggregated pending `D = Σ d_u`:

$$ s_{\text{batch}} = \frac{D\,(S + 10^{\text{offset}})}{A + 1},\qquad \text{sharesPerAsset}_{\text{day}} = \frac{s_{\text{batch}}}{D} $$

Each user later claims `s_u = d_u × sharesPerAsset_day` — identical to depositing individually at the day's NAV, but one swap for everyone.

### Math — instant withdrawal

For `s` shares of pool with `A`, `S`: gross claim `a = s·A/S`. Liquidity sourced as:

$$ \text{fromBuffer} = \min(a_{\text{usdc-portion}}, \text{idleUsdc}), \quad \text{rest} \Rightarrow \text{atomic strategy withdraw + (optional) swap} $$

In-kind path: transfer `q_i · s/S` of each basket token + `idleUsdc · s/S`. USDC path: do the above then swap basket legs to USDC at `minOut` floor.

### AppStorage fields used

`pendingDeposit`, `userPendingDeposit`, `sharesPerAsset`, `daySettled`, `idleUsdc`, `currentDay`.

### Facet functions

```solidity
contract BatchFacet is Modifiers {
    function settleDay(uint256 poolId, address[] calldata tokens, uint16[] calldata weights, bytes[] calldata swapData)
        external onlyExecutor;            // validates RiskGuard, one batched swap, sets sharesPerAsset
    function claimShares(uint256 poolId, uint256 day) external;   // credit settled shares to user
}
// PoolFacet.withdraw(...) handles the instant path.
```

### Worked example

Day N pending: Alice 9,000 + Bob 4,500 = `D=13,500`, pre-snapshot `A=90,000, S=80,000`.
`s_batch = 13,500×80,000/90,000 = 12,000`; `sharesPerAsset = 0.8889`. Alice→8,000 shares, Bob→4,000. One swap converts 13,500 USDC into basket weights. Next day Bob withdraws 4,000 shares in-kind: receives `4,000/84,000` of every basket token + idle USDC, instantly, no swap. ✅

### Invariants

- `claimShares` only after `daySettled[poolId][day] == true`.
- `Σ userPendingDeposit[poolId][day][u] == pendingDeposit[poolId][day]`.
- Sum of claimed shares for day N `== s_batch`.
- Buffer floor `≥ minBufferBps · A` maintained after settlement.
- Withdrawals succeed even when `paused` (users can always exit).
- Reentrancy guard on `withdraw`; pull-pattern transfers.

---

<a name="m6"></a>
## Module 6 — Allocation & RiskGuard Facets

### Concept

Governance sets per-pool target weights + caps. The executor's `settleDay`/`rebalance` calls **must** pass `RiskGuardFacet.validateAllocation` before any swap. LOW pool whitelist = stables only (empty basket → pure lending); MEDIUM/HIGH carry volatile baskets with caps.

### Math

$$ \sum_i w_i + w_{\text{buffer}} = 10{,}000,\quad 0\le w_i \le \text{cap}_i,\quad \text{(HIGH) } \sum_{\text{meme}} w_i \le \text{maxMemeBps} $$

Rebalance allowed only when drift exceeds band:
$$ \max_i\left|\frac{q_i p_i}{A} - \frac{w_i}{10^4}\right| > \delta_{\text{rebalance}} $$

### Facet functions

```solidity
contract RiskGuardFacet is Modifiers {
    function setLimits(uint256 poolId, uint16 maxWeight, uint16 minBuffer, uint16 maxSlip, uint16 band, uint16 maxMeme) external onlyGovernance;
    function setTargetWeights(uint256 poolId, address[] calldata tokens, uint16[] calldata w) external onlyGovernance;
    function setWhitelist(address token, bool ok, bool meme) external onlyGovernance;
    function validateAllocation(uint256 poolId, address[] calldata tokens, uint16[] calldata w) external view returns (bool);
    function validateSwap(uint256 poolId, uint256 amountIn, uint256 minOut) external view;
}
contract AllocationFacet is Modifiers {
    function rebalance(uint256 poolId, address[] calldata tokens, uint16[] calldata w, bytes[] calldata swapData) external onlyExecutor;
}
```

### Worked example

HIGH, `A=100,000`, WBTC cap 40%, buffer min 10%. Executor submits `WBTC 40/ETH 20/SOL 15/LINK 15/AAVE 10` (buffer 0) → **revert** (`buffer 0 < 1000`). Corrected `36/18/14/13/9 + 10% buffer` passes.

### Invariants

- `Σ w + buffer == 10000`, each `≤ cap`, all tokens whitelisted, meme aggregate `≤ cap`.
- Swap legs respect oracle slippage floor.
- Rebalance reverts inside the drift band (no gas churn).
- Only `onlyGovernance` can change any bound; executor only acts within them.

---

<a name="m7"></a>
## Module 7 — Strategy Facets (Lending; Diamond Holds Positions)

### Concept

Because the Diamond custodies funds, strategy logic runs as facets via `delegatecall` — the Diamond is `msg.sender` to Aave/Compound/Morpho and **holds the receipt tokens** (aUSDC, Comet position, MetaMorpho shares). Adding a protocol = `diamondCut` a new strategy facet (timelocked).

**Yield reality:** only stables (Aave/Morpho/Compound/Silo ~3–8%) and ETH-via-wstETH (staking + lending) earn. WBTC/SOL/LINK/AAVE have ~no lending market → held idle in the pool (valued by NAV at oracle price). So HIGH-pool return on those legs is price appreciation, not yield.

### Interface

```solidity
contract StrategyFacet is Modifiers {
    function deploy(uint256 poolId, address strategyKey, address token, uint256 amount) external onlyExecutor; // supply to protocol
    function undeploy(uint256 poolId, address strategyKey, uint256 amount) external returns (uint256);
    function strategyValue(uint256 poolId, address strategyKey) external view returns (uint256 usdcValue);     // for NAV
    function harvest(uint256 poolId, address strategyKey) external returns (uint256 claimed);                  // claim rewards → re-supply
    function emergencyExit(uint256 poolId, address strategyKey) external onlyGuardian;                         // pull all to idle
}
```

Per-protocol logic (Aave supply→aToken, Compound Comet base supply, Morpho MetaMorpho supply — note Morpho doesn't socialize bad debt, so the chosen market/curator is a governance parameter) lives in libraries (`LibAaveV3`, `LibCompoundV3`, `LibMorpho`) called by the facet.

### Harvest math

Reward emissions claimed → swapped to base via `SwapFacet` → re-supplied. Raises `strategyValue` → raises NAV → raises `pps` for all holders.

### Invariants

- `Σ strategyValue + idleUsdc + basket-priced == NavFacet.totalAssets` (no leakage).
- `undeploy` returns `≥ amount` or reverts.
- External calls reentrancy-guarded; return values checked.
- `emergencyExit` only when paused + `onlyGuardian`.

---

<a name="m8"></a>
## Module 8 — Swap Facet & Slippage

### Concept

Integrate an aggregator (1inch/0x/CoW/Paraswap). Backend computes the route off-chain; the facet executes it and enforces an **oracle-derived `minOut` floor**, so a malicious route can't sandwich past the cap.

### Math

$$ \text{minOut} \ge \frac{\text{amountIn}\cdot p_{\text{in}}}{p_{\text{out}}}\left(1 - \frac{\text{maxSlippageBps}}{10^4}\right) $$

### Facet

```solidity
contract SwapFacet is Modifiers {
    function swap(uint256 poolId, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata routerCalldata)
        external onlyExecutor returns (uint256 amountOut);
    // 1) require minOut ≥ oracle floor  2) approve aggregator  3) call  4) require out ≥ minOut  5) reset approval to 0
}
```

### Invariants

- `amountOut ≥ max(minOut, oracleFloor)`; approval reset to 0 after.
- Only the governance-approved `swapAggregator` is callable (no arbitrary call target).
- Per-day turnover cap to bound MEV.

---

<a name="m9"></a>
## Module 9 — Reward Facet (`accArthaPerShare` Engine)

### Concept

The MasterChef/Compound index, per pool. Every (effective) share earns ARTHA equally per unit time; one global index + per-user debt baseline avoids looping.

### Derivation

Emission rate `R` ARTHA/sec (from `EmissionFacet`, pool's slice), `S` = `totalEffectiveShares[poolId]`. Over `Δt`, each share earns `R·Δt/S`:

$$ \text{acc} \mathrel{+}= \frac{R\,\Delta t}{S}\cdot 1e12,\qquad \text{pending}_u = \frac{s^{\text{eff}}_u\cdot\text{acc}}{1e12} - \text{rewardDebt}_u $$

On any share change: settle pending, then `rewardDebt_u = s^eff_u · acc / 1e12`. Boosts (fixed-term, Module 13) enter via `s^eff = s·boost`.

### Facet

```solidity
contract RewardFacet is Modifiers {
    function _update(uint256 poolId) internal;     // accrue acc since lastRewardUpdate using EmissionFacet rate
    function pendingArtha(uint256 poolId, address u) external view returns (uint256);
    function claimArtha(uint256 poolId) external;  // mints from ArthaToken (Diamond is minter)
}
```

### Worked example

`S=10,000` eff, `R=1/s`. After 100s: `acc += 1×100/10,000 ×1e12`. Alice 2,000 shares, debt 0 → pending `20` ARTHA; claim sets debt 20. With a 360-day lock (boost 2.0) her eff = 4,000 → pending `40`.

### Invariants

- `Σ pendingArtha ≤ totalEmitted` (engine never over-pays).
- `_update` runs before every share-affecting action.
- `totalEffectiveShares == Σ effectiveShares`.
- Total ARTHA minted by rewards `≤ rewardBudget` (Module 10).

---

<a name="m10"></a>
## Module 10 — Emission Facet (16-Year Annual Halving)

### Concept

Rewards = **20% of 1B = 200M ARTHA**, emitted with **annual halving over 16 years**, designed so the budget is essentially fully emitted by the end (final stretch completes it). Declining emission bounds dilution and lets fee-based real yield take over.

### Derivation

Year-`n` emission halves: `Y_n = Y_1·(1/2)^{n-1}`. Sum over 16 years:

$$ \sum_{n=1}^{16} Y_1\left(\tfrac12\right)^{n-1} = Y_1\cdot\frac{1-(1/2)^{16}}{1-1/2} = Y_1\cdot 2\left(1 - \tfrac{1}{65536}\right) = B $$

$$ \Rightarrow Y_1 = \frac{B}{2(1 - 2^{-16})} \approx \frac{200\text{M}}{1.99997} \approx 100\text{M} $$

So **Y1 ≈ 100M, Y2 ≈ 50M, Y3 ≈ 25M, …, Y16 ≈ 100M/2^15 ≈ 3{,}052**. Cumulative by end of year 16:

$$ B\left(1 - 2^{-16}\right) \approx 99.998\%\ \text{of } B $$

The residual (~3,050 ARTHA) is emitted by a **final true-up** in the last period so cumulative `== exactly 200M` — i.e. "in the last 6 months everything completes." Per-second rate in year `n`:

$$ R_n = \frac{Y_n}{365\cdot 86400}\quad(\text{piecewise-constant, halving each year}) $$

Daily emission: Y1/365 ≈ **273,973 ARTHA/day** (year 1), halving yearly. Split across pools by `poolEmissionShareBps` (e.g. HIGH 50 / MED 30 / LOW 20) plus a slice to the fixed-term boost.

### AppStorage / facet

```solidity
contract EmissionFacet is Modifiers {
    function currentYear() public view returns (uint256);              // (now - emissionStart)/365d
    function emissionRatePerSec(uint256 poolId) external view returns (uint256);  // R_n × poolShare
    function emittedToDate() external view returns (uint256);
    // mints gated so totalEmitted ≤ rewardBudget; final-year true-up emits remainder
}
```

### Invariants

- `totalEmitted ≤ rewardBudget (200M)`; mint reverts above.
- `Y_n` strictly halving; `Σ poolEmissionShareBps == 10000`.
- Cumulative reaches exactly `200M` by end of year 16 (true-up).

---

<a name="m11"></a>
## Module 11 — Fee Facet (Management + Performance, High-Water Mark)

### Concept

Two revenue streams (feeding the **monthly staking pot**, Module 15, and the emergency fund): a **management fee** on AUM and a **performance fee** on profit gated by a **high-water mark**. Both taken by minting shares to treasury (dilution), so no user asset is seized.

### Math

Management (per period, on elapsed time): `mgmtFee = A·r_mgmt·Δt/yr`; `feeShares = mgmtFee/pps`.

Performance with HWM (at settlement):
$$ pps>HWM:\ \text{profit}=(pps-HWM)\,S,\ \ \text{perfFee}=\text{profit}\cdot r_{\text{perf}},\ \ HWM\leftarrow pps $$
If `pps ≤ HWM`: **no perf fee** (must recover prior losses first).

Defaults: `r_mgmt=2%/yr`, `r_perf=15%`, HWM per pool. Collected fees split: `feeToStakingBps` → staking pot, `feeToEmergencyBps` → emergency fund, remainder → treasury.

### Facet

```solidity
contract FeeFacet is Modifiers {
    function accrueFees(uint256 poolId) external;   // called at day settle; mgmt + perf(HWM); routes splits; adds to feesCollectedThisMonth
}
```

### Worked example

`HWM=1.10`, `pps=1.20`, `S=100,000`, `r_perf=15%` → profit `10,000`, perfFee `1,500` USDC, `feeShares=1,250` to treasury, `HWM←1.20`. Next settle `pps=1.15<1.20` → no perf fee. ✅

### Invariants

- Perf fee only when `pps>HWM`; HWM monotonic non-decreasing.
- Fee shares minted == fee value (no over-mint).
- `feeToStakingBps + feeToEmergencyBps ≤ 10000`; routed amounts conserved; staking slice accumulates into `feesCollectedThisMonth`.

---

<a name="m12"></a>
## Module 12 — Penalty Facet (Early Exit & Split)

### Concept

Breaking the rules (normal withdraw before `minHoldPeriod`, or breaking a fixed-term lock) costs **1% of principal**, split **10% protocol / 20% emergency / 70% remaining users**.

### Math

$$ \text{penalty}=P\cdot r_{\text{pen}}\ (1\%),\quad \text{toUsers}=0.70\,\text{penalty} $$
$$ \Delta\text{accArthaPerShare}_{\text{(or accUsdc)}} = \frac{\text{toUsers}\cdot 1e12}{S_{\text{remaining}}} $$

70% redistributes pro-rata to remaining holders by bumping the index (no loop).

### Facet

```solidity
contract PenaltyFacet is Modifiers {
    function computePenalty(uint256 poolId, address u, uint256 principal) public view returns (uint256 penalty, bool applies);
    // applies if now < depositTimestamp + minHoldPeriod (or lock not matured); called inside withdraw/unlock
}
```

### Worked example

Alice principal 1,000, early exit → penalty `10`. Split: 1 protocol / 2 emergency / 7 to remaining users (index bump). Alice nets `principal + profit − 10`.

### Invariants

- `penToProtocolBps+penToEmergencyBps+penToUsersBps == 10000`.
- Applies only inside the lock/min-hold window.
- 70% increase to remaining users' claims exactly equals `toUsers` (conservation).
- Penalty on principal only.

---

<a name="m13"></a>
## Module 13 — Fixed-Term Facet (90/180/360)

### Concept

Lock for 90/180/360 days for **boosted ARTHA emissions** (underlying yield unchanged; boost multiplies effective shares in Module 9). Breaking a lock → Module 12 penalty.

### Math

$$ s^{\text{eff}} = s\cdot\beta(\text{term}),\quad \beta_{90}=1.25,\ \beta_{180}=1.5,\ \beta_{360}=2.0 $$

### Facet

```solidity
contract FixedTermFacet is Modifiers {
    function lock(uint256 poolId, uint256 shares, uint8 term) external;            // term 1/2/3
    function unlock(uint256 poolId, uint256 lockId) external;                      // penalty if early
}
```

`locks[poolId][user]` is an array → multiple concurrent locks per user.

### Worked example

Bob locks 4,000 shares 360d (β=2.0) → eff 8,000 → double ARTHA vs unlocked for the duration. Early unlock at day 100 → Module 12 penalty.

### Invariants

- `termBoostBps`/`termDuration` set for all terms.
- Effective-share contribution updated in RewardFacet on lock/unlock.
- Locked shares can't use the normal withdraw path until matured (or penalized early-unlock).

---

<a name="m14"></a>
## Module 14 — Referral Facet (Tiers + Discount Share)

### Concept (modeled directly on your uploaded `ReferralSystem.sol`)

At deposit, a referred investor's code earns **ARTHA** sized by **deposit amount × pool/risk multiplier × tier rebate**. The code owner sets a **discount share** splitting that reward between the **investor** (return discount) and the **owner**. Governance **promotes tiers** as a code drives more volume. Convention preserved: **PPM units** (`1e6 = 100%`, so 20% = `200_000`).

### Math

Base referral reward for a deposit `d` into pool `poolId`, code on tier `t`:

$$ R_{\text{ref}} = \underbrace{d \cdot \frac{\text{poolReferralMultPPM}[poolId]}{1e6}}_{\text{risk/pool-scaled base, in ARTHA-equiv}} \cdot \frac{\text{tierRebates}[t]}{1e6} $$

Split by the owner's `discountShare` (fraction returned to investor):

$$ \text{investorReturn} = R_{\text{ref}}\cdot\frac{\text{discountShare}}{1e6},\qquad \text{ownerReward} = R_{\text{ref}} - \text{investorReturn} $$

This is exactly your `calculateReferralRewards` (`traderDiscount`/`referrerReward`) with the base being the **referral ARTHA** instead of a trading-fee rebate.

### AppStorage fields used

`tierRebates`, `codeOwner`, `codeTier`, `codeDiscountShare`, `ownerToCode`, `traderToCode`, `referrerArthaEarned`, `referralVolume`, `poolReferralMultPPM`, `referralBaseRatePPM`.

### Facet functions (ported from your contract)

```solidity
contract ReferralFacet is Modifiers {
    // user / trader
    function registerCode(bytes32 code, uint32 discountShare) external;          // default tier 1
    function setDiscountShare(uint32 share) external;
    function setTraderCode(bytes32 code) external;
    function transferCodeOwnership(bytes32 code, address newOwner) external;

    // governance (your adminSetReferrerTier / setTierRebate)
    function setTierRebate(uint16 tierId, uint32 rebatePPM) external onlyGovernance;
    function setReferrerTier(address referrer, uint16 newTierId) external onlyGovernance;  // volume-based promotion
    function setPoolReferralMult(uint256 poolId, uint32 multPPM) external onlyGovernance;

    // called by PoolFacet/BatchFacet at deposit settlement
    function accrueReferral(uint256 poolId, address investor, uint256 depositAmount) external;
    // -> resolves traderToCode, blocks self-referral, computes R_ref, credits investorReturn (ARTHA to investor)
    //    and ownerReward (ARTHA to code owner), bumps referralVolume (for tier promotion)

    // views
    function calculateReferralRewards(uint256 poolId, address trader, uint256 depositAmount)
        external view returns (uint256 investorReturn, uint256 ownerReward);
}
```

Carry over your guards: code must exist to be set by a trader; `discountShare ≤ 1e6`; one code per owner (`ownerToCode` write-once until transfer); **self-referral blocked** (`codeOwner[code] != investor`); deactivation handler (the Diamond) can zero a code's owner.

### Worked example

Investor deposits 1,000 USDC into HIGH (`poolReferralMult = 50_000` PPM = 5%), code on **tier 2** (`tierRebates[2] = 300_000` PPM = 30%). Base `R_ref = 1,000 × 0.05 × 0.30 = 15` ARTHA-equiv. Owner's `discountShare = 200_000` (20%): investor gets `15 × 0.20 = 3` ARTHA back, owner gets `12` ARTHA. As this code's `referralVolume` crosses a governance threshold, `setReferrerTier` promotes it to tier 3 (higher rebate). ✅

### Invariants

- `traderToCode[u]` settable only to an existing code; `ownerToCode` one-per-owner.
- Self-referral returns `(0,0)`.
- `discountShare ≤ 1e6`; `tierRebates[t] ≤ 1e6`.
- Referral ARTHA counts against `rewardBudget` (or a dedicated referral sub-budget) with per-referrer/per-day caps.

---

<a name="m15"></a>
## Module 15 — Staking Facet (ARTHA → Monthly USDC from Fees)

### Concept (your requirement)

Stake ARTHA → earn **USDC** sourced from **last month's collected fees**. Each month the distributable pot resets to last month's fee take (× `feeToStakingBps`), so the **rate changes monthly** with protocol revenue. veARTHA lock boosts. This is the **real-yield** sink that lets emissions taper.

### Math

At month rollover `m→m+1`, snapshot fees collected during month `m`:

$$ \text{monthlyUsdcPot}_{m+1} = \text{feesCollected}_m \cdot \frac{\text{feeToStakingBps}}{10^4} $$

Distribute via the same accumulator (reward asset = USDC), streamed over the month:

$$ \text{accUsdcPerStake} \mathrel{+}= \frac{\text{inflow}\cdot 1e12}{\text{totalStakedEffective}},\quad \text{pendingUsdc}_u=\frac{\text{stake}^{\text{eff}}_u\cdot\text{accUsdcPerStake}}{1e12}-\text{debt}_u $$

veARTHA: `stake^eff = stake · f(lockTime)`, e.g. `1.0 → 2.5` (Curve-style). **Sustainability:** this is the `F` in `d·E·P ≤ F`; as emissions `E` halve yearly and fee-driven `F` grows, ARTHA crosses to standing on real cash flow.

### Facet

```solidity
contract StakingFacet is Modifiers {
    function stake(uint256 amount, uint256 lockDuration) external;        // sets veARTHA boost
    function unstake(uint256 amount) external;                            // after lockEnd
    function claimUsdc() external;
    function rolloverMonth() external;     // sets monthlyUsdcPot = last month's fees × feeToStakingBps; resets counter
    function pendingUsdc(address u) external view returns (uint256);
}
```

### Worked example

Last month fees → staking slice = 50,000 USDC; `totalStakedEffective = 1,000,000`. `accUsdcPerStake += 50,000/1,000,000 = 0.05` USDC/eff-share. Staker with 10,000 eff ARTHA earns `500` USDC — backed entirely by revenue, zero ARTHA minted. Next month fees rise to 80,000 → pot and rate rise. ✅

### Invariants

- USDC paid `≤` USDC received (no phantom yield).
- `totalStakedEffective == Σ stake^eff`.
- `monthlyUsdcPot` derives from the **previous** month's realized fees (no forward spending).
- Unstake only after `stakeLockEnd`.

---

<a name="m16"></a>
## Module 16 — Governance, Timelock, Ownership & the Bounded Executor

### Concept

The Diamond's **owner is the Timelock**, which is controlled by the **Governor** (votes weighted by ARTHA / veARTHA). The **executor** is a separate multisig that can only *trigger bounded operations* (`settleDay`, `rebalance`, `harvest`) — never change a bound. The **guardian** multisig can pause / emergency-exit.

### Powers matrix

| Action | Role | Path |
|---|---|---|
| `diamondCut` (upgrade any facet) | Governance | Governor → Timelock (delay) |
| Whitelist / weights / caps / fees / emission split | Governance | Governor → Timelock |
| Promote referral tier | Governance | `setReferrerTier` (via Timelock or delegated) |
| `settleDay` / `rebalance` / `harvest` (bounded) | Executor (multisig) | direct, RiskGuard-validated |
| `rolloverMonth` (staking) | Executor / anyone | direct |
| Pause / `emergencyExit` | Guardian (multisig) | direct (paused state) |
| De-risk trigger | Guardian or on-chain condition | CircuitBreaker |

### Facet

```solidity
contract AdminFacet is Modifiers {
    // governance setters (all onlyGovernance == Timelock)
    function setRoles(address executor, bool ok) external onlyGovernance;
    function setGuardian(address g, bool ok) external onlyGovernance;
    function setFees(uint256 poolId, uint16 mgmt, uint16 perf) external onlyGovernance;
    function setFeeRouting(uint16 toStaking, uint16 toEmergency) external onlyGovernance;
    function setPenalty(uint16 pen, uint16 toProto, uint16 toEmerg, uint16 toUsers) external onlyGovernance;
    function setEmissionSplit(uint16[] calldata poolBps) external onlyGovernance;
    // ... every bound has a governance-only setter
}
```

### Invariants

- Every bound-setter is `onlyGovernance` and `governance == Timelock`.
- `diamondCut` callable only by Timelock; delay non-bypassable.
- Executor cannot change any bound; only acts within RiskGuard.
- Guardian actions gated on `paused` (except pause itself).

---

<a name="m17"></a>
## Module 17 — Oracle & Circuit Breaker

### Concept

NAV correctness needs trustworthy prices; safety needs the ability to de-risk **gradually** (never a single-block fire-sale that sells the bottom).

### Math — graduated de-risk

$$ \frac{pps_{\text{peak}} - pps}{pps_{\text{peak}}} > \theta_{\text{dd}}\ (25\%)\ \Rightarrow\ \text{raise buffer toward } w_{\text{defensive}}\ (30\%)\ \text{over } k\ \text{days} $$

### External oracle + facet

```solidity
contract OracleAggregator { // external, read-only
    function price(address token) external view returns (uint256);  // Chainlink+Pyth; revert if stale/divergent
}
contract CircuitBreakerFacet is Modifiers {
    function checkAndTrigger(uint256 poolId) external;   // anyone can poke; acts only if drawdown condition true
    function pause() external onlyGuardian;
    function unpause() external onlyGovernance;
}
```

### Invariants

- `price()` reverts if stale (`> maxDelay`) or Chainlink/Pyth diverge `> maxDivergenceBps`.
- De-risk spread over `k` days; never a single-tx full liquidation.
- Pause halts deposits/rebalances but **always allows withdrawals**.

---

<a name="m18"></a>
## Module 18 — Protocol-Wide Invariants (Test Checklist)

1. **Storage:** AppStorage field order identical across all facets; only appended on upgrades.
2. **Share conservation:** `Σ shares[poolId][u] == totalShares[poolId]`.
3. **NAV identity:** `idle + Σ strategyValue + Σ basket·price == totalAssets` (rounding).
4. **No free shares:** no path mints shares without matching assets (offset defense verified).
5. **pps monotonicity:** decreases only on real loss.
6. **Reward solvency:** `Σ pendingArtha ≤ totalEmitted ≤ rewardBudget (200M)`; cumulative == 200M by year 16.
7. **Fee solvency:** USDC to stakers `≤` fees received; perf fee only when `pps > HWM`; HWM monotonic.
8. **Weight bounds:** post-op `Σ w + buffer == 10000`, each `≤ cap`, buffer `≥ min`, meme `≤ cap`.
9. **Penalty conservation:** 10/20/70 fully routed; 70% index bump exact.
10. **Referral:** self-referral blocked; `discountShare, tierRebate ≤ 1e6`; investorReturn+ownerReward == R_ref.
11. **Staking:** monthly pot derives from prior month's realized fees; payouts ≤ inflow.
12. **Access:** only Timelock changes bounds / `diamondCut`; executor bounded; guardian gated on pause.
13. **Liveness on exit:** withdrawals succeed even when paused / de-risking.
14. **Oracle safety:** any priced action reverts on stale/divergent feeds.
15. **Day-batch fairness:** Σ claimed shares per day == `s_batch`.
16. **Upgrade safety:** removed selectors revert; every active selector resolves to a deployed facet.

Run as a Foundry **invariant suite** + **forked-L2 integration** (real Aave/Morpho/Compound + real aggregator), `forge coverage ≥ 95%` on core libs, external audit before mainnet funds (Diamonds especially — the upgrade key is the prize).

---

<a name="m19"></a>
## Module 19 — Default Parameters & Token Distribution

| Parameter | Default | Module |
|---|---|---|
| Chain | L2 (Base / Arbitrum) | 0 |
| Pools | 0=LOW / 1=MED / 2=HIGH (`poolId`) | 0 |
| Base asset | USDC (deposits, fees, staking) | — |
| Tokens per pool | ≤ 5 | 4,6 |
| `decimalsOffset` | 6 | 3 |
| Min deposit | 100 USDC (per deposit) | 5 |
| Deposit timing | **end-of-day batch** (executor-triggered) | 5 |
| Withdraw timing | **instant** (live NAV) | 5 |
| Liquidity buffer (min) | 10% | 5 |
| Per-token weight cap (HIGH) | 40% | 6 |
| Max slippage / swap | 1% | 8 |
| Rebalance drift band | 3% | 6 |
| ARTHA supply | 1,000,000,000 (hard cap) | 10 |
| Reward budget | 200,000,000 (20%) | 10 |
| Emission | **annual halving, 16 years** | 10 |
| Y1 / Y2 / … / Y16 | ~100M / 50M / … / ~3,052 (true-up to 200M) | 10 |
| Day-1 emission | ~273,973 ARTHA/day | 10 |
| Pool emission split | HIGH 50 / MED 30 / LOW 20 | 10 |
| Management fee | 2% / yr | 11 |
| Performance fee | 15% (HWM) | 11 |
| Fee → staking | governance-set (e.g. 60%) | 11,15 |
| Fee → emergency | governance-set (e.g. 15%) | 11 |
| Early-exit penalty | 1% of principal | 12 |
| Penalty split | 10 / 20 / 70 (protocol / emergency / users) | 12 |
| Min-hold (normal) | governance-set (e.g. 15–30 d) | 12 |
| Fixed-term boosts | 1.25× / 1.5× / 2.0× (90/180/360 d) | 13 |
| Referral units | PPM (1e6 = 100%) | 14 |
| Referral pool mult (HIGH) | e.g. 5% (50,000 PPM) | 14 |
| Default tier rebate | tier 1 set by governance | 14 |
| veARTHA boost | 1.0× → 2.5× | 15 |
| Staking reward | monthly USDC = last month's fees × feeToStaking | 15 |
| Timelock delay | 48 h | 16 |
| Drawdown de-risk trigger | 25% → 30% buffer over k days | 17 |

### Token distribution (1B)

| Bucket | % | Tokens | Notes |
|---|---|---|---|
| Community & rewards | 20% | 200M | 16-yr halving (Module 10) |
| Treasury / ecosystem | 25% | 250M | ops, grants, runway |
| Liquidity (DEX + CEX) | 20% | 200M | pools + listings |
| Airdrop | 15% | 150M | web2 acquisition |
| Team / founder | 15% | 150M | 3–4 yr vest |
| Safety / insurance reserve | 5% | 50M | backstop |

> Non-negotiables regardless of exact split: emissions **decline** (Module 10), team/treasury **vest**, and `diamondCut` is **timelocked**.

---

<a name="m20"></a>
## Module 20 — Build Order

1. **Diamond + LibDiamond + DiamondCut/Loupe/Ownership + LibAppStorage** — bare Diamond that can cut facets; lock owner to a placeholder, later the Timelock.
2. **PoolFacet + NavFacet + BatchFacet** — deposit-request → end-of-day settle → shares; instant withdraw. The spine, on testnet.
3. **RiskGuardFacet + AllocationFacet + StrategyFacet (Aave first) + SwapFacet** — bounded executor loop with one real lending integration (forked L2).
4. **RewardFacet + EmissionFacet + ArthaToken** — 16-yr halving incentive layer.
5. **FeeFacet + PenaltyFacet + StakingFacet** — revenue + monthly USDC staking (the sustainability layer).
6. **ReferralFacet** — port your `ReferralSystem.sol` into AppStorage with ARTHA rewards + discountShare + tiers.
7. **FixedTermFacet + CircuitBreakerFacet + OracleAggregator** — locks + safety.
8. **Governor + Timelock**, transfer Diamond ownership to Timelock, set executor/guardian multisigs.
9. **Invariant suite + forked integration + audit.**

Each facet is independently testable and independently upgradeable — ship and harden one before cutting the next.

---

### Note on your uploaded `ReferralSystem.sol`

The standalone contract is sound and maps cleanly onto `ReferralFacet`: move its state into `AppStorage`, keep the PPM convention (`1e6`), tiers, `discountShare` split, self-referral guard, and handler-deactivation. The one semantic change for Artha: the rebate **base** is the deposit-derived **referral ARTHA** (amount × pool multiplier × tier), not a trading-fee rebate — so `calculateReferralRewards` returns `(investorReturn, ownerReward)` in ARTHA. Governance drives tier promotion off `referralVolume`. Everything else carries over 1:1.
