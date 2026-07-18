# Artha Protocol

> **Status:** implemented. `contracts/src/facets/`, `contracts/src/libraries/`,
> `contracts/src/strategies/`, `contracts/src/oracle/`, `contracts/src/rewards/`,
> `contracts/src/referral/`, and `contracts/src/governance/` are built. Deploy
> scripts and the test suite are the next phase, not yet written.
>
> **Start here:** [`docs/architecture.md`](../docs/architecture.md) (system layout,
> facet map, access control) and [`docs/formulas.md`](../docs/formulas.md) (every
> formula — NAV, share math, fees, caps — with worked numeric examples). Per-facet
> detail lives in [`docs/facets/`](../docs/facets/), per-strategy detail in
> [`docs/strategies/`](../docs/strategies/).
>
> ---
>
> ## ⚠ Parts I–III below (§0–§12) describe an EARLIER, SUPERSEDED design
>
> Everything from here through the end of §12 (just before "PART IV —
> STRATEGIES") documents a design that was never built: vaults as ERC-721
> positions, per-position cost-basis accounting, an entry-fee + profit-fee model,
> and an end-of-day batch-deploy flow explicitly different from Yearn's real one.
> It is kept below as historical design-reasoning context, not as a description of
> the current codebase.
>
> **What was actually built instead**, in one paragraph: one Diamond serves an
> arbitrary number of vaults, each identified by its own `VaultShareToken` — a
> plain, transferable ERC-20 (fungible shares, not ERC-721 positions; this is what
> lets `UserRewardVault` stake vault shares with a bare `transferFrom`, no special
> integration). Deposits mint shares immediately against a checkpointed NAV and
> sit as idle balance until the keeper's `deployIdle`/`rebalance` call actually
> deploys them — Yearn's real production model (Model A), not the batched
> alternative these sections describe. Each vault holds up to 5 strategies plus an
> admin-set 0–10% idle buffer, priced by `idle + Σ strategy.totalAssets()` (each
> strategy already folds in oracle-converted position value and haircut pending
> rewards — see `docs/strategies/00-base-strategy.md`). The fee is ONE vault-wide
> aggregate high-water-mark performance fee, realized by minting shares to the
> treasury, never a per-position entry/profit fee pair. Full detail, with worked
> arithmetic for every one of these, is in `docs/formulas.md`.
>
> **Part IV (§13–§16, strategies) and Part V (§17–§20, rewards + referral) DO**
> describe the current system and remain accurate — nothing there changed.
>
> **Part VI (§21–§25, operations) is ALSO superseded**, for the same reason as
> Parts I–III: §21–§22's "super admin can only touch strategies while a
> protocol-wide `emergency` flag freezes every user's deposit/withdraw" model was
> never built. What exists instead (`VaultAdminFacet` + `VaultEmergencyFacet`, see
> `docs/architecture.md` §5 and `docs/facets/VaultEmergencyFacet.md`): a guardian
> can pause a vault (or the whole protocol) instantly, but can **never** unpause —
> only governance (the timelock, via a full public proposal) can. Strategy changes
> (`addStrategy`/`removeStrategy`/`setTargets`/`migrateStrategy`) are `onlyGovernance`
> at all times, not gated behind a declared emergency — the timelock's own public
> delay window is the front-running defense, not a separate freeze mechanism.
> Withdrawals are NEVER fully frozen: a paused vault blocks the *normal*
> `withdraw`/`redeem` path, but `emergencyWithdraw` remains open to everyone,
> always, and never reverts on a liquidity shortfall. §21's "keeper cannot add/
> remove a strategy" and "worst case if the keeper key is stolen" reasoning
> **does** still hold for the implemented `VaultHarvestFacet` (harvest/deployIdle/
> rebalance only, same bounded blast radius) — only the super-admin/emergency-gate
> mechanics in §22 (and the worked walkthroughs in §23 that assume it) differ.

---

## Table of contents

**Part I — Orientation**
1. [§0 · What changed from v3, and why](#s0)
2. [§1 · The system in one picture](#s1)
3. [§2 · Vocabulary](#s2)

**Part II — The vault**
4. [§3 · Vault = Diamond + ERC-721](#s3)
5. [§4 · Facets: what lives where](#s4)
6. [§5 · Storage layout](#s5)
7. [§6 · Positions: multiple per user, per vault](#s6)
8. [§7 · Access control: who may call what](#s7)

**Part III — Money**
9. [§8 · Total liquidity: the heart of the system](#s8)
10. [§9 · Share accounting](#s9)
11. [§10 · The deposit → end-of-day-deploy flow](#s10)
12. [§11 · Withdrawal + profit-only fees](#s11)
13. [§12 · Fee model in full](#s12)

**Part IV — Strategies**
14. [§13 · Strategy interface + the four yield shapes](#s13)
15. [§14 · Why one mechanism needs many contracts](#s14)
16. [§15 · The strategies Artha will ship](#s15)
17. [§16 · Swap adapter + oracle](#s16)

**Part V — Rewards**
18. [§17 · The two parallel reward systems](#s17)
19. [§18 · User rewards: System + Vault split](#s18)
20. [§19 · Referral rewards: the existing stack](#s19)
21. [§20 · Address-keyed, not id-keyed](#s20)

**Part VI — Operations**
22. [§21 · Roles: keeper, timelock, super admin](#s21)
23. [§22 · Emergency mode](#s22)
24. [§23 · Worked example: a full day](#s23)
25. [§24 · Invariants & audit checklist](#s24)
26. [§25 · Build order](#s25)

---

<a name="s0"></a>
## §0 · What changed from v3, and why

| # | Change | Why it matters |
|---|---|---|
| **1** | **PositionManager deleted.** Each vault is its own ERC-721. Users call the vault directly; the vault routes to its facets. | v3's single manager was a global chokepoint and forced one-NFT-per-user across all vaults. Removing it lets each vault own its position lifecycle and removes a hop from every call. |
| **2** | **Multiple positions per user, per vault.** `mint()` on demand; user says "new position" or "add to #7". | Different entry prices, different cost bases, different exit timing. One NFT per user made partial exits and tax-lot tracking impossible. |
| **3** | **Reward ratio keyed by vault address.** Many vaults can share a base token (USDC-Conservative, USDC-Aggressive) with different ARTHA rates. | Reward should track *risk taken*, not *token deposited*. |
| **4** | **`rewardRatio == 0` → no ARTHA.** Explicit, checked, no accrual. | The clean off-switch when the pool is spent. |
| **5** | **Emergency mode gates admin surgery.** Super admin can only add/remove/rebalance/re-weight when emergency is ON — and while it's on, users cannot deposit or withdraw. Timelock + keeper can call these functions any time. | Prevents an admin from re-weighting while users transact against a mid-flight state. |
| **6** | **Total liquidity = invested + interest + reward-tokens-valued-in-base.** COMP/CRV/etc. are priced into the base token before any share math. | v3 read `strategy.convertToAssets()` and ignored unclaimed reward tokens. That systematically **understated** the vault and let a late depositor buy shares cheap right before a harvest. |
| **7** | **Entry fee (gas + maintenance) + profit-only exit fee.** | Entry fee covers keeper gas. Exit fee only on profit above cost basis — never on principal, never when underwater. |
| **8** | **Anyone can deposit into a position; only the owner withdraws/claims.** | Enables third-party top-ups, treasury funding, DCA bots. |
| **9** | **ARTHA rewards keyed by user address, not tokenId.** | A user with 5 positions in 3 vaults has *one* ARTHA balance. Claiming shouldn't mean 15 transactions. |
| **10** | **User rewards split into System + Vault**, mirroring the referral stack: System = logic/accounting, Vault = custody/transfer. Vaults *notify* it exactly like they notify the referral vault. | Symmetry. Two reward programs, one integration pattern, one mental model. |
| **11** | **One mechanism → many strategy contracts.** `CompoundUsdcStrategy` and `CompoundWethStrategy` are separate deployments. | Their harvest paths differ (USDC market pays interest in USDC; WETH market pays in WETH; both pay COMP). Different swap route ⇒ different contract. |

---

<a name="s1"></a>
## §1 · The system in one picture

```
                                  ┌─────────────────────────────────┐
                                  │        GOVERNANCE (Timelock)     │
                                  │   ArthaToken · Governor · Time   │
                                  └───────────────┬─────────────────┘
                                                  │ owns / configures
                 ┌────────────────────────────────┼────────────────────────────────┐
                 │                                │                                │
                 ▼                                ▼                                ▼
    ┌────────────────────────┐      ┌────────────────────────┐      ┌────────────────────────┐
    │   USER REWARD SYSTEM   │      │    REFERRAL SYSTEM     │      │    VAULT REGISTRY      │
    │  (logic + accounting)  │      │  (logic + accounting)  │      │  (which vaults exist)  │
    └───────────┬────────────┘      └───────────┬────────────┘      └────────────────────────┘
                │ pays via                      │ pays via
                ▼                               ▼
    ┌────────────────────────┐      ┌────────────────────────┐
    │   USER REWARD VAULT    │      │    REFERRAL VAULT      │
    │  (holds ARTHA, cap)    │      │  (holds ARTHA, cap)    │
    └───────────▲────────────┘      └───────────▲────────────┘
                │  notifyDeposit / notifyWithdraw│
                │                                │
    ┌───────────┴────────────────────────────────┴───────────┐
    │                                                         │
    │            ARTHA VAULT  (Diamond + ERC-721)             │  ◄── USER calls directly
    │                                                         │      (no PositionManager)
    │  ┌──────────────────────────────────────────────────┐   │
    │  │  Facets (delegatecall, shared AppStorage)        │   │
    │  │   PositionFacet  · mint / burn / ERC-721          │   │
    │  │   DepositFacet   · deposit into position          │   │
    │  │   WithdrawFacet  · withdraw + profit fee          │   │
    │  │   AccountingFacet· totalLiquidity / pps / views   │   │
    │  │   KeeperFacet    · deployIdle / rebalance         │   │
    │  │   AdminFacet     · add/remove strategy, emergency │   │
    │  │   RewardFacet    · ARTHA sync / claim routing     │   │
    │  │   LoupeFacet     · introspection                  │   │
    │  │   CutFacet       · upgrades                       │   │
    │  └──────────────────────────────────────────────────┘   │
    └───────────┬─────────────────────────────────────────────┘
                │ deploys base token into (1..5)
                ▼
    ┌───────────────────────────────────────────────────────────────┐
    │  STRATEGIES (each its own contract, its own harvest path)      │
    │                                                                │
    │   AaveUsdcStrategy      CompoundUsdcStrategy   SUsdsStrategy   │
    │   ├ aToken rebases      ├ interest in USDC     ├ pps rises     │
    │   └ no reward token     └ + COMP → swap→USDC   └ no rewards    │
    └──────────────┬─────────────────────────────────────────────────┘
                   │ prices reward tokens through
                   ▼
    ┌──────────────────────────┐      ┌──────────────────────────┐
    │      SWAP ADAPTER        │      │         ORACLE           │
    │  (1inch / CoW / Curve)   │      │   (Chainlink / TWAP)     │
    └──────────────────────────┘      └──────────────────────────┘
```

**Read the picture in one sentence:** a user calls a vault, the vault mints them an
NFT position and books shares, the keeper deploys idle capital into that vault's
strategies at end of day, each strategy reports its *total liquidity* (principal +
interest + reward tokens priced in base), and the vault notifies two independent
reward systems that a referred/rewarded balance changed.

---

<a name="s2"></a>
## §2 · Vocabulary

Precise words, used consistently for the rest of this document.

| Term | Meaning |
|---|---|
| **Vault** | One Diamond contract. One base token. 1–5 strategies. Its own ERC-721. |
| **Position** | One ERC-721 `tokenId` inside one vault. Has shares + a cost basis. |
| **Shares** | Internal, non-transferable balance keyed by `tokenId`. Claim on the vault's assets. |
| **Base token** | The vault's asset (USDC, WETH, DAI). Everything is valued in it. |
| **Strategy** | A contract that takes base token, does something, and reports total liquidity in base token. |
| **Total liquidity** | `invested + interest + (reward tokens × price × haircut)`. §8. |
| **Idle** | Base token sitting in the vault, not yet deployed. |
| **Buffer** | The slice of idle deliberately kept for instant withdrawals. |
| **pps** | Price per share = `totalLiquidity / totalShares`. |
| **Cost basis** | Net base token a position has been credited with. Drives the profit fee. |
| **ARTHA** | The reward token. Pre-minted, capped, paid by two independent systems. |
| **Keeper** | Bot. Deploys idle, harvests, rebalances. Cannot move funds outside targets. |
| **Timelock** | Governance. Configures everything. The real owner in production. |
| **Super admin** | Break-glass key. Can only act when emergency mode is ON. |

---

<a name="s3"></a>
## §3 · Vault = Diamond + ERC-721

This is the central structural change, so it gets its own section.

### 3.1 What "the vault is the ERC-721" means concretely

```solidity
// The vault Diamond's fallback delegates to facets, but the ERC-721 *state*
// (owners, balances, approvals) lives in the vault's own AppStorage.
// PositionFacet implements the ERC-721 surface over that storage.

contract ArthaVault {              // Diamond
    fallback() external payable {
        address facet = LibDiamond.diamondStorage()
            .selectorToFacetAndPosition[msg.sig].facetAddress;
        require(facet != address(0), "no selector");
        // delegatecall → facet runs, but reads/writes THIS vault's storage
        ...
    }
}
```

So `ownerOf(7)`, `transferFrom(a,b,7)`, `balanceOf(alice)` are all **vault
functions**, served by `PositionFacet`, operating on `LibVaultStorage`. The vault
*is* the NFT collection. `USDC-Conservative` is one collection. `USDC-Aggressive`
is a different collection with a different address and its own `tokenId` space.

### 3.2 Why this is better than the v3 PositionManager

```
 v3                                          v4
 ──────────────────────────────────────      ──────────────────────────────────────
 user ──► PositionManager ──► Vault A        user ──► Vault A  (is its own ERC-721)
              │            ──► Vault B       user ──► Vault B  (is its own ERC-721)
              │            ──► Vault C       user ──► Vault C  (is its own ERC-721)
              │
              └─ ONE NFT for everything      each vault: many NFTs per user
                 global tokenId space        independent tokenId spaces
                 extra hop on every call     direct call
                 manager knows every vault   vaults know nothing about each other
                 upgrade manager = risk to   upgrade one vault = only that vault
                   every vault at once
```

Four concrete wins:

1. **Blast radius.** A bug in v3's manager was a bug in *every* vault. In v4, vaults
   are isolated: `USDC-Aggressive` can be paused, upgraded, or drained without
   `WETH-Conservative` noticing.
2. **One less hop.** `deposit()` was `user → manager → vault → facet`. Now it's
   `user → vault → facet`. Cheaper, and the vault sees `msg.sender == the actual user`
   instead of `msg.sender == manager` (which is why v3 had to thread an `owner`
   parameter through every function — that parameter is now gone).
3. **Independent token IDs.** Vault A can mint #1..#900 while Vault B mints #1..#3.
   No coordination, no shared counter.
4. **Marketplace clarity.** Each vault is one OpenSea collection with a coherent
   floor price, because every NFT in it holds the same base token under the same
   strategy mix. In v3, one collection mixed WETH and USDC positions — a meaningless
   floor.

### 3.3 The trade-off, stated honestly

You lose the single-call cross-vault view. `positionValue(user)` across five vaults
is now five calls instead of one. **This is the right trade** — that's a read, and
reads are free off-chain. A frontend or a subgraph aggregates it trivially. You do
not distort the write path (which costs real gas and carries real risk) to optimise
a read path that has a free solution.

If you want it on-chain anyway, add a **stateless** `ArthaLens` view contract:

```solidity
contract ArthaLens {
    function positionsOf(address user, address[] calldata vaults)
        external view returns (PositionView[][] memory)
    { /* loop, read, return */ }
}
```
It holds no state, has no privileges, and can be redeployed at will. It is *not*
in the trust path — which is exactly the difference between it and v3's manager.

---

<a name="s4"></a>
## §4 · Facets: what lives where

Nine facets. The split is by **who calls it**, not by what it does — because
that's what makes access control auditable at a glance.

```
┌─────────────────┬──────────────────────────────────┬───────────────────────────┐
│ FACET           │ FUNCTIONS                        │ CALLER                    │
├─────────────────┼──────────────────────────────────┼───────────────────────────┤
│ PositionFacet   │ mint()                           │ anyone                    │
│                 │ burn(id)                         │ position owner            │
│                 │ ownerOf / balanceOf / tokenURI   │ view                      │
│                 │ transferFrom / approve / ...     │ owner or approved         │
├─────────────────┼──────────────────────────────────┼───────────────────────────┤
│ DepositFacet    │ deposit(id, amount)              │ ANYONE (§6.4)             │
│                 │ mintAndDeposit(amount)           │ anyone                    │
├─────────────────┼──────────────────────────────────┼───────────────────────────┤
│ WithdrawFacet   │ withdraw(id, assets, to)         │ position OWNER only       │
│                 │ redeem(id, shares, to)           │ position OWNER only       │
├─────────────────┼──────────────────────────────────┼───────────────────────────┤
│ AccountingFacet │ totalLiquidity()                 │ view                      │
│                 │ pps() / convertToShares/Assets   │ view                      │
│                 │ positionValue(id)                │ view                      │
├─────────────────┼──────────────────────────────────┼───────────────────────────┤
│ KeeperFacet     │ deployIdle()                     │ keeper OR timelock        │
│                 │ harvest(strategy)                │ keeper OR timelock        │
│                 │ harvestAll()                     │ keeper OR timelock        │
│                 │ rebalance()                      │ keeper OR timelock (§21)  │
│                 │ setTargets(...)                  │ keeper OR timelock (§21)  │
│                 │ syncStrategy(s)                  │ keeper OR timelock        │
├─────────────────┼──────────────────────────────────┼───────────────────────────┤
│ AdminFacet      │ addStrategy(s, bps)              │ timelock, OR super admin  │
│                 │ removeStrategy(s)                │   ONLY IN EMERGENCY (§22) │
│                 │ setBuffer(bps)                   │                           │
│                 │ setEmergency(bool)               │ timelock or super admin    │
│                 │ setKeeper(a) / setFees(...)      │ timelock only             │
├─────────────────┼──────────────────────────────────┼───────────────────────────┤
│ RewardFacet     │ claimArtha(to)                   │ msg.sender (own rewards)  │
│                 │ syncArtha(user)                  │ anyone (permissionless)   │
│                 │ pendingArtha(user)               │ view                      │
├─────────────────┼──────────────────────────────────┼───────────────────────────┤
│ LoupeFacet      │ facets / facetAddress / ...      │ view                      │
├─────────────────┼──────────────────────────────────┼───────────────────────────┤
│ CutFacet        │ diamondCut(...)                  │ timelock ONLY             │
└─────────────────┴──────────────────────────────────┴───────────────────────────┘
```

**Why `deposit` and `withdraw` are different facets.** They have different callers
(anyone vs owner) and different risk. Splitting them means you can `diamondCut` a
withdrawal fix without touching the deposit path, and an auditor reviewing "who can
take money out" reads exactly one file.

---

<a name="s5"></a>
## §5 · Storage layout

One `AppStorage` struct at a fixed slot. Every facet reads the same struct.

```solidity
library LibVaultStorage {
    bytes32 constant POSITION = keccak256("artha.vault.storage.v4");

    uint256 constant MAX_STRATEGIES = 5;
    uint256 constant MIN_STRATEGIES = 1;
    uint256 constant BPS  = 10_000;
    uint256 constant ACC  = 1e18;
    uint256 constant YEAR = 360 days;
    uint8   constant OFFSET = 6;

    struct Position {
        uint256 shares;       // claim on vault assets
        uint256 costBasis;    // NET base token credited (drives profit fee)
        uint64  createdAt;
        uint64  lastDeposit;
    }

    struct StrategyInfo {
        bool    active;
        uint16  targetBps;      // % of DEPLOYABLE funds
        uint256 index;
        uint256 lastReported;   // total liquidity at last harvest
        uint64  lastHarvest;
    }

    struct VaultStorage {
        // ── identity / wiring ──
        address asset;
        uint8   assetDecimals;
        uint256 scale;              // 10^(18-dec) for normalisation
        string  name;
        string  symbol;

        address timelock;
        address keeper;
        address superAdmin;
        address rewardSystem;       // user-reward logic contract
        address referralVault;      // referral stack entry point
        address swapAdapter;
        address oracle;

        bool    initialized;
        bool    emergency;          // §22

        // ── ERC-721 state (PositionFacet operates on this) ──
        mapping(uint256 => address) ownerOf;
        mapping(address => uint256) balanceOf;
        mapping(uint256 => address) tokenApprovals;
        mapping(address => mapping(address => bool)) operatorApprovals;
        uint256 nextTokenId;        // starts at 1
        uint256 totalSupply;

        // ── positions ──
        mapping(uint256 => Position) positions;
        mapping(address => uint256[]) userPositions;  // enumeration
        uint256 totalShares;

        // ── strategies ──
        address[] strategies;
        mapping(address => StrategyInfo) strategyInfo;
        uint16 minBufferBps;

        // ── fees ──
        uint16  entryFeeBps;        // gas + maintenance, taken on deposit
        uint16  perfFeeBps;         // % of PROFIT ONLY, taken on withdraw
        address feeRecipient;
        uint256 accruedFees;        // base token owed to treasury

        // ── ARTHA accrual (ADDRESS-keyed, not id-keyed — §20) ──
        uint256 accArthaPerPrincipal;
        uint256 lastArthaUpdate;
        mapping(address => uint256) userPrincipalNorm; // user => Σ costBasis, 18dp
        mapping(address => uint256) userRewardDebt;
        uint256 totalPrincipalNorm;
    }

    function s() internal pure returns (VaultStorage storage vs) {
        bytes32 p = POSITION;
        assembly { vs.slot := p }
    }
}
```

**Note the ARTHA mappings are keyed by `address`, not `uint256 tokenId`.** That's
change #9 and it's load-bearing — §20 explains the full consequence.

---

<a name="s6"></a>
## §6 · Positions: multiple per user, per vault

### 6.1 The mental model

```
   Alice
     │
     ├── USDC-Conservative vault (ERC-721 "aUSDC-C")
     │      ├── #1   shares: 5,000    basis: 5,000    opened Jan
     │      ├── #4   shares: 12,000   basis: 12,000   opened Mar
     │      └── #9   shares: 800      basis: 800      opened Jul
     │
     ├── USDC-Aggressive vault (ERC-721 "aUSDC-A")   ← same base token!
     │      └── #2   shares: 30,000   basis: 30,000
     │
     └── WETH-Core vault (ERC-721 "aWETH")
            └── #1   shares: 4e18     basis: 4e18

   Alice's ARTHA balance: ONE number, tracked per (vault, address).  §20
```

Three positions in one vault. Different entry points, different cost bases,
independently exitable. `#1` and `#4` are separate NFTs — she can sell `#4` and keep
`#1`.

### 6.2 Why multiple positions matter

| Reason | Without it (v3) | With it (v4) |
|---|---|---|
| **Cost basis** | One blended basis. Exit "at a loss" is impossible to express when half the position is up. | Each lot has its own basis. Exit the losing lot, keep the winner. |
| **Selling part** | You sell the whole portfolio or nothing. | Sell `#4`, keep `#1` and `#9`. |
| **Different mandates** | A DAO's treasury and its grants budget share one NFT. | One NFT each. Separate accounting, separate signers. |
| **Tax lots** | Blended. Your accountant hates you. | FIFO/LIFO/specific-lot, all expressible. |
| **Testing a strategy** | Move everything or nothing. | Open a small position, watch it, scale in. |

### 6.3 The two entry paths

```solidity
// PositionFacet
function mint() external returns (uint256 tokenId) {
    LibVaultStorage.VaultStorage storage vs = LibVaultStorage.s();
    require(!vs.emergency, "EMERGENCY");
    tokenId = vs.nextTokenId++;
    _mint(msg.sender, tokenId);
    vs.positions[tokenId].createdAt = uint64(block.timestamp);
    emit PositionOpened(msg.sender, tokenId);
}

// DepositFacet — convenience: mint + deposit in one tx
function mintAndDeposit(uint256 amount) external returns (uint256 tokenId) {
    tokenId = IPositionFacet(address(this)).mint();
    _deposit(tokenId, amount);
}

// DepositFacet — add to an existing position
function deposit(uint256 tokenId, uint256 amount) external {
    require(_exists(tokenId), "NO_POSITION");
    _deposit(tokenId, amount);
}
```

The user's choice — "new position" or "position #7" — is just *which function they
call*. No flag, no mode, no ambiguity.

### 6.4 Anyone deposits, only the owner withdraws

```
      ┌──────────────────────────────────────────────────────┐
      │  deposit(tokenId, amount)          → ANYONE          │
      │  ─────────────────────────────────────────────────   │
      │  Bob can top up Alice's #4.                          │
      │  A DAO can fund a grantee's position.                │
      │  A DCA bot can deposit weekly on your behalf.        │
      │  An employer can vest into an employee's position.   │
      └──────────────────────────────────────────────────────┘
                              │
                              │  shares & basis credit the POSITION
                              │  ARTHA principal credits the OWNER
                              ▼
      ┌──────────────────────────────────────────────────────┐
      │  withdraw(tokenId, assets, to)     → OWNER ONLY      │
      │  claimArtha(to)                    → SELF ONLY       │
      │  ─────────────────────────────────────────────────   │
      │  Only ownerOf(tokenId) can pull value out.           │
      └──────────────────────────────────────────────────────┘
```

This asymmetry is deliberate and safe: **depositing into someone's position is a
gift, not an attack.** It increases their shares and their basis. There is no way to
deposit *maliciously* — the worst case is you gave someone money.

> **The one real edge case.** A donor's deposit raises the owner's `costBasis`, which
> *lowers* the owner's future profit fee. Someone could theoretically deposit to
> manipulate a fee calculation. But they'd have to give away real capital to do it,
> and the beneficiary is the position owner, not the depositor. Not exploitable.

**Critical detail:** when Bob deposits into Alice's `#4`, the ARTHA reward principal
credits **Alice** (the owner), not Bob. The reward follows ownership, because the
reward is for *having capital at risk*, and Alice is the one who can withdraw it.

```solidity
function _deposit(uint256 tokenId, uint256 amount) internal {
    VaultStorage storage vs = LibVaultStorage.s();
    require(!vs.emergency, "EMERGENCY");          // §22
    require(amount > 0, "ZERO");

    address owner = vs.ownerOf[tokenId];          // ← the OWNER, not msg.sender

    // 1. pull gross from the CALLER (may be anyone)
    IERC20(vs.asset).safeTransferFrom(msg.sender, address(this), amount);

    // 2. entry fee (§12)
    uint256 fee = amount * vs.entryFeeBps / BPS;
    uint256 net = amount - fee;
    vs.accruedFees += fee;

    // 3. bank the OWNER's ARTHA at the OLD principal, before it changes
    LibArtha.settle(owner);

    // 4. mint shares against the PRE-deposit liquidity base
    uint256 shares = LibShares.convertToSharesOnDeposit(net);
    require(shares > 0, "ZERO_SHARES");
    vs.positions[tokenId].shares += shares;
    vs.positions[tokenId].costBasis += net;       // ← basis = NET, not gross
    vs.positions[tokenId].lastDeposit = uint64(block.timestamp);
    vs.totalShares += shares;

    // 5. grow the OWNER's ARTHA principal, re-checkpoint
    uint256 norm = net * vs.scale;
    vs.userPrincipalNorm[owner] += norm;
    vs.totalPrincipalNorm += norm;
    LibArtha.recheckpoint(owner);

    // 6. notify BOTH reward systems (§17)
    IRewardSystem(vs.rewardSystem).notifyDeposit(address(this), owner, net);
    IReferralVault(vs.referralVault).notifyDeposit(address(this), owner, net);

    emit Deposited(tokenId, owner, msg.sender, amount, fee, net, shares);
}
```

> **Read step 3 and 5 together.** This is the *bank-before-change* rule and it is the
> single most important pattern in the reward engine. Settle at the old principal,
> *then* change the principal, *then* re-checkpoint. Get the order wrong and you
> either pay the new rate on old time (theft from the pool) or lose accrued rewards
> (theft from the user).

---

<a name="s7"></a>
## §7 · Access control: who may call what

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                          THE COMPLETE PERMISSION MATRIX                        ║
╠══════════════════════╤════════╤════════╤═════════╤══════════╤═════════════════╣
║ FUNCTION             │ anyone │ owner  │ keeper  │ timelock │ superAdmin      ║
╠══════════════════════╪════════╪════════╪═════════╪══════════╪═════════════════╣
║ mint()               │   ✓    │        │         │          │                 ║
║ deposit(id, amt)     │   ✓    │        │         │          │                 ║
║ withdraw(id,...)     │        │   ✓    │         │          │                 ║
║ burn(id)             │        │   ✓    │         │          │                 ║
║ transferFrom(...)    │        │   ✓    │         │          │                 ║
║ claimArtha(to)       │        │  self  │         │          │                 ║
║ syncArtha(user)      │   ✓    │        │         │          │                 ║
╟──────────────────────┼────────┼────────┼─────────┼──────────┼─────────────────╢
║ deployIdle()         │        │        │    ✓    │    ✓     │                 ║
║ harvest(s)           │        │        │    ✓    │    ✓     │                 ║
║ rebalance()          │        │        │    ✓    │    ✓     │  emergency only ║
║ setTargets(...)      │        │        │    ✓    │    ✓     │  emergency only ║
╟──────────────────────┼────────┼────────┼─────────┼──────────┼─────────────────╢
║ addStrategy(s, bps)  │        │        │         │    ✓     │  emergency only ║
║ removeStrategy(s)    │        │        │         │    ✓     │  emergency only ║
║ setBuffer(bps)       │        │        │         │    ✓     │  emergency only ║
╟──────────────────────┼────────┼────────┼─────────┼──────────┼─────────────────╢
║ setEmergency(bool)   │        │        │         │    ✓     │       ✓         ║
║ setKeeper(a)         │        │        │         │    ✓     │                 ║
║ setFees(...)         │        │        │         │    ✓     │                 ║
║ setRewardRatio(...)  │        │        │         │    ✓     │   (on System)   ║
║ diamondCut(...)      │        │        │         │    ✓     │                 ║
╚══════════════════════╧════════╧════════╧═════════╧══════════╧═════════════════╝
```

The `emergency only` column is the whole of change #5 and gets §22 to itself.

```solidity
modifier onlyKeeperOrTimelock() {
    VaultStorage storage vs = LibVaultStorage.s();
    require(msg.sender == vs.keeper || msg.sender == vs.timelock, "NOT_AUTHORISED");
    _;
}

/// Timelock any time; super admin ONLY while emergency is on.
modifier onlyTimelockOrEmergencyAdmin() {
    VaultStorage storage vs = LibVaultStorage.s();
    require(
        msg.sender == vs.timelock ||
        (msg.sender == vs.superAdmin && vs.emergency),
        "NOT_AUTHORISED"
    );
    _;
}

modifier whenNotEmergency() {
    require(!LibVaultStorage.s().emergency, "EMERGENCY");
    _;
}
```

---

# PART III — MONEY

<a name="s8"></a>
## §8 · Total liquidity: the heart of the system

**This is the most important section in the document.** Every share price, every
deposit, every withdrawal, every fee depends on getting this one number right.

### 8.1 The question

> "How much is this vault actually worth, right now, in base token?"

Sounds trivial. It isn't. Because a strategy's value is scattered across **three
different shapes**, and two of them aren't denominated in the base token at all.

### 8.2 The three components

```
   TOTAL LIQUIDITY of a strategy
   ═════════════════════════════
   
        ┌────────────────────────────────────────────────────────┐
        │  1. INVESTED PRINCIPAL                                 │
        │     What we supplied. Denominated in base token.       │
        │     Compound: our Comet balance's principal part       │
        │     Aave:     our aToken balance's principal part      │
        └────────────────────────────────────────────────────────┘
                              +
        ┌────────────────────────────────────────────────────────┐
        │  2. ACCRUED INTEREST — already in BASE TOKEN           │
        │     Compound USDC market → pays interest in USDC       │
        │     Aave USDC market     → aToken rebases in USDC      │
        │     ✓ No conversion needed. Already base.              │
        └────────────────────────────────────────────────────────┘
                              +
        ┌────────────────────────────────────────────────────────┐
        │  3. REWARD TOKENS — NOT in base token                  │
        │     Compound → COMP                                    │
        │     Curve    → CRV                                     │
        │     Convex   → CVX  (+ CRV)                            │
        │     Aerodrome→ AERO                                    │
        │     ✗ MUST be priced into base before counting.        │
        └────────────────────────────────────────────────────────┘
                              ║
                              ▼
        ┌────────────────────────────────────────────────────────┐
        │  TOTAL = invested + interest + (rewards × price × 0.98)│
        └────────────────────────────────────────────────────────┘
```

### 8.3 The bug this fixes (v3 got this wrong)

v3's `LibShares.totalAssets()` did this:

```solidity
// v3 — WRONG
assets = IERC20(vs.asset).balanceOf(address(this));
for (uint i; i < strats.length; i++) {
    assets += s.convertToAssets(s.balanceOf(address(this)));  // ← misses COMP!
}
```

`convertToAssets` on a Compound strategy returns the Comet balance. **It does not
include unclaimed COMP.** So:

```
  Reality:  strategy holds 500,000 USDC + 12,500 interest + 300 COMP (=12,348 USDC)
            true value = 524,848

  v3 says:  512,500     ← understates by 12,348 (2.4%)
```

**Why that's an actual exploit, not just an inaccuracy:**

```
  Day 1..29   COMP accrues silently. Vault reports 512,500. True value 524,848.
              pps is 2.4% too LOW.
              
  Day 30      ┌─ Mallory sees the pending harvest (it's a public mempool).
              │  She deposits 100,000 at the artificially LOW pps.
              │  She gets ~2.4% more shares than she should.
              │
              └─ Keeper harvests. COMP → USDC. totalAssets jumps 12,348.
                 pps jumps 2.4%. 
                 
  Day 31      Mallory withdraws. She has extracted ~2,400 USDC of yield
              that belonged to depositors who held through the whole month.
              
              She took zero risk. She was in the vault for one day.
```

This is a **harvest-front-run**, and it's a real, repeatedly-exploited class of bug
in yield aggregators. The fix is to count the reward tokens *continuously*, so the
harvest is a non-event for pps.

```
  ═══════════════════════════════════════════════════════════════════════
   pps over time — v3 (broken) vs v4 (correct)
  ═══════════════════════════════════════════════════════════════════════

  v3:   pps
         │                                    ╱▔▔▔▔▔  ← harvest = JUMP
         │                                   ╱          front-runnable
         │  ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁╱
         └────────────────────────────────────────────► t
                                          ↑ harvest

  v4:   pps
         │                          ▁▂▃▄▅▆▇█  ← smooth; harvest changes
         │                    ▁▂▃▄▅▆            NOTHING (COMP was already
         │  ▁▁▂▂▃▃▄▄▅▅▆▆▇▇             counted, just converted)
         └────────────────────────────────────────────► t
                                          ↑ harvest = no-op for pps
```

### 8.4 The implementation

```solidity
// BaseStrategy — every strategy implements _totalLiquidity()
abstract contract BaseStrategy is IStrategy {

    /// @notice THE function. Total value of everything this strategy controls,
    ///         denominated in the vault's base token.
    function totalLiquidity() public view returns (uint256) {
        return _investedPlusInterest() + _pendingRewardsInBase();
    }

    /// @dev Principal + interest, already in base token. Venue-specific.
    function _investedPlusInterest() internal view virtual returns (uint256);

    /// @dev Unclaimed reward tokens, priced into base token, haircut applied.
    ///      Returns 0 for strategies with no reward token (Aave, sUSDS).
    function _pendingRewardsInBase() internal view virtual returns (uint256) {
        return 0;   // default: no reward token
    }
}
```

**Compound USDC** — has both interest *and* a reward token:

```solidity
contract CompoundUsdcStrategy is BaseStrategy {
    IComet   public immutable comet;        // cUSDCv3
    ICometRewards public immutable rewards;
    IERC20   public immutable COMP;
    IOracle  public immutable oracle;
    uint16   public rewardHaircutBps = 200;  // 2% — see 8.5

    function _investedPlusInterest() internal view override returns (uint256) {
        // Comet balanceOf ALREADY includes accrued supply interest, in USDC.
        return comet.balanceOf(address(this));
    }

    function _pendingRewardsInBase() internal view override returns (uint256) {
        uint256 compQty = rewards.getRewardOwed(address(comet), address(this));
        if (compQty == 0) return 0;
        uint256 compValueInUsdc = oracle.quote(address(COMP), asset, compQty);
        // conservative: never over-report an unrealised, illiquid asset
        return compValueInUsdc * (10_000 - rewardHaircutBps) / 10_000;
    }
}
```

**Aave USDC** — interest only, no reward token:

```solidity
contract AaveUsdcStrategy is BaseStrategy {
    function _investedPlusInterest() internal view override returns (uint256) {
        // aToken REBASES: balance grows. Principal + interest in one number.
        return IERC20(aToken).balanceOf(address(this));
    }
    // _pendingRewardsInBase() → inherits the 0 default. Nothing to convert.
}
```

**sUSDS** — exchange-rate appreciation, no reward token, no rebase:

```solidity
contract SUsdsStrategy is BaseStrategy {
    function _investedPlusInterest() internal view override returns (uint256) {
        // shares × price-per-share. The pps rises; the share count doesn't.
        uint256 shares = IERC4626(sUSDS).balanceOf(address(this));
        return IERC4626(sUSDS).convertToAssets(shares);   // → USDS ≈ USDC 1:1 via PSM
    }
}
```

### 8.5 Why the 2% haircut

`_pendingRewardsInBase` discounts by `rewardHaircutBps`. Four reasons, each real:

| Risk | What happens without the haircut |
|---|---|
| **Slippage** | The oracle says COMP=$42. Selling 300 COMP moves the market; you realise $41.20. The vault over-reported. |
| **Oracle lag** | Chainlink updates on a deviation threshold. Between updates, the true price may be 1% below the reported one. |
| **Timing** | Rewards accrue continuously but harvest is periodic. The price at harvest ≠ the price at valuation. |
| **Manipulation** | If the reward token is thin, someone can pump the oracle, deposit at the inflated pps, and dump. The haircut shrinks the profit; the oracle's TWAP kills it. |

**Direction matters more than magnitude.** Over-reporting is theft from existing
holders (a new depositor buys shares that are worth less than they paid). Under-
reporting slightly is a gift to existing holders and self-corrects at harvest. **When
uncertain, always under-report.** 2% is a starting value; governance can tune it per
strategy.

### 8.6 Vault-level roll-up

```solidity
// AccountingFacet
function totalLiquidity() public view returns (uint256 total) {
    VaultStorage storage vs = LibVaultStorage.s();
    total = IERC20(vs.asset).balanceOf(address(this));   // idle
    address[] memory strats = vs.strategies;
    for (uint256 i; i < strats.length; i++) {
        total += IStrategy(strats[i]).totalLiquidity();   // ← the fixed number
    }
}
```

### 8.7 Worked example — verified arithmetic

**A USDC vault with two strategies.**

```
┌─────────────────────────────────────────────────────────────────────┐
│ COMPOUND USDC STRATEGY                                              │
├─────────────────────────────────────────────────────────────────────┤
│ invested principal                            500,000.00 USDC       │
│ accrued interest (already USDC)                12,500.00 USDC       │
│ COMP pending: 300 COMP                                              │
│   oracle: 1 COMP = 42 USDC        →  300 × 42 = 12,600.00 USDC      │
│   haircut 2%                      →  12,600 × 0.98 = 12,348.00      │
├─────────────────────────────────────────────────────────────────────┤
│ TOTAL LIQUIDITY                    500,000 + 12,500 + 12,348        │
│                                             = 524,848.00 USDC       │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ AAVE USDC STRATEGY                                                  │
├─────────────────────────────────────────────────────────────────────┤
│ aToken balance (principal + interest, rebased)  409,000.00 USDC     │
│ reward tokens                                          none         │
├─────────────────────────────────────────────────────────────────────┤
│ TOTAL LIQUIDITY                              = 409,000.00 USDC      │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ VAULT ROLL-UP                                                       │
├─────────────────────────────────────────────────────────────────────┤
│ idle (not yet deployed)                        80,000.00 USDC       │
│ Compound strategy                             524,848.00 USDC       │
│ Aave strategy                                 409,000.00 USDC       │
├─────────────────────────────────────────────────────────────────────┤
│ VAULT totalLiquidity                        1,013,848.00 USDC       │
└─────────────────────────────────────────────────────────────────────┘

Compare: v3 would have reported 80,000 + 512,500 + 409,000 = 1,001,500
         → understated by 12,348 USDC (1.23% of the vault)
         → every depositor in that window bought shares 1.23% too cheap
```

### 8.8 What happens at harvest

```
   BEFORE harvest                          AFTER harvest
   ─────────────────────────               ─────────────────────────
   invested    500,000                     invested    524,848  ← COMP sold,
   interest     12,500                     interest          0     proceeds
   COMP        300 (=12,348)               COMP              0     redeposited
   ─────────────────────────               ─────────────────────────
   TOTAL       524,848                     TOTAL       524,848  ← IDENTICAL

                        ┌──────────────────────────┐
                        │  pps does NOT move.      │
                        │  Nothing to front-run.   │
                        └──────────────────────────┘
```

That identity — **harvest does not change total liquidity** — is the invariant that
kills the front-run. Harvest only changes the *shape* of the value (COMP → USDC), not
the *amount*. In practice the numbers differ slightly (real slippage vs the 2%
haircut), which is exactly the small, bounded, unexploitable difference you want.

```solidity
// KeeperFacet
function harvest(address strategy) external onlyKeeperOrTimelock {
    uint256 before = IStrategy(strategy).totalLiquidity();
    IStrategy(strategy).harvest();      // claim rewards → swap to base → redeposit
    uint256 after_ = IStrategy(strategy).totalLiquidity();

    // sanity: harvest must not destroy value beyond tolerated slippage
    require(after_ >= before * (10_000 - maxHarvestSlippageBps) / 10_000, "HARVEST_LOSS");

    vs.strategyInfo[strategy].lastReported = after_;
    vs.strategyInfo[strategy].lastHarvest  = uint64(block.timestamp);
    emit Harvested(strategy, before, after_);
}
```

---

<a name="s9"></a>
## §9 · Share accounting

### 9.1 The formula

```
                       totalShares + 10^OFFSET
   shares = assets × ─────────────────────────────
                       totalLiquidity + 1

                       totalLiquidity + 1
   assets = shares × ─────────────────────────────
                       totalShares + 10^OFFSET
```

> **pps convention, stated once.** Throughout this document
> `pps = totalLiquidity_in_base_units / (totalShares / 10^OFFSET)`. It equals
> **exactly 1.000000 at genesis** and rises from there, so "pps = 1.0172419" reads
> directly as "+1.72% since launch". Shares are raw internal units; dividing by
> `10^OFFSET` converts them to *share-units*, which is the scale pps is quoted
> against. Getting this wrong by a factor of `10^OFFSET` is the single easiest
> mistake to make when reading these examples.

`10^OFFSET` (OFFSET=6) is a **virtual share** count. `+1` is a virtual asset. Both
exist to kill the **first-depositor inflation attack**:

```
   WITHOUT the offset:
   ────────────────────────────────────────────────────────────────
   1. Mallory deposits 1 wei         → gets 1 share.  totalShares=1
   2. Mallory DONATES 10,000 USDC directly to the vault (transfer, no deposit)
                                     → totalLiquidity = 10,000.000001
   3. Alice deposits 10,000 USDC
      shares = 10,000 × 1 / 10,000.000001 = 0.999... → rounds to 0
                                     → ALICE GETS ZERO SHARES
   4. Mallory redeems her 1 share    → gets the whole 20,000. 
   
   WITH offset=6:
   ────────────────────────────────────────────────────────────────
   1. Mallory deposits 1 wei         → shares = 1 × 10^6 / 1 = 1,000,000
   2. Mallory donates 10,000 USDC    → totalLiquidity = 10,000.000001
   3. Alice deposits 10,000 USDC
      shares = 10,000e6 × (1e6 + 1e6) / (10,000.000001e6 + 1)
             ≈ 2,000,000  → Alice gets real shares
   4. Mallory's 1e6 shares are now 1/3 of supply... but she donated 10,000
      to get there. She LOST money. Attack is not profitable.
```

The offset makes the attack cost more than it pays. That's the whole trick.

### 9.2 The v3 bug: pricing against the wrong base

Found and fixed during the v3 spike. It's subtle enough to restate:

```
   The vault receives the tokens BEFORE the share math runs.
   So totalLiquidity() ALREADY INCLUDES the incoming deposit.

   WRONG:                                   RIGHT:
   ─────────────────────────                ─────────────────────────
   transfer 10,000 in                       transfer 10,000 in
   totalLiquidity() = 10,000                totalLiquidity() = 10,000
   shares = 10,000 × 1e6 / 10,001           prior = 10,000 - 10,000 = 0
          ≈ 1,000                           shares = 10,000 × 1e6 / (0+1)
          ← FIRST DEPOSITOR GETS 1,000             = 10,000,000,000
            instead of 10,000,000,000               ← correct
```

```solidity
library LibShares {
    /// @dev Deposit-time mint. Assets are ALREADY in the vault, so subtract them
    ///      to price against the PRE-deposit base. This is not optional.
    function convertToSharesOnDeposit(uint256 assets) internal view returns (uint256) {
        VaultStorage storage vs = LibVaultStorage.s();
        uint256 prior = totalLiquidity() - assets;      // ← the fix
        return (assets * (vs.totalShares + 10 ** OFFSET)) / (prior + 1);
    }

    /// @dev Post-deposit conversions (withdraw, views) use the live base.
    function convertToShares(uint256 assets) internal view returns (uint256) {
        VaultStorage storage vs = LibVaultStorage.s();
        return (assets * (vs.totalShares + 10 ** OFFSET)) / (totalLiquidity() + 1);
    }

    function convertToAssets(uint256 shares) internal view returns (uint256) {
        VaultStorage storage vs = LibVaultStorage.s();
        return (shares * (totalLiquidity() + 1)) / (vs.totalShares + 10 ** OFFSET);
    }
}
```

### 9.3 Worked example — verified arithmetic

Using the §8.7 vault (`totalLiquidity = 1,013,848`), with an existing
`totalShares = 981,000,000,000,000`.

```
  Alice deposits 10,000 USDC gross.
  ─────────────────────────────────────────────────────────────────
  entry fee    = 10,000 × 30bps / 10,000  =        30.00 USDC
  net credited = 10,000 − 30              =      9,970.00 USDC

  pps before   = 1,013,848e6 / (981,000,000,000,000 / 1e6)
               = 1,033.4842  base-units per share-unit
               (pps = 1.0 at genesis; this vault has appreciated)

  shares       = 9,970e6 × (981,000,000,000,000 + 1,000,000)
                 ─────────────────────────────────────────────
                        (1,013,848e6 + 1)

               = 9,646,978,649,620  shares
  ─────────────────────────────────────────────────────────────────
  Position #N:  shares    = 9,646,978,649,620
                costBasis =         9,970.00 USDC
  
  Check: (9,646,978,649,620 / 1e6) × 1,033.4842 / 1e6 = 9,970.00 ✓
```

### 9.4 Yield reaches the user with zero reward logic

```
   t=0    totalLiquidity = 1,000,000    totalShares = S    pps = 1,000,000/S
   
          ... strategies earn. COMP accrues. Interest accrues. ...
   
   t=90d  totalLiquidity = 1,050,000    totalShares = S    pps = 1,050,000/S
                          ▲▲▲▲▲▲▲▲▲                        ▲▲▲▲▲▲▲▲▲▲▲
                          liquidity grew                   pps grew 5%
                          share count didn't
   
   Every position's shares are now worth 5% more. Automatically.
   No accrual. No claim. No transaction.
```

**Strategy yield and ARTHA rewards are completely different mechanisms.** Yield is
passive (pps rises). ARTHA is an accumulator that must be settled. Don't confuse
them.

---

<a name="s10"></a>
## §10 · The deposit → end-of-day-deploy flow

### 10.1 The full sequence

```
 ┌──── INSTANT (user's transaction) ────────────────────────────────────┐
 │                                                                       │
 │  1. user (or anyone) calls vault.deposit(tokenId, 10,000)            │
 │       │                                                               │
 │  2.   ├─► pull 10,000 USDC from msg.sender                           │
 │       │                                                               │
 │  3.   ├─► entry fee 30 → accruedFees;  net = 9,970                   │
 │       │                                                               │
 │  4.   ├─► LibArtha.settle(OWNER)      ← bank at OLD principal        │
 │       │                                                               │
 │  5.   ├─► shares = convertToSharesOnDeposit(9,970)                   │
 │       │   positions[id].shares    += shares                          │
 │       │   positions[id].costBasis += 9,970                           │
 │       │                                                               │
 │  6.   ├─► userPrincipalNorm[OWNER] += 9,970e12   (→18dp)             │
 │       │   LibArtha.recheckpoint(OWNER)                               │
 │       │                                                               │
 │  7.   ├─► rewardSystem.notifyDeposit(vault, OWNER, 9,970)            │
 │       │   referralVault.notifyDeposit(vault, OWNER, 9,970)           │
 │       │                                                               │
 │  8.   └─► 9,970 USDC sits IDLE. NOT deployed. Tx ends.               │
 │                                                                       │
 │      ✓ user has shares immediately                                   │
 │      ✓ user earns pps growth immediately (idle counts in liquidity)  │
 │      ✓ user earns ARTHA immediately                                  │
 │      ✓ cost ≈ 120k gas — no external protocol touched                │
 └───────────────────────────────────────────────────────────────────────┘
                                    │
                          ... more deposits all day ...
                                    │
 ┌──── END OF DAY (keeper's transaction) ───────────────────────────────┐
 │                                                                       │
 │  9.  keeper calls vault.deployIdle()                                 │
 │        │                                                              │
 │ 10.    ├─► deployable = idle − bufferFloor                           │
 │        │                                                              │
 │ 11.    ├─► for each strategy:                                        │
 │        │      amt = deployable × targetBps / 10,000                  │
 │        │      approve(strategy, amt)                                 │
 │        │      strategy.deposit(amt)   ← strategy supplies to venue   │
 │        │                                                              │
 │ 12.    └─► idle → strategy positions. totalLiquidity UNCHANGED.      │
 │                                                                       │
 │      ✓ ONE tx amortises the venue-deposit gas across ALL depositors  │
 │      ✓ nobody's shares changed — deploy is value-neutral             │
 └───────────────────────────────────────────────────────────────────────┘
```

### 10.2 Why idle doesn't hurt anyone

The question everyone asks: *"if my money sits idle all day, am I losing yield?"*

**No — and the reason is important.** Idle base token is counted in `totalLiquidity`
at exactly its face value. Deploying it swaps `10,000 idle` for `10,000 of strategy
position`. Total is identical. **Deployment is value-neutral by construction.**

```
   BEFORE deployIdle()                    AFTER deployIdle()
   ────────────────────────               ────────────────────────
   idle              80,000               idle               8,000
   compound         524,848               compound         560,848
   aave             409,000               aave             445,000
   ────────────────────────               ────────────────────────
   TOTAL          1,013,848               TOTAL          1,013,848  ← same
   totalShares            S               totalShares            S  ← same
   pps       1,013,848 / S               pps       1,013,848 / S  ← same
```

What you *do* lose is the *yield* the idle capital would have earned during that
window. But that loss is shared by every holder pro-rata via pps, and it is the price
of the gas saving. If you deployed on every deposit:

```
   Per-deposit deploy:  120k (deposit) + 250k (Aave supply) + 200k (Comet supply)
                        = ~570k gas PER DEPOSITOR
   
   Batched:             120k (deposit) per depositor
                        + ~450k (one deployIdle) split across ALL of them
   
   100 depositors:      per-deposit  = 57,000,000 gas
                        batched      = 12,450,000 gas    → 78% cheaper
```

### 10.3 What Yearn actually does (and why we differ deliberately)

Worth being precise here, because it's a common misconception:

| | **Yearn V3** | **Artha v4** |
|---|---|---|
| Deposit lands | **Idle.** Never touches a strategy. | **Idle.** Same. |
| Deploy trigger | **Event-driven.** A bot calls `update_debt(strategy, target)` whenever allocation drifts. No schedule. | **Time-driven.** Keeper calls `deployIdle()` end-of-day. |
| Deploy granularity | Per-strategy: `update_debt` sets one strategy's target debt. | All-strategies: `deployIdle` splits idle by targets. |
| Buffer | `minimum_total_idle` (absolute amount) | `minBufferBps` (% of total) |
| Withdraw shortfall | Walks `default_queue`, respects `max_loss` | Walks `strategies[]` in order |

**The anti-front-running property comes from idle-on-deposit alone, not from the
batching cadence.** Yearn gets it for free the same way we do. Our end-of-day cadence
is purely a gas/capital-efficiency choice — the contract doesn't know or care what
time it is.

**Recommended evolution:** add `updateDebt(strategy, targetAssets)` alongside
`deployIdle()`. It gives you Yearn's per-strategy granularity and makes partial
rebalances far cheaper than the current unwind-everything `rebalance()`:

```solidity
// KeeperFacet — the Yearn-shaped primitive
function updateDebt(address strategy, uint256 targetAssets) external onlyKeeperOrTimelock {
    uint256 current = IStrategy(strategy).totalLiquidity();
    if (targetAssets > current) {
        uint256 add = targetAssets - current;
        uint256 available = _deployableIdle();
        if (add > available) add = available;
        _supplyTo(strategy, add);
    } else if (targetAssets < current) {
        _freeFrom(strategy, current - targetAssets);
    }
}
```

### 10.4 deployIdle in full

```solidity
// KeeperFacet
function deployIdle() external onlyKeeperOrTimelock whenNotEmergency {
    VaultStorage storage vs = LibVaultStorage.s();
    uint256 deployable = _deployableIdle(vs);
    if (deployable == 0) { emit Deployed(0); return; }

    address[] memory strats = vs.strategies;
    for (uint256 i; i < strats.length; i++) {
        uint16 bps = vs.strategyInfo[strats[i]].targetBps;
        if (bps == 0) continue;
        uint256 amt = deployable * bps / BPS;
        if (amt == 0) continue;
        IERC20(vs.asset).forceApprove(strats[i], amt);
        IStrategy(strats[i]).deposit(amt);
    }
    emit Deployed(deployable);
}

/// @dev Idle above the buffer floor. Buffer is % of TOTAL liquidity.
function _deployableIdle(VaultStorage storage vs) internal view returns (uint256) {
    uint256 idle  = IERC20(vs.asset).balanceOf(address(this));
    uint256 floor = totalLiquidity() * vs.minBufferBps / BPS;
    return idle > floor ? idle - floor : 0;
}
```

### 10.5 Worked example — 50/40/10 with a 10% buffer

```
   Vault holds 100,000 idle. targets: Aave 50%, Compound 40%. buffer 10%.
   
   totalLiquidity = 100,000  (all idle, nothing deployed yet)
   bufferFloor    = 100,000 × 10% = 10,000    ← must stay liquid
   deployable     = 100,000 − 10,000 = 90,000
   
   ┌────────────────────────────────────────────────────────────┐
   │ Aave      = 90,000 × 5000/10,000 = 45,000                  │
   │ Compound  = 90,000 × 4000/10,000 = 36,000                  │
   │ undeployed= 90,000 × 1000/10,000 =  9,000  ← targets sum   │
   │                                              to 9000 not   │
   │                                              10000         │
   └────────────────────────────────────────────────────────────┘
   
   AFTER:
     Aave         45,000
     Compound     36,000
     idle         19,000   ← 10,000 buffer + 9,000 unallocated
     ─────────────────────
     TOTAL       100,000   ← unchanged ✓
```

> **Read the targets carefully.** They're a % of *deployable*, and they **do not have
> to sum to 100%.** Leaving them at 90% keeps an extra 10% of deployable liquid on
> top of the buffer. That's a deliberate design knob: the buffer is the *floor*, the
> target gap is *discretionary* extra liquidity.


---

<a name="s11"></a>
## §11 · Withdrawal + profit-only fees

### 11.1 The rule

> **Fee is charged on profit only. Never on principal. Never when underwater.**

"Profit" means: *value above the cost basis of the shares being withdrawn.*

### 11.2 Cost basis: what it is and why it must exist

```
   Position #4
   ─────────────────────────────────────────────────────
   costBasis = 9,970    ← the NET base token ever credited to this position
   shares    = 9,646,978,649,620
   
   value now = shares × pps = 11,094.01
   
   profit    = 11,094.01 − 9,970.00 = 1,124.01     ← ONLY this is taxable
   principal =              9,970.00               ← NEVER touched by the fee
```

Without a stored `costBasis`, you cannot compute profit. You'd have to either
(a) charge a fee on the whole withdrawal, which taxes principal — unacceptable, or
(b) charge on pps growth since deposit, which requires storing the entry pps anyway —
same storage, worse math (it breaks on multiple deposits at different prices).

`costBasis` is the simplest correct answer: **it accumulates the net credited amount
and decrements proportionally on exit.**

### 11.3 The math, in full

```
   Given:  withdrawing `assets` from a position worth `value` with basis `basis`
   
   ┌─────────────────────────────────────────────────────────────────┐
   │  fraction  = assets / value           (what % of the position)  │
   │  basisUsed = basis × fraction         (basis consumed pro-rata) │
   │  profit    = assets − basisUsed       (if > 0, else 0)          │
   │  fee       = profit × perfFeeBps / 10,000                       │
   │  payout    = assets − fee                                       │
   │                                                                 │
   │  basis' = basis − basisUsed          ← remaining basis          │
   └─────────────────────────────────────────────────────────────────┘
```

Why pro-rata basis consumption is the correct rule: it keeps
`basis / value` constant across a partial exit, so a user cannot game the fee by
salami-slicing their withdrawal. Withdrawing 40% four times costs exactly the same
as withdrawing 100% once. **That property is worth verifying in a fuzz test.**

### 11.4 Worked examples — verified arithmetic

**Case A — full exit in profit**

```
   basis     =  9,970.00
   shares    =  9,646,978,649,620
   pps       =  1,150.0000         (grew from 1,033.4842)
   value     = (9,646,978,649,620 / 1e6) × 1,150.0 / 1e6 = 11,094.03
   
   fraction  = 11,094.01 / 11,094.01 = 1.00
   basisUsed =  9,970.00 × 1.00      =  9,970.00
   profit    = 11,094.01 − 9,970.00  =  1,124.01
   fee (10%) =  1,124.01 × 0.10      =    112.40
   ───────────────────────────────────────────────
   USER RECEIVES                     = 10,981.61
   TREASURY GETS                     =    112.40
   
   The user keeps 100% of their 9,970 principal + 90% of their 1,124 profit.
```

**Case B — partial exit (40%)**

```
   value     = 11,094.01     basis = 9,970.00
   withdraw  =  4,437.61     (= 40% of value)
   
   fraction  =  4,437.61 / 11,094.01 = 0.40
   basisUsed =  9,970.00 × 0.40      = 3,988.00
   profit    =  4,437.61 − 3,988.00  =   449.61
   fee (10%) =    449.61 × 0.10      =    44.96
   ───────────────────────────────────────────────
   USER RECEIVES                     =  4,392.65
   
   REMAINING POSITION:
     basis   =  9,970.00 − 3,988.00  = 5,982.00
     value   = 11,094.01 − 4,437.61  = 6,656.40
     unrealised profit               =   674.40   ← untaxed until withdrawn ✓
   
   Check: 449.61 + 674.40 = 1,124.01 = the original total profit ✓
          Fee was charged on exactly the realised 40%. No double-count.
```

**Case C — underwater. No fee.**

```
   basis     =  9,970.00
   pps       =    950.0000      ← strategies lost money
   value     = (9,646,978,649,620 / 1e6) × 950.0 / 1e6 = 9,164.63
   
   fraction  = 1.00
   basisUsed = 9,970.00
   profit    = 9,164.62 − 9,970.00 = −805.38  →  clamped to 0
   fee       = 0 × 10%             = 0.00
   ───────────────────────────────────────────────
   USER RECEIVES                   = 9,164.62     ← ALL of it
   TREASURY GETS                   = 0.00
   
   The vault does not profit from the user's loss. This is non-negotiable.
```

**Case D — recovery after a loss (the high-water-mark question)**

```
   A user deposits 10,000 (basis 10,000). Value drops to 8,000. Recovers to 11,000.
   
   basis   = 10,000
   value   = 11,000
   profit  =  1,000        ← measured from BASIS, not from the 8,000 trough
   fee     =    100
   
   The user is NOT charged on the 8,000 → 10,000 recovery. That's not profit,
   that's getting their own money back. Cost-basis accounting gives you a
   per-position high-water mark for free.
```

### 11.5 Implementation

```solidity
// WithdrawFacet
function withdraw(uint256 tokenId, uint256 assets, address to)
    external
    nonReentrant
    whenNotEmergency
    returns (uint256 sharesBurned)
{
    VaultStorage storage vs = LibVaultStorage.s();
    address owner = vs.ownerOf[tokenId];
    require(msg.sender == owner, "NOT_OWNER");        // ← owner only (§6.4)
    require(assets > 0, "ZERO");
    require(to != address(0), "ZERO_ADDR");

    Position storage p = vs.positions[tokenId];

    // 1. bank ARTHA at the OLD principal, before basis changes
    LibArtha.settle(owner);

    // 2. how much of the position is this?
    uint256 value = LibShares.convertToAssets(p.shares);
    require(assets <= value, "EXCEEDS_POSITION");

    // 3. burn shares (round UP so the vault never leaks value)
    sharesBurned = LibShares.convertToShares(assets);
    if (LibShares.convertToAssets(sharesBurned) < assets) sharesBurned += 1;
    if (sharesBurned > p.shares) sharesBurned = p.shares;

    // 4. PROFIT-ONLY FEE
    uint256 basisUsed = p.costBasis * assets / value;   // pro-rata
    uint256 profit    = assets > basisUsed ? assets - basisUsed : 0;
    uint256 fee       = profit * vs.perfFeeBps / BPS;
    uint256 payout    = assets - fee;
    vs.accruedFees += fee;

    // 5. free liquidity from strategies if the buffer is short
    _ensureLiquidity(vs, assets);

    // 6. update position
    p.shares    -= sharesBurned;
    p.costBasis -= basisUsed;
    vs.totalShares -= sharesBurned;

    // 7. shrink the OWNER's ARTHA principal, re-checkpoint
    uint256 normDown = basisUsed * vs.scale;
    if (normDown > vs.userPrincipalNorm[owner]) normDown = vs.userPrincipalNorm[owner];
    vs.userPrincipalNorm[owner] -= normDown;
    vs.totalPrincipalNorm       -= normDown;
    LibArtha.recheckpoint(owner);

    // 8. notify both reward systems
    IRewardSystem(vs.rewardSystem).notifyWithdraw(address(this), owner, basisUsed);
    IReferralVault(vs.referralVault).notifyWithdraw(address(this), owner, basisUsed);

    // 9. pay
    IERC20(vs.asset).safeTransfer(to, payout);
    emit Withdrawn(tokenId, owner, to, assets, fee, payout, sharesBurned);
}
```

> **Note step 7 uses `basisUsed`, not `assets`.** The ARTHA reward principal tracks
> *deposited capital*, not *current value*. If you withdraw 11,094 from a 9,970 basis,
> your reward principal drops by 9,970 — because that's what you actually put in.
> Using `assets` here would let a profitable user drive their reward principal
> negative. This is exactly the kind of bug that only shows up after a bull run.

### 11.6 Freeing liquidity

```solidity
function _ensureLiquidity(VaultStorage storage vs, uint256 need) internal {
    uint256 idle = IERC20(vs.asset).balanceOf(address(this));
    if (idle >= need) return;                       // buffer covers it — done

    address[] memory strats = vs.strategies;
    for (uint256 i; i < strats.length; i++) {
        uint256 have = IERC20(vs.asset).balanceOf(address(this));
        if (have >= need) break;
        uint256 short = need - have;
        IStrategy s = IStrategy(strats[i]);
        uint256 avail = s.maxWithdraw();
        if (avail == 0) continue;
        s.withdraw(avail >= short ? short : avail);
    }
    require(IERC20(vs.asset).balanceOf(address(this)) >= need, "ILLIQUID");
}
```

```
   ┌──────────────────────────────────────────────────────────────┐
   │  Withdrawal waterfall                                        │
   │                                                              │
   │   need 8,000                                                 │
   │      │                                                       │
   │      ├─ idle buffer has 1,900?  → take 1,900, short 6,100    │
   │      │                                                       │
   │      ├─ strategy[0] Aave: maxWithdraw 45,000                 │
   │      │     → pull 6,100. short = 0. STOP.                    │
   │      │                                                       │
   │      └─ strategy[1] never touched (loop breaks)              │
   └──────────────────────────────────────────────────────────────┘
```

For RWA / queued-withdrawal strategies, `maxWithdraw()` returns what's *instantly*
available (often 0), so the loop skips them and pulls from liquid venues first. That's
the correct behaviour and it's why the buffer exists.

---

<a name="s12"></a>
## §12 · Fee model in full

### 12.1 Two fees, two purposes

```
╔═══════════════════════════════════════════════════════════════════════════╗
║  ENTRY FEE — "gas + maintenance"                                          ║
║  ─────────────────────────────────────────────────────────────────────    ║
║  When:    on every deposit                                                ║
║  Base:    gross deposit amount                                            ║
║  Rate:    entryFeeBps (e.g. 30 = 0.30%)                                   ║
║  Purpose: pays the keeper's gas (deployIdle, harvest, rebalance)          ║
║           + protocol maintenance                                          ║
║  Effect:  costBasis = gross − fee.  The user's basis is the NET.          ║
╠═══════════════════════════════════════════════════════════════════════════╣
║  PERFORMANCE FEE — "share of the upside"                                  ║
║  ─────────────────────────────────────────────────────────────────────    ║
║  When:    on withdrawal, ONLY if the withdrawn slice is in profit         ║
║  Base:    profit above cost basis — NEVER principal                       ║
║  Rate:    perfFeeBps (e.g. 1,000 = 10% of profit)                         ║
║  Purpose: aligns the protocol with users — we earn when you earn          ║
║  Effect:  zero fee if flat or down. Zero fee on the principal, ever.      ║
╚═══════════════════════════════════════════════════════════════════════════╝
```

### 12.2 Why the entry fee reduces cost basis (and must)

```
   Deposit 10,000 gross. Fee 30. Net 9,970.
   
   costBasis = 9,970   ← NET, not gross
   
   WHY? Because 9,970 is what actually bought shares. If basis were 10,000:
   
      value = 9,970 (immediately after deposit, before any yield)
      basis = 10,000
      "profit" = −30
      
      → the user would be permanently 30 "underwater" and would pay
        zero performance fee on their first 30 of real profit.
        The entry fee would silently become a 30-unit performance-fee credit.
   
   Setting basis = net keeps the two fees independent. Which is what you want.
```

### 12.3 Full lifecycle — verified arithmetic

```
   ═══════════════════════════════════════════════════════════════════
    Alice: deposit 10,000 → hold 90 days → withdraw everything
   ═══════════════════════════════════════════════════════════════════
   
   DAY 0 — DEPOSIT
     gross                          10,000.00
     entry fee (30 bps)                 30.00  ──► treasury
     ──────────────────────────────────────────
     net credited                    9,970.00
     costBasis                       9,970.00
     shares minted           9,646,978,649,620
   
   DAY 0..90 — strategies earn. pps: 1,033.4842 → 1,150.0000 (+11.27%)
     
   DAY 90 — WITHDRAW ALL
     value          = shares × pps  = 11,094.01
     basisUsed      = 9,970 × 100%  =  9,970.00
     profit         = 11,094 − 9,970 = 1,124.01
     perf fee (10%) = 1,124.01 × 0.10 =  112.40  ──► treasury
     ──────────────────────────────────────────
     ALICE RECEIVES                 = 10,981.61
   
   ═══════════════════════════════════════════════════════════════════
    SCOREBOARD
   ═══════════════════════════════════════════════════════════════════
     Alice in           10,000.00
     Alice out          10,981.61
     Alice net          +  981.61     = +9.82% over 90 days
     
     Treasury: entry     30.00
             + perf     112.40
             ─────────────────
             total      142.40        = 1.42% of the deposit
                                      = 12.67% of the gross profit (1,124.01)
     
     PLUS: Alice earned 1,250 ARTHA (§18) on top. Not shown above.
   ═══════════════════════════════════════════════════════════════════
```

### 12.4 Fee collection

Fees accrue as a **counter**, not a transfer. Sweeping is a separate keeper call —
this keeps the user's gas cost down (no extra transfer per deposit) and lets the
treasury batch.

```solidity
// AdminFacet
uint256 public constant MAX_ENTRY_FEE_BPS = 100;    // 1.00% hard ceiling
uint256 public constant MAX_PERF_FEE_BPS  = 2_000;  // 20% hard ceiling

function setFees(uint16 entryBps, uint16 perfBps) external onlyTimelock {
    require(entryBps <= MAX_ENTRY_FEE_BPS, "ENTRY_TOO_HIGH");
    require(perfBps  <= MAX_PERF_FEE_BPS,  "PERF_TOO_HIGH");
    VaultStorage storage vs = LibVaultStorage.s();
    vs.entryFeeBps = entryBps;
    vs.perfFeeBps  = perfBps;
    emit FeesUpdated(entryBps, perfBps);
}

function sweepFees() external {
    VaultStorage storage vs = LibVaultStorage.s();
    uint256 amt = vs.accruedFees;
    require(amt > 0, "NOTHING");
    vs.accruedFees = 0;
    IERC20(vs.asset).safeTransfer(vs.feeRecipient, amt);
    emit FeesSwept(vs.feeRecipient, amt);
}
```

> **The hard ceilings are a governance-capture defence.** They're `constant`, not
> storage. Even a fully compromised timelock cannot set a 100% fee — it would have to
> `diamondCut` a new AdminFacet, which is a visible, delayed, on-chain action that
> the community can see coming. Constants make the attack loud.

**One important accounting detail:** `accruedFees` sits in the vault as base token,
so it's counted by `IERC20(asset).balanceOf(address(this))` inside `totalLiquidity()`.
That means accrued fees are inflating pps until swept.

Two options:
1. **Subtract it** — `totalLiquidity() = idle − accruedFees + Σ strategies`. Exact,
   but every accounting read pays for the subtraction.
2. **Sweep often** — keep `accruedFees` near zero so the distortion is negligible.

**Recommendation: do both.** Subtract in `totalLiquidity()` (correctness first) *and*
sweep on a keeper schedule (hygiene). The subtraction is one `SLOAD` and one `SUB`;
correctness is worth 2,100 gas.

```solidity
function totalLiquidity() public view returns (uint256 total) {
    VaultStorage storage vs = LibVaultStorage.s();
    uint256 idle = IERC20(vs.asset).balanceOf(address(this));
    total = idle > vs.accruedFees ? idle - vs.accruedFees : 0;   // ← fees aren't users'
    address[] memory strats = vs.strategies;
    for (uint256 i; i < strats.length; i++) {
        total += IStrategy(strats[i]).totalLiquidity();
    }
}
```


---

# PART IV — STRATEGIES

<a name="s13"></a>
## §13 · Strategy interface + the four yield shapes

### 13.1 The interface

Every strategy, whatever it does internally, presents exactly this surface:

```solidity
interface IStrategy {
    // ── identity ──
    function asset() external view returns (address);   // must equal vault's base token
    function vault() external view returns (address);   // the ONE vault allowed to call

    // ── the number that matters (§8) ──
    function totalLiquidity() external view returns (uint256);

    // ── capital movement (vault-only) ──
    function deposit(uint256 assets) external;
    function withdraw(uint256 assets) external returns (uint256 withdrawn);
    function maxWithdraw() external view returns (uint256);   // instantly available

    // ── keeper ops ──
    function harvest() external;      // claim rewards → swap to base → redeposit
    function tend() external;         // optional: rebalance internals, no harvest
    function emergencyExit() external; // unwind everything to base, vault-only
}
```

Nine functions. `totalLiquidity()` is the one that carries all the weight.

### 13.2 The four shapes of yield

**This taxonomy is the key to the whole strategy layer.** Every yield source in DeFi
delivers value in one of exactly four shapes. Once you can classify a protocol, you
know what its adapter has to do.

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║  SHAPE 1 — REBASE                                                             ║
║  ─────────────────────────────────────────────────────────────────────────    ║
║  Your token BALANCE grows. 100 aUSDC becomes 105 aUSDC.                       ║
║                                                                               ║
║    balanceOf(me):  100 ──────► 105                                            ║
║    price:            1 ──────►   1                                            ║
║                                                                               ║
║  Protocols: Aave V3 (aTokens), Compound V3 (Comet balance)                    ║
║  totalLiquidity() = token.balanceOf(this)          ← trivial                  ║
║  Reward token?  Aave: no.  Compound: YES (COMP) → also Shape 3                ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║  SHAPE 2 — EXCHANGE-RATE APPRECIATION                                         ║
║  ─────────────────────────────────────────────────────────────────────────    ║
║  Your BALANCE is fixed. The PRICE per unit grows.                             ║
║                                                                               ║
║    balanceOf(me):  100 ──────► 100                                            ║
║    price:         1.00 ──────► 1.05                                           ║
║                                                                               ║
║  Protocols: sUSDS, sDAI, sUSDe, wstETH, rETH, any ERC-4626                    ║
║  totalLiquidity() = shares × pricePerShare        ← one call                  ║
║  Reward token?  No. This is why they're the easiest.                          ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║  SHAPE 3 — CLAIMABLE EMISSIONS                                                ║
║  ─────────────────────────────────────────────────────────────────────────    ║
║  A SEPARATE token accrues. You must claim it and sell it.                     ║
║                                                                               ║
║    base position:  100 ──────► 100                                            ║
║    COMP pending:     0 ──────►   3       ← different token! needs pricing     ║
║                                                                               ║
║  Protocols: Compound (COMP), Curve (CRV), Convex (CVX+CRV), Aerodrome (AERO)  ║
║  totalLiquidity() = base + (rewardQty × oracle × haircut)   ← §8              ║
║  This is the shape that breaks naive aggregators.                             ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║  SHAPE 4 — DISCOUNT TO PAR                                                    ║
║  ─────────────────────────────────────────────────────────────────────────    ║
║  Bought below par. Redeems at par at maturity. The gap IS the yield.          ║
║                                                                               ║
║    PT price:      0.95 ──────► 1.00 at maturity                               ║
║    (linear-ish interpolation in between)                                      ║
║                                                                               ║
║  Protocols: Pendle PT                                                         ║
║  totalLiquidity() = qty × interpolate(now, maturity)                          ║
║  Reward token?  No, but the valuation is time-dependent.                      ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

**Mixing is normal.** Compound USDC is **Shape 1 + Shape 3**: the Comet balance
rebases (interest in USDC) *and* COMP accrues separately. Curve+Convex is **Shape 3
only** (LP token doesn't rebase; fees accrue into the LP's virtual price — actually
Shape 2 + Shape 3). Reading a protocol correctly means asking *both* questions:

1. Does my position's value grow on its own? (Shape 1 or 2)
2. Does a separate token accrue that I must claim and sell? (Shape 3)

### 13.3 Shape → implementation, at a glance

| Shape | `totalLiquidity()` | `_pendingRewardsInBase()` | Difficulty |
|---|---|---|---|
| **1 · Rebase** | `token.balanceOf(this)` | usually `0` | Trivial |
| **2 · Exchange rate** | `vault.convertToAssets(shares)` | `0` | Trivial |
| **3 · Emissions** | base + priced rewards | `qty × oracle × haircut` | **Hard** — needs oracle + swap |
| **4 · Discount** | `qty × interpolate(t)` | `0` | Medium — time-dependent |

**The whole difficulty of the strategy layer is Shape 3.** Shapes 1, 2, and 4 need no
oracle, no swap adapter, no haircut. Shape 3 needs all three. Which is why:

> **Build order: ship every Shape-1 and Shape-2 strategy first. They need no
> infrastructure. Then build the oracle + swap adapter once, and unlock all of
> Shape 3 at the same time.**

---

<a name="s14"></a>
## §14 · Why one mechanism needs many contracts

**This is change #11, and it's the least obvious one in the document.**

### 14.1 The naive assumption

> "Compound is Compound. Write one `CompoundStrategy`, pass the market address in the
> constructor, deploy it for USDC and WETH. Done."

**This is wrong**, and the reason is worth understanding precisely.

### 14.2 What actually differs

```
╔════════════════════════════════════════════════════════════════════════════════╗
║               COMPOUND V3 — USDC MARKET vs WETH MARKET                         ║
╠═══════════════════════╤════════════════════════╤═══════════════════════════════╣
║                       │ cUSDCv3                │ cWETHv3                       ║
╠═══════════════════════╪════════════════════════╪═══════════════════════════════╣
║ base token            │ USDC                   │ WETH                          ║
║ interest paid in      │ USDC       (= base ✓)  │ WETH        (= base ✓)        ║
║ reward token          │ COMP                   │ COMP                          ║
║ ─────────────────────────────────────────────────────────────────────────────  ║
║ HARVEST SWAP ROUTE    │ COMP ──► USDC          │ COMP ──► WETH                 ║
║                       │                        │                               ║
║                       │ COMP/WETH (Uni V3 0.3%)│ COMP/WETH (Uni V3 0.3%)       ║
║                       │      ↓                 │      ↓                        ║
║                       │ WETH/USDC (Uni V3 0.05%)│     DONE (1 hop)             ║
║                       │      ↓                 │                               ║
║                       │    DONE (2 hops)       │                               ║
║ ─────────────────────────────────────────────────────────────────────────────  ║
║ oracle needed         │ COMP/USD               │ COMP/ETH                      ║
║ slippage tolerance    │ tight (stable)         │ loose (volatile)              ║
║ decimals              │ 6                      │ 18                            ║
║ dust threshold        │ ~1 USDC                │ ~0.0003 WETH                  ║
╚═══════════════════════╧════════════════════════╧═══════════════════════════════╝
```

**The mechanism is identical. The swap path is not.** And the swap path is code:
route encoding, slippage bounds, oracle feed, dust threshold, decimals.

### 14.3 The two ways to handle it

```
   OPTION A — ONE CONTRACT, PARAMETERISED (rejected)
   ══════════════════════════════════════════════════════════════
   
   contract CompoundStrategy {
       bytes  public swapRoute;        // set by governance per deployment
       uint16 public slippageBps;
       address public rewardOracle;
       ...
       function harvest() external {
           uint256 comp = _claim();
           // decode a route from storage, hope it's right
           swapAdapter.swap(COMP, asset, comp, swapRoute, slippageBps);
       }
   }
   
   ✗ swapRoute is opaque bytes. An auditor cannot verify it.
   ✗ A wrong route = silent loss of every harvest.
   ✗ Changing the route is a storage write — no timelock visibility into
     what the new bytes actually DO.
   ✗ One bug in the shared contract hits every market at once.
   ✓ Cheaper to deploy. (This is the only advantage.)


   OPTION B — ONE CONTRACT PER MARKET (chosen)
   ══════════════════════════════════════════════════════════════
   
   contract CompoundUsdcStrategy is BaseCompoundStrategy {
       function _swapRewardsToBase(uint256 compQty) internal override {
           // COMP → WETH → USDC, explicit, readable, auditable
           swapAdapter.exactInput(
               abi.encodePacked(COMP, uint24(3000), WETH, uint24(500), USDC),
               compQty,
               _minOut(compQty, 100)      // 1% slippage — stable leg
           );
       }
   }
   
   contract CompoundWethStrategy is BaseCompoundStrategy {
       function _swapRewardsToBase(uint256 compQty) internal override {
           // COMP → WETH. One hop. Different tolerance.
           swapAdapter.exactInput(
               abi.encodePacked(COMP, uint24(3000), WETH),
               compQty,
               _minOut(compQty, 300)      // 3% slippage — volatile leg
           );
       }
   }
   
   ✓ The route is CODE. Reviewable, diffable, testable.
   ✓ A USDC-route bug cannot touch the WETH vault.
   ✓ Changing a route = new deployment + timelock + explicit migration.
   ✓ Each can tune slippage/dust for its own volatility profile.
   ✗ More deployments. (~2M gas each. This is nothing.)
```

**The deciding argument:** a wrong swap route doesn't revert — it silently sells your
COMP for less than it's worth, every harvest, forever. It's a *quiet* loss. Quiet
losses must be caught by review, and review requires readable code. `bytes public
swapRoute = 0xc00e94...0001f4...` is not readable code.

### 14.4 The shared-base pattern

Share the mechanism, specialise the route:

```solidity
// ── shared: everything that is genuinely identical ──
abstract contract BaseCompoundStrategy is BaseStrategy {
    IComet        public immutable comet;
    ICometRewards public immutable cometRewards;
    IERC20        public immutable COMP;

    function _investedPlusInterest() internal view override returns (uint256) {
        return comet.balanceOf(address(this));       // identical for every market
    }

    function _depositToVenue(uint256 amount) internal override {
        IERC20(asset).forceApprove(address(comet), amount);
        comet.supply(asset, amount);                 // identical
    }

    function _withdrawFromVenue(uint256 amount) internal override returns (uint256) {
        comet.withdraw(asset, amount);               // identical
        return amount;
    }

    function harvest() external override onlyKeeperOrVault {
        cometRewards.claim(address(comet), address(this), true);
        uint256 compQty = COMP.balanceOf(address(this));
        if (compQty < _dustThreshold()) return;       // ← market-specific
        _swapRewardsToBase(compQty);                  // ← market-specific
        uint256 got = IERC20(asset).balanceOf(address(this));
        if (got > 0) _depositToVenue(got);            // compound it
    }

    // ── the two things that genuinely differ ──
    function _swapRewardsToBase(uint256 compQty) internal virtual;
    function _dustThreshold() internal view virtual returns (uint256);
}

// ── specialised: 20 lines each ──
contract CompoundUsdcStrategy is BaseCompoundStrategy {
    function _swapRewardsToBase(uint256 q) internal override { /* COMP→WETH→USDC */ }
    function _dustThreshold() internal pure override returns (uint256) { return 1e6; } // 1 USDC
}

contract CompoundWethStrategy is BaseCompoundStrategy {
    function _swapRewardsToBase(uint256 q) internal override { /* COMP→WETH */ }
    function _dustThreshold() internal pure override returns (uint256) { return 3e14; } // 0.0003 WETH
}
```

**~95% of the code is shared. ~5% is specialised. And the 5% is exactly the part that
must be reviewed per-market.** That's the whole point of the split.

### 14.5 The deployment matrix

```
   ┌─────────────────┬──────────────────────────┬────────────────────────────┐
   │ MECHANISM       │ CONTRACTS DEPLOYED       │ WHY SEPARATE               │
   ├─────────────────┼──────────────────────────┼────────────────────────────┤
   │ Aave V3 lend    │ AaveUsdcStrategy         │ no reward token → could be │
   │                 │ AaveWethStrategy         │ one contract, but keep it  │
   │                 │ AaveDaiStrategy          │ consistent + per-asset caps│
   ├─────────────────┼──────────────────────────┼────────────────────────────┤
   │ Compound V3     │ CompoundUsdcStrategy     │ COMP→USDC = 2 hops         │
   │                 │ CompoundWethStrategy     │ COMP→WETH = 1 hop          │
   ├─────────────────┼──────────────────────────┼────────────────────────────┤
   │ ERC-4626 wrap   │ ERC4626Wrapper (× N)     │ SAME contract, different   │
   │                 │   → sUSDS, sUSDe, sDAI   │ ctor arg. No reward token, │
   │                 │   → wstETH, nested vault │ no swap → nothing differs. │
   ├─────────────────┼──────────────────────────┼────────────────────────────┤
   │ Curve + Convex  │ CurveConvex3PoolStrategy │ each pool = different LP,  │
   │                 │ CurveConvexTriCryptoStr… │ gauge, reward set, route   │
   └─────────────────┴──────────────────────────┴────────────────────────────┘
```

> **Note the ERC-4626 row.** It's the exception that proves the rule: those *can*
> share one contract, because Shape-2 strategies have **no reward token and therefore
> no swap route**. The thing that forces separate contracts is precisely the swap
> path. No swap → no split.

---

<a name="s15"></a>
## §15 · The strategies Artha will ship

### 15.1 Phase 1 — no infrastructure needed

These need **no oracle and no swap adapter**. Ship them first.

| Strategy | Shape | `totalLiquidity()` | Notes |
|---|---|---|---|
| `AaveUsdcStrategy` | 1 · Rebase | `aUSDC.balanceOf(this)` | Instant exit. The reference implementation. |
| `AaveWethStrategy` | 1 · Rebase | `aWETH.balanceOf(this)` | Same code, different market. |
| `SUsdsStrategy` | 2 · Exch. rate | `sUSDS.convertToAssets(shares)` | **Best risk-adjusted add.** No borrower, no liquidation, T-bill backed. |
| `SUsdeStrategy` | 2 · Exch. rate | `sUSDe.convertToAssets(shares)` | Wrap it, never build the hedge. Funding-rate tail risk. |
| `WstEthStrategy` | 2 · Exch. rate | `wstETH.getStETHByWstETH(bal)` | WETH vault only. LST depeg + slashing tail. |
| `NestedArthaStrategy` | 2 · Exch. rate | `otherVault.convertToAssets(shares)` | **Never point back into a vault in your own dependency graph.** |

**Five of these six are the same `ERC4626WrapperStrategy` with a different
constructor argument.** That's the shortcut worth internalising.

```solidity
contract ERC4626WrapperStrategy is BaseStrategy {
    IERC4626 public immutable wrapper;

    constructor(address asset_, address vault_, address wrapper_)
        BaseStrategy(asset_, vault_)
    {
        require(IERC4626(wrapper_).asset() == asset_, "ASSET_MISMATCH");
        wrapper = IERC4626(wrapper_);
    }

    function _investedPlusInterest() internal view override returns (uint256) {
        return wrapper.convertToAssets(wrapper.balanceOf(address(this)));
    }
    function _depositToVenue(uint256 a) internal override {
        IERC20(asset).forceApprove(address(wrapper), a);
        wrapper.deposit(a, address(this));
    }
    function _withdrawFromVenue(uint256 a) internal override returns (uint256) {
        return wrapper.withdraw(a, address(this), address(this));
    }
    // harvest() → no-op. There is nothing to claim. That's the beauty of Shape 2.
}
```

### 15.2 Phase 2 — needs oracle + swap adapter

| Strategy | Shape | Extra machinery | Risk |
|---|---|---|---|
| `CompoundUsdcStrategy` | 1 + 3 | COMP oracle, COMP→WETH→USDC route | Low |
| `CompoundWethStrategy` | 1 + 3 | COMP oracle, COMP→WETH route | Low |
| `MorphoStrategy` | 1 + 3 | market param, reward route | Low–Med — isolated market risk |
| `CurveConvexStrategy` | 2 + 3 | CRV+CVX oracles, 2 routes, gauge | Med — impermanent loss |

### 15.3 Phase 3 — advanced

| Strategy | Shape | Why it's hard |
|---|---|---|
| `PendlePtStrategy` | 4 | Time-dependent valuation. Early exit has AMM slippage. Maturity rollover is an ops burden. |
| `WstEthLooperStrategy` | 1 + leverage | **Unwinding is the risk.** Must hard-cap leverage well below liquidation LTV, and unwind must work when the market is against you. |
| `RwaQueueStrategy` | 2 + queue | `maxWithdraw()` returns 0 most of the time. Needs a much larger buffer + a withdrawal-request state machine. |

### 15.4 The rule for what to build

> **A strategy earns its place only if `totalLiquidity()` can be computed
> trustlessly and `withdraw()` works when you need it most — during a panic.**

Both halves matter:

- Shape 1 and 2 pass trivially. Balance/price reads are atomic and manipulation-
  resistant.
- Shape 3 passes *only with a robust oracle*. A spot-price read is manipulable, and
  a manipulable `totalLiquidity()` is a manipulable pps, which is a drain.
- Looping fails the second half if you don't model the unwind under stress. Leverage
  is easy to enter and hard to exit — and you only ever need to exit when everyone
  else does too.
- RWA fails the second half by construction. That's *fine* if you size it against the
  buffer and are honest that it's the illiquid sleeve.

---

<a name="s16"></a>
## §16 · Swap adapter + oracle

The two pieces of shared infrastructure that unlock all of Shape 3.

### 16.1 Why they're separate contracts

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  ORACLE      "what is 300 COMP worth in USDC?"    → VALUATION        │
   │              read-only, must be manipulation-resistant                │
   │              used by: totalLiquidity()  ← EVERY accounting read       │
   ├──────────────────────────────────────────────────────────────────────┤
   │  SWAP        "sell 300 COMP for USDC, now"        → EXECUTION        │
   │              state-changing, must get a good fill                     │
   │              used by: harvest()          ← occasional keeper op       │
   └──────────────────────────────────────────────────────────────────────┘
   
   They answer DIFFERENT questions and have DIFFERENT threat models.
   Never use the swap venue's spot price as your oracle. That's the
   flash-loan attack, in its original form.
```

### 16.2 Oracle

```solidity
interface IOracle {
    /// @notice How much `quoteToken` is `amount` of `baseToken` worth?
    function quote(address baseToken, address quoteToken, uint256 amount)
        external view returns (uint256);
}

contract ChainlinkOracle is IOracle {
    mapping(address => address) public feeds;      // token => Chainlink aggregator
    uint256 public maxStaleness = 3600;            // 1 hour

    function quote(address base, address quote_, uint256 amount)
        external view returns (uint256)
    {
        (uint256 basePrice, uint8 baseDec)  = _price(base);
        (uint256 quotePrice, uint8 quoteDec) = _price(quote_);
        // amount × (basePrice/quotePrice), decimal-adjusted
        return amount * basePrice * (10 ** quoteDec) / (quotePrice * (10 ** baseDec));
    }

    function _price(address token) internal view returns (uint256, uint8) {
        AggregatorV3Interface f = AggregatorV3Interface(feeds[token]);
        require(address(f) != address(0), "NO_FEED");
        (, int256 answer,, uint256 updatedAt,) = f.latestRoundData();
        require(answer > 0, "BAD_PRICE");
        require(block.timestamp - updatedAt <= maxStaleness, "STALE_PRICE");   // ← critical
        return (uint256(answer), f.decimals());
    }
}
```

**Three non-negotiables:**

| Check | Why |
|---|---|
| `answer > 0` | A negative or zero price makes `totalLiquidity()` nonsense or reverts on division. |
| **staleness** | A frozen feed is worse than no feed. If Chainlink stops updating during a crash, you're valuing COMP at yesterday's price while the market repriced it 40% down. |
| **TWAP fallback** | If a token has no Chainlink feed, use a Uniswap V3 TWAP with a long window (≥30 min). Never spot. |

> **The staleness check is the one people forget.** It's two lines. It is the
> difference between "we mispriced rewards for an hour" and "an attacker deposited
> against a stale high price and drained the vault."

### 16.3 Swap adapter

```solidity
interface ISwapAdapter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,     // ← caller computes from the ORACLE, not the venue
        bytes calldata route
    ) external returns (uint256 amountOut);
}
```

The strategy computes `minAmountOut` from the **oracle**, then asks the **venue** to
fill it. If the venue can't, the tx reverts. That's the sandwich defence:

```solidity
// inside a Shape-3 strategy
function _minOut(uint256 rewardQty, uint16 slippageBps) internal view returns (uint256) {
    uint256 fair = oracle.quote(address(COMP), asset, rewardQty);   // ← oracle decides
    return fair * (10_000 - slippageBps) / 10_000;
}

function _swapRewardsToBase(uint256 compQty) internal override {
    COMP.forceApprove(address(swapAdapter), compQty);
    swapAdapter.swap(
        address(COMP), asset, compQty,
        _minOut(compQty, 100),          // ← 1% band around the ORACLE price
        SWAP_ROUTE
    );
}
```

```
   ┌─────────────────────────────────────────────────────────────────────┐
   │  SANDWICH DEFENCE                                                   │
   │                                                                     │
   │  Mallory front-runs harvest(), pumping COMP/USDC on Uniswap.        │
   │      → the VENUE now quotes a bad rate for our sell                 │
   │      → but minAmountOut came from CHAINLINK, which she didn't move  │
   │      → the swap can't meet minAmountOut → REVERTS                   │
   │      → Mallory's front-run tx just cost her gas for nothing         │
   │      → keeper retries next block                                    │
   │                                                                     │
   │  The attack fails because the price we DEMAND and the venue we      │
   │  TRADE ON are independent.                                          │
   └─────────────────────────────────────────────────────────────────────┘
```


---

# PART V — REWARDS

<a name="s17"></a>
## §17 · The two parallel reward systems

### 17.1 One deposit, two payouts, two independent pools

```
                        Alice deposits 10,000 USDC
                    (referred by Bob's code, tier 2)
                                  │
                                  ▼
                    ┌─────────────────────────────┐
                    │      ARTHA USDC VAULT       │
                    │  net = 9,970 after fee      │
                    └──────────┬──────────────────┘
                               │
              ┌────────────────┴────────────────┐
              │  TWO notify calls, one deposit  │
              ▼                                 ▼
   ┌─────────────────────────┐      ┌─────────────────────────┐
   │   USER REWARD SYSTEM    │      │    REFERRAL SYSTEM      │
   │  ─────────────────────  │      │  ─────────────────────  │
   │  pays: THE DEPOSITOR    │      │  pays: THE REFERRER     │
   │  who:  Alice            │      │  who:  Bob              │
   │  rate: rewardRatio      │      │  rate: rewardRatio      │
   │        [vault]          │      │        [vault] ×        │
   │                         │      │        tierRatio[tier]  │
   │  key:  (vault, ADDRESS) │      │  key:  (vault, CODE)    │
   └───────────┬─────────────┘      └───────────┬─────────────┘
               │                                │
               ▼                                ▼
   ┌─────────────────────────┐      ┌─────────────────────────┐
   │   USER REWARD VAULT     │      │    REFERRAL VAULT       │
   │  holds ARTHA pool A     │      │  holds ARTHA pool B     │
   │  cap: maxDistributable  │      │  cap: its own balance   │
   └─────────────────────────┘      └─────────────────────────┘

   ══════════════════════════════════════════════════════════════
    TWO POOLS. TWO CAPS. TWO CLAIMS. ZERO SHARED STATE.
    Draining one cannot touch the other.
   ══════════════════════════════════════════════════════════════
```

### 17.2 Side-by-side

| | **User rewards** | **Referral rewards** |
|---|---|---|
| **Who earns** | The depositor (position owner) | The referral code owner |
| **Why** | For putting capital at risk | For bringing capital in |
| **Rate** | `rewardRatio[vault]` | `rewardRatio[vault] × tierRatio[tier]` |
| **Keyed by** | `(vault, user address)` | `(vault, code)` |
| **Tiers?** | No — one rate per vault | Yes — up to 8 tiers |
| **Accumulator** | Single: `accArthaPerPrincipal` | Split: `accTierSeconds[t]` × `lane[V][t].acc` |
| **Pool** | `UserRewardVault` | `ReferralVault` |
| **Claim** | `vault.claimArtha(to)` | `referralVault.claim(vault, code, to, amt)` |
| **Lifecycle** | Permanent programme | **Temporary** — retired when budget is spent |

### 17.3 Why the referral accumulator is more complex

Worth explaining, because someone will ask why the two engines don't share code.

**User rewards** have *one* rate per vault:
```
   rate = rewardRatio[vault]
   → one accumulator per vault. Trivial.
```

**Referral rewards** have a *product of two independently-governed* rates:
```
   rate = rewardRatio[vault] × tierRatio[tier]
   
   Naive: one accumulator per (vault, tier) pair.
          Change tierRatio[2]?  → must advance the (V,2) lane for EVERY vault.
          With 1,000 vaults, that's 1,000 SSTOREs in one tx. Impossible.
   
   Split: accTierSeconds[t] = ∫ tierRatio[t] dτ         ← ONE integral per tier
          lane[V][t].acc    += rewardRatio[V] × Δ(accTierSeconds[t]) × ACC / (1e36 × YEAR)
          
          Change tierRatio[2]?  → advance ONE integral. O(1). 
          Change rewardRatio[V]? → advance V's ≤8 lanes. O(8). 
```

**That's why `ReferralVault` has the `Lane` struct and `accTierSeconds` and the user
reward engine doesn't.** The complexity buys O(1) tier changes at unbounded vault
count. The user engine has no tiers, so it needs none of it.

---

<a name="s18"></a>
## §18 · User rewards: System + Vault split

**This is change #10:** mirror the referral architecture exactly. Logic in the
System, money in the Vault.

### 18.1 The layering

```
   ┌────────────────────────────────────────────────────────────────────┐
   │  UserRewardManager        ← access control base                    │
   │    · rewardManager (timelock)                                      │
   │    · approvedCallers[vault]  ← which vaults may notify             │
   │    · pause / unpause                                               │
   └───────────────────────────┬────────────────────────────────────────┘
                               │ inherits
   ┌───────────────────────────▼────────────────────────────────────────┐
   │  UserRewardSystem         ← LOGIC + ACCOUNTING. Holds no money.    │
   │    · rewardRatio[vault]                                            │
   │    · accArthaPerPrincipal[vault]                                   │
   │    · userPrincipalNorm[vault][user]                                │
   │    · userRewardDebt[vault][user]                                   │
   │    · notifyDeposit / notifyWithdraw / sync                         │
   │    · _settle() → calls vault.credit()                              │
   └───────────────────────────┬────────────────────────────────────────┘
                               │ inherits
   ┌───────────────────────────▼────────────────────────────────────────┐
   │  UserRewardVault          ← MONEY. Custody, cap, transfer.         │
   │    · IERC20 artha                                                  │
   │    · maxDistributable / totalDistributed / totalClaimed            │
   │    · earnedByVault[vault][user] / claimed[user]                    │
   │    · credit() ← capped                                             │
   │    · claim()  ← transfers                                          │
   └────────────────────────────────────────────────────────────────────┘

   IDENTICAL SHAPE TO:
   ReferralVaultManager → ReferralSystem → ReferralVault
```

### 18.2 Why split logic from money

| | If merged | Split (chosen) |
|---|---|---|
| **Audit** | "Where can ARTHA leave?" → read 800 lines | → read only the Vault layer's `claim()` |
| **Upgrade** | Fix an accrual bug → redeploy the thing holding the money → migrate the pool | Fix accrual in System, Vault untouched, ARTHA never moves |
| **Cap** | Enforcement scattered through accrual logic | One `require` at one boundary |
| **Symmetry** | Two reward systems, two shapes, two mental models | Same shape → learn once |

### 18.3 UserRewardManager

```solidity
contract UserRewardManager is Pausable {
    address public rewardManager;                    // the Timelock in production
    mapping(address => bool) public approvedCallers; // the vaults

    event RewardManagerUpdated(address oldM, address newM);
    event CallerUpdated(address caller, bool status);

    modifier onlyRewardManager() {
        require(msg.sender == rewardManager, "NOT_REWARD_MANAGER");
        _;
    }

    /// @dev A vault may ONLY report under its own address. See §18.7.
    modifier onlyCaller(address vault) {
        require(approvedCallers[msg.sender], "NOT_APPROVED_CALLER");
        require(msg.sender == vault, "CALLER_NOT_VAULT");     // ← critical
        _;
    }

    constructor(address _rewardManager) {
        require(_rewardManager != address(0), "INVALID_MANAGER");
        rewardManager = _rewardManager;
    }

    function setCaller(address _caller, bool _status) external onlyRewardManager {
        require(_caller != address(0), "INVALID_CALLER");
        approvedCallers[_caller] = _status;
        emit CallerUpdated(_caller, _status);
    }

    function pause()   external onlyRewardManager { _pause(); }
    function unpause() external onlyRewardManager { _unpause(); }
}
```

### 18.4 UserRewardSystem — the accrual engine

```solidity
contract UserRewardSystem is UserRewardManager {
    uint256 public constant ACC       = 1e18;
    uint256 public constant YEAR      = 360 days;
    uint256 public constant RATIO_ONE = 1e18;

    struct VaultMeta {
        bool    registered;
        uint8   decimals;
        uint256 rewardRatio;        // 0..1e18.  ZERO ⇒ NO REWARDS (change #4)
        uint256 scale;              // 10^(18-decimals)
        uint256 accArthaPerPrincipal;
        uint256 lastUpdate;
        uint256 totalPrincipalNorm;
        uint256 totalArthaEarned;   // per-vault book (change #10)
        uint256 totalArthaClaimed;
    }

    mapping(address => VaultMeta) public vaultMeta;
    uint64 public vaultCount;

    // ── ADDRESS-KEYED, not tokenId-keyed (change #9) ──
    mapping(address => mapping(address => uint256)) public userPrincipalNorm; // vault=>user=>18dp
    mapping(address => mapping(address => uint256)) public userRewardDebt;    // vault=>user

    // per-user footprint — bounds claimAll / syncAll
    mapping(address => address[]) public userVaults;
    mapping(address => mapping(address => bool)) public userInVault;

    // ───────────────────────── accrual ─────────────────────────

    /// @dev Advance a vault's accumulator to now. If rewardRatio == 0, nothing accrues.
    function _updateAccumulator(address vault) internal {
        VaultMeta storage m = vaultMeta[vault];
        if (block.timestamp <= m.lastUpdate) return;
        uint256 ratio = m.rewardRatio;
        if (ratio != 0) {                                   // ← change #4, explicit
            uint256 dt = block.timestamp - m.lastUpdate;
            m.accArthaPerPrincipal += (ratio * dt * ACC) / (RATIO_ONE * YEAR);
        }
        m.lastUpdate = block.timestamp;
    }

    /// @dev Bank a user's accrued ARTHA in one vault, then re-checkpoint.
    ///      Idempotent: a second call in the same block banks zero.
    function _settle(address vault, address user) internal {
        _updateAccumulator(vault);
        VaultMeta storage m = vaultMeta[vault];
        uint256 accumulated = (userPrincipalNorm[vault][user] * m.accArthaPerPrincipal) / ACC;
        uint256 pending = accumulated - userRewardDebt[vault][user];   // monotonic → safe
        if (pending != 0) {
            uint256 credited = _credit(vault, user, pending);          // ← Vault layer, capped
            m.totalArthaEarned += credited;
        }
        userRewardDebt[vault][user] = accumulated;
    }

    // ───────────────────────── configuration ─────────────────────────

    function registerVault(address vault, uint8 decimals, uint256 rewardRatio_)
        external onlyRewardManager
    {
        require(vault != address(0), "INVALID_VAULT");
        require(!vaultMeta[vault].registered, "ALREADY_REGISTERED");
        require(decimals <= 18, "DECIMALS_GT_18");
        require(rewardRatio_ <= RATIO_ONE, "RATIO_GT_ONE");

        vaultMeta[vault] = VaultMeta({
            registered: true,
            decimals: decimals,
            rewardRatio: rewardRatio_,
            scale: 10 ** (18 - decimals),
            accArthaPerPrincipal: 0,
            lastUpdate: block.timestamp,
            totalPrincipalNorm: 0,
            totalArthaEarned: 0,
            totalArthaClaimed: 0
        });
        unchecked { vaultCount += 1; }
        emit VaultRegistered(vault, decimals, rewardRatio_);
    }

    /// @notice Change a vault's rate. NON-RETROACTIVE: banks the old rate first.
    function setRewardRatio(address vault, uint256 newRatio) external onlyRewardManager {
        require(vaultMeta[vault].registered, "NOT_REGISTERED");
        require(newRatio <= RATIO_ONE, "RATIO_GT_ONE");
        _updateAccumulator(vault);                       // ← bank old rate up to NOW
        uint256 old = vaultMeta[vault].rewardRatio;
        vaultMeta[vault].rewardRatio = newRatio;
        emit RewardRatioUpdated(vault, old, newRatio, block.timestamp);
    }

    /// @notice Turn every listed vault off. The clean stop when the pool is spent.
    function stopAll(address[] calldata vaults) external onlyRewardManager {
        for (uint256 i; i < vaults.length; i++) {
            _updateAccumulator(vaults[i]);
            vaultMeta[vaults[i]].rewardRatio = 0;
            emit RewardRatioUpdated(vaults[i], 0, 0, block.timestamp);
        }
    }

    // ───────────────────────── hooks (the vault calls these) ─────────────────────────

    function notifyDeposit(address vault, address user, uint256 rawPrincipal)
        external onlyCaller(vault) whenNotPaused
    {
        require(vaultMeta[vault].registered, "NOT_REGISTERED");
        if (rawPrincipal == 0 || user == address(0)) return;

        _settle(vault, user);                                   // bank at OLD principal
        uint256 addNorm = rawPrincipal * vaultMeta[vault].scale;
        userPrincipalNorm[vault][user] += addNorm;
        vaultMeta[vault].totalPrincipalNorm += addNorm;
        _recheckpoint(vault, user);

        if (!userInVault[user][vault]) {
            userInVault[user][vault] = true;
            userVaults[user].push(vault);
        }
        emit PrincipalIncreased(vault, user, rawPrincipal);
    }

    function notifyWithdraw(address vault, address user, uint256 rawPrincipal)
        external onlyCaller(vault) whenNotPaused
    {
        require(vaultMeta[vault].registered, "NOT_REGISTERED");
        if (rawPrincipal == 0) return;
        uint256 bal = userPrincipalNorm[vault][user];
        if (bal == 0) return;

        _settle(vault, user);                                   // bank first
        uint256 decNorm = rawPrincipal * vaultMeta[vault].scale;
        if (decNorm > bal) decNorm = bal;                       // clamp
        userPrincipalNorm[vault][user] = bal - decNorm;
        vaultMeta[vault].totalPrincipalNorm -= decNorm;
        _recheckpoint(vault, user);
        emit PrincipalDecreased(vault, user, rawPrincipal);
    }

    // ───────────────────────── permissionless sync ─────────────────────────

    function sync(address vault, address user) public {
        require(vaultMeta[vault].registered, "NOT_REGISTERED");
        _settle(vault, user);
    }

    function syncAll(address user) external {
        address[] storage list = userVaults[user];
        for (uint256 i; i < list.length; i++) _settle(list[i], user);
    }

    // ───────────────────────── views ─────────────────────────

    /// @notice Live pending (unbanked) ARTHA for a user in one vault.
    function pendingReward(address vault, address user) public view returns (uint256) {
        VaultMeta storage m = vaultMeta[vault];
        uint256 acc = m.accArthaPerPrincipal;
        if (block.timestamp > m.lastUpdate && m.rewardRatio != 0) {
            uint256 dt = block.timestamp - m.lastUpdate;
            acc += (m.rewardRatio * dt * ACC) / (RATIO_ONE * YEAR);
        }
        uint256 accumulated = (userPrincipalNorm[vault][user] * acc) / ACC;
        return accumulated - userRewardDebt[vault][user];
    }

    function pendingRewardAll(address user) external view returns (uint256 total) {
        address[] storage list = userVaults[user];
        for (uint256 i; i < list.length; i++) total += pendingReward(list[i], user);
    }

    /// @notice Per-vault books — how much ARTHA this vault has paid users. (change #10)
    function vaultBooks(address vault)
        external view
        returns (
            uint256 rewardRatio_,
            uint256 principalNorm,
            uint256 arthaEarned,
            uint256 arthaClaimed,
            uint256 arthaOutstanding
        )
    {
        VaultMeta storage m = vaultMeta[vault];
        return (
            m.rewardRatio,
            m.totalPrincipalNorm,
            m.totalArthaEarned,
            m.totalArthaClaimed,
            m.totalArthaEarned - m.totalArthaClaimed
        );
    }

    function _recheckpoint(address vault, address user) internal {
        userRewardDebt[vault][user] =
            (userPrincipalNorm[vault][user] * vaultMeta[vault].accArthaPerPrincipal) / ACC;
    }

    /// @dev Implemented by the Vault layer.
    function _credit(address vault, address user, uint256 amount)
        internal virtual returns (uint256 credited);
}
```

### 18.5 UserRewardVault — the money layer

```solidity
contract UserRewardVault is UserRewardSystem, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable artha;

    uint256 public maxDistributable;   // THE CAP = pre-minted pool
    uint256 public totalDistributed;   // Σ credited across all users & vaults
    uint256 public totalClaimed;

    mapping(address => mapping(address => uint256)) public earnedByVault; // vault=>user
    mapping(address => uint256) public totalEarned;   // user => Σ across vaults (change #9)
    mapping(address => uint256) public claimed;       // user => lifetime claimed

    event Credited(address indexed vault, address indexed user, uint256 amount);
    event Claimed(address indexed user, address indexed to, uint256 amount);
    event CapSet(uint256 cap);

    constructor(address _artha, address _manager) UserRewardManager(_manager) {
        require(_artha != address(0), "INVALID_ARTHA");
        artha = IERC20(_artha);
    }

    function setCap(uint256 cap) external onlyRewardManager {
        require(cap >= totalDistributed, "CAP_LT_DISTRIBUTED");
        maxDistributable = cap;
        emit CapSet(cap);
    }

    /// @dev THE HARD CAP. Σ credited can never exceed the pool.
    ///      Once full, this silently returns 0 → accrual continues but pays nothing.
    function _credit(address vault, address user, uint256 amount)
        internal override returns (uint256)
    {
        uint256 room = maxDistributable - totalDistributed;
        if (amount > room) amount = room;
        if (amount == 0) return 0;
        totalDistributed          += amount;
        earnedByVault[vault][user] += amount;
        totalEarned[user]          += amount;      // ← ONE balance per user (change #9)
        emit Credited(vault, user, amount);
        return amount;
    }

    /// @notice A user claims ARTHA across EVERY vault they're in. ONE transaction.
    function claimAll(address to) external nonReentrant whenNotPaused returns (uint256 amount) {
        require(to != address(0), "ZERO_ADDR");
        address[] storage list = userVaults[msg.sender];
        for (uint256 i; i < list.length; i++) _settle(list[i], msg.sender);   // bank everything

        amount = totalEarned[msg.sender] - claimed[msg.sender];
        require(amount > 0, "NOTHING_TO_CLAIM");
        claimed[msg.sender] += amount;
        totalClaimed        += amount;
        artha.safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    /// @notice Claim a specific amount (partial claims).
    function claim(address to, uint256 amount) external nonReentrant whenNotPaused {
        require(to != address(0) && amount != 0, "INVALID_PARAMS");
        address[] storage list = userVaults[msg.sender];
        for (uint256 i; i < list.length; i++) _settle(list[i], msg.sender);

        uint256 owed = totalEarned[msg.sender] - claimed[msg.sender];
        require(amount <= owed, "EXCEEDS_EARNED");
        claimed[msg.sender] += amount;
        totalClaimed        += amount;
        artha.safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    function claimable(address user) external view returns (uint256) {
        return totalEarned[user] - claimed[user];
    }

    function remainingPool() external view returns (uint256) {
        return maxDistributable - totalDistributed;
    }
}
```

### 18.6 The reward math — verified arithmetic

```
   ┌───────────────────────────────────────────────────────────────────┐
   │  accArthaPerPrincipal += rewardRatio × dt × ACC / (1e18 × YEAR)   │
   │  earned(user) = principalNorm × acc / ACC − rewardDebt            │
   └───────────────────────────────────────────────────────────────────┘

   Alice: 10,000 USDC in a vault with rewardRatio = 5e17 (50%/yr), 90 days.

   1) normalise:   principalNorm = 10,000e6 × 1e12 = 1e22        (10,000 @ 18dp)
   
   2) accumulator over 90 days (dt = 7,776,000 s):
      acc = 5e17 × 7,776,000 × 1e18 / (1e18 × 31,104,000)
          = 5e17 × 7,776,000 / 31,104,000
          = 5e17 × 0.25
          = 1.25e17
   
   3) earned = 1e22 × 1.25e17 / 1e18 = 1.25e21 wei
   
   ═══════════════════════════════════════════════════════
    earned = 1,250 ARTHA
   
    CHECK:  50%/yr × 10,000 = 5,000 ARTHA/yr
            5,000 × 90/360  = 1,250 ARTHA  ✓
   ═══════════════════════════════════════════════════════
```

**rewardRatio = 0 → nothing accrues (change #4):**
```
   acc += 0 × 7,776,000 × 1e18 / (1e18 × 31,104,000) = 0
   earned = principalNorm × 0 / 1e18 − 0 = 0
   
   The `if (ratio != 0)` guard makes this explicit AND saves the SSTORE.
   Zero is not a special case — it's the natural identity. But we still
   check it, because an explicit branch is cheaper and clearer than
   trusting multiplication by zero.
```

**Bank-before-change, demonstrated:**
```
   Day 0    deposit 10,000.  principalNorm = 1e22.  rewardDebt = 0.
   Day 90   deposit 10,000 MORE.
   
            ┌─ _settle() FIRST:
            │    acc         = 1.25e17
            │    accumulated = 1e22 × 1.25e17 / 1e18 = 1.25e21
            │    pending     = 1.25e21 − 0 = 1.25e21   → 1,250 ARTHA BANKED ✓
            │    rewardDebt  = 1.25e21
            │
            ├─ THEN change principal:
            │    principalNorm = 1e22 + 1e22 = 2e22
            │
            └─ THEN re-checkpoint:
                 rewardDebt = 2e22 × 1.25e17 / 1e18 = 2.5e21
   
   Day 180  acc = 2.5e17
            accumulated = 2e22 × 2.5e17 / 1e18 = 5e21
            pending     = 5e21 − 2.5e21 = 2.5e21  → 2,500 ARTHA
   
   TOTAL = 1,250 + 2,500 = 3,750 ARTHA
   
   CHECK:  first 10,000 for 180 days  = 50% × 10,000 × 180/360 = 2,500
           second 10,000 for 90 days  = 50% × 10,000 ×  90/360 = 1,250
                                                        TOTAL  = 3,750 ✓
   
   Without the settle-first, the day-90 re-checkpoint would have wiped
   the 1,250 that the FIRST 10,000 had already earned. Silently.
```

### 18.7 The `msg.sender == vault` check — why it's critical

```solidity
modifier onlyCaller(address vault) {
    require(approvedCallers[msg.sender], "NOT_APPROVED_CALLER");
    require(msg.sender == vault, "CALLER_NOT_VAULT");     // ← THIS LINE
    _;
}
```

Without the second line:

```
   ┌───────────────────────────────────────────────────────────────────┐
   │  ATTACK                                                           │
   │                                                                   │
   │  1. WETH-Vault is an approved caller (legitimately).              │
   │  2. WETH-Vault has rewardRatio = 1e17  (10%/yr — low).            │
   │  3. USDC-Vault has rewardRatio = 1e18  (100%/yr — launch boost).  │
   │                                                                   │
   │  4. A bug (or a malicious upgrade) in WETH-Vault lets it call:    │
   │       rewardSystem.notifyDeposit(USDC_VAULT, attacker, 1e30)      │
   │                                     ▲                             │
   │                                     └─ NOT its own address!       │
   │                                                                   │
   │  5. The attacker now has a phantom 1e30 principal accruing at     │
   │     100%/yr in a vault they never deposited a cent into.          │
   │                                                                   │
   │  6. The entire ARTHA pool drains to them.                         │
   └───────────────────────────────────────────────────────────────────┘

   WITH the check: WETH-Vault can ONLY report under `WETH_VAULT`. A compromised
   vault can only corrupt its own book. Blast radius = one vault.
```

> **This exact check should be added to `ReferralVaultManager.onlyCaller` too.** The
> current version only verifies `approvedCallers[msg.sender]` — it never checks that
> the `strategy`/`vault` argument matches the caller. **Any approved vault can
> currently credit referrals under any other vault's key.** Same attack, same fix:
>
> ```solidity
> // ReferralVaultManager — CURRENT (vulnerable)
> modifier onlyCaller() {
>     require(approvedCallers[msg.sender], "NOT_APPROVED_CALLER");
>     _;
> }
>
> // FIXED — take the vault as a parameter and bind it
> modifier onlyCaller(address vault) {
>     require(approvedCallers[msg.sender], "NOT_APPROVED_CALLER");
>     require(msg.sender == vault, "CALLER_NOT_VAULT");
>     _;
> }
> // then in ReferralVault:
> //   function notifyDeposit(address vault, address investor, uint256 raw)
> //       external onlyCaller(vault) whenNotPaused { ... }
> ```
>
> `RewardTracker.credit()` in the v3 spike already had it right
> (`require(isVault[msg.sender] && msg.sender == vault)`). The referral stack should
> match.

---

<a name="s19"></a>
## §19 · Referral rewards: the existing stack

Unchanged from your current implementation. Recapped here so the document is
self-contained.

### 19.1 The three layers

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  ReferralVaultManager      ← ACCESS CONTROL                          │
   │    referralVaultManager (timelock) · approvedCallers[] · pause       │
   └──────────────────────────┬───────────────────────────────────────────┘
                              │ inherits
   ┌──────────────────────────▼───────────────────────────────────────────┐
   │  ReferralSystem            ← REGISTRY. Who owns what. No money.      │
   │    codeOwner[code] · ownerToCode[addr] · traderToCode[investor]      │
   │    codeTier[code]  · pendingCodeOwner[code]                          │
   │    createCode (ADMIN ONLY) · approveTransfer/executeTransfer         │
   │    setTraderCode (investor, ONCE) · _setCodeTier · _deactivateCode   │
   └──────────────────────────┬───────────────────────────────────────────┘
                              │ inherits
   ┌──────────────────────────▼───────────────────────────────────────────┐
   │  ReferralVault             ← MONEY + ACCRUAL                         │
   │    vaultMeta[vault] · tierRatio[t] · accTierSeconds[t]               │
   │    lane[vault][tier] · codeAccount[vault][code]                      │
   │    notifyDeposit/notifyWithdraw · sync/syncAll · claim/claimAll      │
   └──────────────────────────────────────────────────────────────────────┘
```

### 19.2 Design rules worth restating

| Rule | Why |
|---|---|
| **Codes are admin-created only** | Users can't mint a code and refer their own second wallet. Handed out at real-world events. |
| **Investor sets their code once** | Rewards are tracked per code. Switching mid-way would misattribute already-referred capital. |
| **`owner == investor` is blocked at the vault layer** | Defence-in-depth against self-referral even if a code leaks. |
| **Tiers live in the registry, ratios live in the vault** | The registry records *rank*; the vault decides what rank is *worth*. Governance can reprice tiers without touching the registry. |
| **The programme is temporary** | Spend the budget, deactivate all codes, pause the vault, sweep the remainder to treasury. |

### 19.3 The referral reward formula

```
   ┌──────────────────────────────────────────────────────────────────┐
   │  rewardPerYear = amountNorm × tierRatio × rewardRatio / 1e36     │
   │  accrued       = rewardPerYear × elapsed / YEAR                  │
   └──────────────────────────────────────────────────────────────────┘

   amountNorm  = raw principal × 10^(18−decimals)
   rewardRatio = per-VAULT rate  (0..1e18)
   tierRatio   = per-TIER  rate  (tier1=1e17, tier2=3e17, tier3=1e18)
   YEAR        = 360 days
```

**Worked example.** Bob's code is tier 2 (`3e17`). Alice deposits 10,000 USDC into a
vault with `rewardRatio = 1e18`. She holds 90 days.

```
   amountNorm  = 10,000e6 × 1e12 = 1e22
   
   rewardPerYear = 1e22 × 3e17 × 1e18 / 1e36
                 = 1e22 × 3e17 / 1e18
                 = 3e21                                  = 3,000 ARTHA/yr
   
   accrued     = 3e21 × 7,776,000 / 31,104,000
               = 3e21 × 0.25
               = 7.5e20                                  = 750 ARTHA
   
   ═══════════════════════════════════════════════════════════
    BOB earns 750 ARTHA for referring Alice.
    ALICE earns 1,250 ARTHA for depositing (at 50% user ratio).
    
    Two pools. Two caps. One deposit. Neither touches the other.
   ═══════════════════════════════════════════════════════════
```

Note the tier's effect: at tier 1 (`1e17`) Bob would earn 250; at tier 3 (`1e18`),
2,500. **Same deposit, 10× spread across tiers.** That's the incentive to climb.

### 19.4 The split accumulator, walked through

Why `accTierSeconds` exists, concretely:

```
   Day 0     tierRatio[2] = 3e17.  tierLastUpdate[2] = day 0.
             accTierSeconds[2] = 0
   
   Day 30    Governance raises tier 2 → 5e17.
             ┌─ _syncTier(2) FIRST:
             │    accTierSeconds[2] += 3e17 × (30 days in secs)
             │                      += 3e17 × 2,592,000 = 7.776e23
             │    tierLastUpdate[2] = day 30
             └─ THEN tierRatio[2] = 5e17
             
             ONE SSTORE. No vault was touched. Works with 1,000,000 vaults.
   
   Day 90    A lane for (USDC-vault, tier 2) is advanced:
             _syncTier(2) → accTierSeconds[2] += 5e17 × 5,184,000 = 2.592e24
                          → total = 7.776e23 + 2.592e24 = 3.3696e24
             
             lane.acc += rewardRatio[V] × Δ(accTierSeconds) × ACC / (1e36 × YEAR)
             
             The lane gets 3e17 for days 0–30 and 5e17 for days 30–90,
             automatically, WITHOUT anyone having advanced it at day 30.
   
   ═══════════════════════════════════════════════════════════════════
    THE INTEGRAL *IS* THE RECORD OF "old rate until the boundary,
    new rate after". That's why it's O(1).
   ═══════════════════════════════════════════════════════════════════
```

---

<a name="s20"></a>
## §20 · Address-keyed, not id-keyed

**This is change #9 and it's the one with the biggest UX consequence.**

### 20.1 The problem with id-keying

```
   v3: rewards keyed by tokenId
   ══════════════════════════════════════════════════════════════════
   
   Alice has:
     USDC-Conservative  #1, #4, #9      ← 3 positions
     USDC-Aggressive    #2              ← 1 position
     WETH-Core          #1              ← 1 position
   
   To claim her ARTHA:
   
     vaultA.claimArtha(1)   ┐
     vaultA.claimArtha(4)   │
     vaultA.claimArtha(9)   ├── 5 TRANSACTIONS
     vaultB.claimArtha(2)   │   5 × gas
     vaultC.claimArtha(1)   ┘   5 chances to mess up
   
   And it gets WORSE with more positions — which v4 actively encourages
   (change #2). The two changes fight each other.
```

### 20.2 The fix

```
   v4: rewards keyed by (vault, user address)
   ══════════════════════════════════════════════════════════════════
   
   Alice's positions:                    Alice's ARTHA principal:
     USDC-Cons #1  basis  5,000            userPrincipalNorm[USDC-Cons][alice]
     USDC-Cons #4  basis 12,000              = (5,000+12,000+800) × 1e12
     USDC-Cons #9  basis    800              = 1.78e22
     USDC-Aggr #2  basis 30,000            userPrincipalNorm[USDC-Aggr][alice]
     WETH-Core #1  basis      4               = 3e22
                                           userPrincipalNorm[WETH-Core][alice]
                                             = 4e18
   
   To claim EVERYTHING:
   
     userRewardVault.claimAll(alice)   ← ONE TRANSACTION
                                          loops userVaults[alice],
                                          settles each,
                                          pays totalEarned − claimed
```

### 20.3 Why this is correct, not just convenient

Three independent arguments:

**1. The reward is for the *person*, not the *lot*.**
The ARTHA rate is `rewardRatio[vault]` — a function of the vault, not the position.
Alice's three USDC-Conservative positions accrue at an identical rate on identical
terms. Splitting them into three accrual states stores the same number three times
and gives three chances for drift.

**2. Position count must not change reward.**
```
   Alice: one position, 17,800 basis
   Bob:   three positions, 5,000 + 12,000 + 800 = 17,800 basis
   
   Same capital. Same vault. Same duration.
   → They MUST earn identical ARTHA.
   
   Address-keying makes this true BY CONSTRUCTION:
     userPrincipalNorm[vault][alice] = 1.78e22
     userPrincipalNorm[vault][bob]   = 1.78e22     ← identical
   
   Id-keying makes it true only if three separate accumulators
   stay perfectly in sync. Which they will — until a rounding
   difference at the third settle. Then Bob earns 2 wei less
   than Alice, forever, for no reason.
```

**3. It composes with the referral system.**
The referral engine is already keyed by `(vault, code)` — not by position. Keying
user rewards by `(vault, address)` means both engines have the same shape:
`mapping(vault => mapping(key => state))`. One mental model, one review pattern.

### 20.4 The trade-off, stated honestly

```
   ┌─────────────────────────────────────────────────────────────────────┐
   │  NFT TRANSFER NO LONGER MOVES UNCLAIMED ARTHA                       │
   │                                                                     │
   │  v3:  transfer #4 → buyer inherits shares AND unclaimed ARTHA       │
   │  v4:  transfer #4 → buyer inherits shares ONLY.                     │
   │                     Alice's ARTHA stays with Alice.                 │
   └─────────────────────────────────────────────────────────────────────┘
```

**This is the correct semantic**, and here's why:

- ARTHA was earned by **Alice's capital being at risk for Alice's time**. It is
  *hers*. Selling a position shouldn't forfeit rewards you already earned, any more
  than selling a stock forfeits a dividend already declared.
- The buyer gets the **shares** — the principal + yield. That's what they paid for.
  They start earning ARTHA from block 1 of *their* ownership.
- It removes a whole class of valuation ambiguity. In v3, pricing an NFT meant
  pricing `shares × pps + unclaimed ARTHA`, where the ARTHA leg needs a live ARTHA
  price. In v4 the NFT is worth `shares × pps`. Clean. Marketplace-friendly.

**The transfer hook that makes it work:**

```solidity
// PositionFacet — _update is OZ v5's transfer hook
function _update(address to, uint256 tokenId, address auth)
    internal returns (address from)
{
    VaultStorage storage vs = LibVaultStorage.s();
    from = _ownerOf(tokenId);

    if (from != address(0) && to != address(0) && from != to) {
        uint256 basis = vs.positions[tokenId].costBasis;

        // 1. bank the SELLER's ARTHA at their current principal
        LibArtha.settle(from);
        // 2. move the reward principal: seller loses it, buyer gains it
        uint256 norm = basis * vs.scale;
        if (norm > vs.userPrincipalNorm[from]) norm = vs.userPrincipalNorm[from];
        vs.userPrincipalNorm[from] -= norm;
        LibArtha.recheckpoint(from);

        // 3. bank the BUYER's ARTHA at their OLD principal, then add
        LibArtha.settle(to);
        vs.userPrincipalNorm[to] += norm;
        LibArtha.recheckpoint(to);

        // 4. tell both reward systems the principal moved
        IRewardSystem(vs.rewardSystem).notifyWithdraw(address(this), from, basis);
        IRewardSystem(vs.rewardSystem).notifyDeposit(address(this), to, basis);
        IReferralVault(vs.referralVault).notifyWithdraw(address(this), from, basis);
        IReferralVault(vs.referralVault).notifyDeposit(address(this), to, basis);
    }
    // ... standard ERC-721 ownership bookkeeping ...
}
```

```
   ┌─────────────────────────────────────────────────────────────────────┐
   │  Alice sells #4 (basis 12,000) to Carol on day 90                   │
   │                                                                     │
   │  BEFORE                          AFTER                              │
   │  ──────────────────────          ──────────────────────             │
   │  ownerOf(#4)     = alice         ownerOf(#4)     = carol            │
   │  principal[alice]= 17,800        principal[alice]=  5,800  (−12,000)│
   │  principal[carol]=      0        principal[carol]= 12,000  (+12,000)│
   │  earned[alice]   =  2,225        earned[alice]   =  2,225  ← KEPT   │
   │  earned[carol]   =      0        earned[carol]   =      0           │
   │                                                                     │
   │  Alice keeps every ARTHA she earned. Carol earns from now on.       │
   │  Alice can still call claimAll() and collect her 2,225.             │
   └─────────────────────────────────────────────────────────────────────┘
```


---

# PART VI — OPERATIONS

<a name="s21"></a>
## §21 · Roles: keeper, timelock, super admin

### 21.1 The three keys

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║  KEEPER                                                    a hot bot key       ║
║  ─────────────────────────────────────────────────────────────────────────    ║
║  Can:     deployIdle · harvest · rebalance · setTargets · sync                 ║
║  Cannot:  move funds anywhere except into registered strategies               ║
║           add or remove a strategy                                             ║
║           change fees, keeper, or any address                                  ║
║           upgrade anything                                                     ║
║                                                                                ║
║  WORST CASE IF STOLEN: the attacker can rebalance between the SAME             ║
║  registered strategies and burn gas. They cannot extract a single token.       ║
║  → so it can safely be a hot key on a server.                                  ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║  TIMELOCK (governance)                                     the real owner      ║
║  ─────────────────────────────────────────────────────────────────────────    ║
║  Can:     everything — add/remove strategies, set fees, set ratios,           ║
║           diamondCut, set the keeper, toggle emergency                        ║
║  Delay:   48h minimum. Every action is visible on-chain before it executes.   ║
║                                                                                ║
║  WORST CASE IF CAPTURED: bounded by the hard constants (MAX_ENTRY_FEE_BPS,     ║
║  MAX_PERF_FEE_BPS) and by the 48h window in which users can exit.             ║
╠═══════════════════════════════════════════════════════════════════════════════╣
║  SUPER ADMIN                                               break-glass         ║
║  ─────────────────────────────────────────────────────────────────────────    ║
║  Can:     toggle emergency                                                     ║
║           AND — only while emergency is ON — add/remove/rebalance/setTargets   ║
║  Cannot:  do ANY of that while the vault is operating normally                ║
║           change fees, upgrade, or set addresses. Ever.                        ║
║                                                                                ║
║  This is change #5. §22 explains the gating in full.                           ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

### 21.2 Why the keeper is deliberately weak

The keeper is a bot. Bots have keys on servers. Servers get compromised. So the
design question isn't *"how do we keep the keeper key safe"* — it's *"what is the
worst thing a stolen keeper key can do?"*

```
   Attacker steals the keeper key. They can:
   
     ✓ call deployIdle()      → moves idle into REGISTERED strategies.
                                 That's... what it was going to do anyway.
     ✓ call rebalance()       → shuffles between REGISTERED strategies.
                                 Costs gas, loses a little to slippage.
     ✓ call setTargets(...)   → changes the mix between REGISTERED strategies.
                                 Bounded by which strategies exist.
     ✓ call harvest()         → claims rewards and compounds them.
                                 Thanks, I guess.
   
     ✗ addStrategy(evilContract)   → REVERTS. Not a keeper function.
     ✗ removeStrategy(...)         → REVERTS.
     ✗ setFees(9999, 9999)         → REVERTS.
     ✗ diamondCut(evilFacet)       → REVERTS.
   
   ══════════════════════════════════════════════════════════════════
    MAXIMUM DAMAGE: griefing. Gas waste and rebalance slippage.
    NOT a drain. The funds cannot leave the strategy set.
   ══════════════════════════════════════════════════════════════════
```

**That's the whole design.** `addStrategy` is the dangerous function — it's the one
that could point at an attacker's contract. So it lives with the timelock, behind a
48-hour delay, where the community can see `addStrategy(0xEVIL)` queued and react.

### 21.3 Why `rebalance` and `setTargets` are keeper functions

A fair question: they change allocation. Isn't that dangerous?

**No — because they're bounded by the registered strategy set.** `setTargets` can
say "80% Aave, 20% Compound" instead of "50/40". Both are strategies governance
already vetted. The keeper is choosing *among approved options*, not *adding new
ones*.

The alternative — routing every rebalance through a 48-hour timelock — would make the
vault unable to react to a rate change or a depeg for two days. **That's a worse
risk than the one it prevents.** Rebalancing must be fast; adding attack surface must
be slow. The split is exactly along that line.

---

<a name="s22"></a>
## §22 · Emergency mode

**This is change #5.** The most subtle access-control rule in the protocol.

### 22.1 The rule

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   SUPER ADMIN may call addStrategy / removeStrategy / rebalance /             ║
║   setTargets / setBuffer   ONLY WHEN   emergency == true.                     ║
║                                                                               ║
║   AND WHILE emergency == true, USERS CANNOT deposit or withdraw.              ║
║                                                                               ║
║   Timelock and keeper are unaffected — they can call their functions          ║
║   at any time, emergency or not.                                              ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

### 22.2 Why these two clauses must go together

The rule looks like two independent restrictions. **It's one idea.**

```
   ┌─────────────────────────────────────────────────────────────────────┐
   │  THE RACE THIS PREVENTS                                             │
   │                                                                     │
   │  Suppose super admin could removeStrategy() during normal operation:│
   │                                                                     │
   │   block N     removeStrategy(compound) starts.                      │
   │               → unwinds 524,848 from Comet                          │
   │               → mid-unwind, slippage hits, totalLiquidity           │
   │                 momentarily reads 519,000                           │
   │                                                                     │
   │   block N     Mallory (same block, higher gas) calls deposit()      │
   │               → buys shares at the DEPRESSED pps                    │
   │                                                                     │
   │   block N+1   unwind completes, totalLiquidity back to 524,848      │
   │               → pps recovers                                        │
   │               → Mallory withdraws, pockets the difference           │
   │                                                                     │
   │  She front-ran an ADMIN ACTION. The admin did nothing wrong.        │
   └─────────────────────────────────────────────────────────────────────┘
```

Freezing user flow while the admin operates makes this structurally impossible.
**There is no user transaction to interleave with.** It's not mitigated, it's
eliminated.

```
   ┌─────────────────────────────────────────────────────────────────────┐
   │  AND THE REVERSE: why emergency must GATE the admin, not just       │
   │  accompany it                                                       │
   │                                                                     │
   │  If super admin could act freely, the "super admin" key becomes a   │
   │  second, un-timelocked governance. The whole point of a 48h delay   │
   │  evaporates: why queue addStrategy() through governance when a      │
   │  single key can do it instantly?                                    │
   │                                                                     │
   │  Requiring emergency==true means using the break-glass key ALWAYS   │
   │  costs something visible: the vault halts. Users see it. The DAO    │
   │  sees it. It cannot be used quietly.                                │
   └─────────────────────────────────────────────────────────────────────┘
```

> **That's the real insight.** Emergency mode isn't a *permission* — it's a *price*.
> The super admin can act, but only by paying a cost that everyone can observe.
> A break-glass key that can be used silently isn't break-glass; it's a backdoor.

### 22.3 The state machine

```
        ┌──────────────────────────────────────────────────────────┐
        │                     NORMAL                               │
        │  ────────────────────────────────────────────────────    │
        │  users:      deposit ✓   withdraw ✓   mint ✓             │
        │  keeper:     deployIdle ✓ harvest ✓ rebalance ✓          │
        │  timelock:   everything ✓                                 │
        │  superAdmin: setEmergency(true) ONLY                      │
        └──────────────────┬───────────────────────────────────────┘
                           │
              setEmergency(true)
              by timelock OR superAdmin
                           │
                           ▼
        ┌──────────────────────────────────────────────────────────┐
        │                    EMERGENCY                             │
        │  ────────────────────────────────────────────────────    │
        │  users:      deposit ✗   withdraw ✗   mint ✗   ← FROZEN  │
        │  keeper:     deployIdle ✗  harvest ✓  rebalance ✓        │
        │  timelock:   everything ✓                                 │
        │  superAdmin: addStrategy ✓   removeStrategy ✓            │
        │              rebalance ✓     setTargets ✓                │
        │              setBuffer ✓     setEmergency(false) ✓       │
        │                                                          │
        │  → surgery happens here, with nobody else in the room    │
        └──────────────────┬───────────────────────────────────────┘
                           │
              setEmergency(false)
              by timelock OR superAdmin
                           │
                           ▼
                    back to NORMAL
```

Note `deployIdle` is disabled in emergency (don't push money *out* while unwinding)
but `harvest` stays enabled (claiming rewards is always safe and may be urgent).

### 22.4 Implementation

```solidity
// AdminFacet

function setEmergency(bool on) external {
    VaultStorage storage vs = LibVaultStorage.s();
    require(msg.sender == vs.timelock || msg.sender == vs.superAdmin, "NOT_AUTHORISED");
    vs.emergency = on;
    emit EmergencySet(on, msg.sender, block.timestamp);
}

/// @dev Timelock any time. Super admin ONLY in emergency.
modifier onlyTimelockOrEmergencyAdmin() {
    VaultStorage storage vs = LibVaultStorage.s();
    require(
        msg.sender == vs.timelock ||
        (msg.sender == vs.superAdmin && vs.emergency),
        "NOT_AUTHORISED"
    );
    _;
}

function addStrategy(address strategy, uint16 targetBps)
    external onlyTimelockOrEmergencyAdmin
{
    VaultStorage storage vs = LibVaultStorage.s();
    require(strategy != address(0), "ZERO_ADDR");
    require(!vs.strategyInfo[strategy].active, "ALREADY_ADDED");
    require(vs.strategies.length < MAX_STRATEGIES, "MAX_STRATEGIES");
    require(IStrategy(strategy).asset() == vs.asset, "ASSET_MISMATCH");
    require(IStrategy(strategy).vault() == address(this), "VAULT_MISMATCH");
    require(targetBps <= BPS, "BPS_TOO_HIGH");

    vs.strategies.push(strategy);
    vs.strategyInfo[strategy] = StrategyInfo({
        active: true, targetBps: targetBps,
        index: vs.strategies.length - 1,
        lastReported: 0, lastHarvest: uint64(block.timestamp)
    });
    emit StrategyAdded(strategy, targetBps);
}

function removeStrategy(address strategy) external onlyTimelockOrEmergencyAdmin {
    VaultStorage storage vs = LibVaultStorage.s();
    require(vs.strategyInfo[strategy].active, "NOT_ACTIVE");
    require(vs.strategies.length > MIN_STRATEGIES, "MIN_STRATEGIES");

    IStrategy(strategy).emergencyExit();          // ← unwind EVERYTHING to base first
    require(IStrategy(strategy).totalLiquidity() == 0, "NOT_EMPTY");

    uint256 i = vs.strategyInfo[strategy].index;
    uint256 last = vs.strategies.length - 1;
    if (i != last) {
        address moved = vs.strategies[last];
        vs.strategies[i] = moved;
        vs.strategyInfo[moved].index = i;
    }
    vs.strategies.pop();
    delete vs.strategyInfo[strategy];
    emit StrategyRemoved(strategy);
}
```

And the user-facing gate:

```solidity
modifier whenNotEmergency() {
    require(!LibVaultStorage.s().emergency, "EMERGENCY");
    _;
}
// applied to: mint(), deposit(), mintAndDeposit(), withdraw(), redeem(), deployIdle()
```

### 22.5 The honest objection

> **"Freezing withdrawals is user-hostile. Users should always be able to exit."**

This is a real argument and it deserves a real answer.

**The counter:** during a strategy unwind, `totalLiquidity()` is *mid-flight*. Letting
someone withdraw against a mid-unwind pps means they either:
- extract more than their share (theft from everyone who stayed), or
- extract less (they're robbed by the timing).

**Both are worse than a bounded pause.** The user who withdraws at a wrong price loses
permanently. The user who waits 20 minutes loses nothing.

**But the objection is right about one thing: an unbounded pause is a rug.** So:

```solidity
// RECOMMENDED HARDENING — not yet in the spec above
uint256 public constant MAX_EMERGENCY_DURATION = 24 hours;
uint256 public emergencyStartedAt;

function setEmergency(bool on) external {
    VaultStorage storage vs = LibVaultStorage.s();
    require(msg.sender == vs.timelock || msg.sender == vs.superAdmin, "NOT_AUTHORISED");
    if (on && !vs.emergency) vs.emergencyStartedAt = block.timestamp;
    vs.emergency = on;
    emit EmergencySet(on, msg.sender, block.timestamp);
}

/// @notice ANYONE can end an emergency that has overstayed its welcome.
///         The break-glass key cannot hold the vault hostage.
function forceEndEmergency() external {
    VaultStorage storage vs = LibVaultStorage.s();
    require(vs.emergency, "NOT_EMERGENCY");
    require(block.timestamp > vs.emergencyStartedAt + MAX_EMERGENCY_DURATION, "TOO_EARLY");
    vs.emergency = false;
    emit EmergencyForceEnded(msg.sender, block.timestamp);
}
```

> **Add this.** It converts "trust the super admin to un-pause" into "the pause
> expires on its own." A 24-hour ceiling is long enough for any legitimate surgery
> and short enough that it can't be used as a hostage. The permissionless
> `forceEndEmergency` means users don't even need the admin to cooperate.

---

<a name="s23"></a>
## §23 · Worked example: a full day

Everything above, in one narrative. **All numbers verified.**

### Setup

```
   VAULT: Artha USDC-Conservative (ERC-721 "aUSDC-C")
   ────────────────────────────────────────────────────────────
   asset            USDC (6 decimals), scale = 1e12
   strategies       AaveUsdcStrategy    target 50%
                    CompoundUsdcStrategy target 40%
   buffer           10% of totalLiquidity
   entryFeeBps      30    (0.30%)
   perfFeeBps       1,000 (10% of profit)
   rewardRatio      5e17  (50%/yr user ARTHA)
   
   REFERRAL: Bob's code, tier 2 → tierRatio 3e17, vault rewardRatio 1e18
```

### 08:00 — Alice opens a position

```
   Alice: setTraderCode(BOB_CODE)          ← one time, permanent
   Alice: vault.mintAndDeposit(10,000 USDC)
   
   ┌──────────────────────────────────────────────────────────────┐
   │ 1. mint → tokenId #7, ownerOf[7] = alice                     │
   │ 2. pull 10,000 USDC from alice                               │
   │ 3. entry fee   = 10,000 × 30/10,000 =     30.00 → accruedFees│
   │    net         =                       9,970.00              │
   │ 4. settle(alice) → principal is 0, nothing to bank           │
   │ 5. prior       = totalLiquidity() − 9,970 = 0  (first!)      │
   │    shares      = 9,970e6 × (0 + 1e6) / (0 + 1)               │
   │                = 9,970,000,000,000,000                       │
   │    positions[7].shares    = 9.97e15                          │
   │    positions[7].costBasis = 9,970.00                         │
   │ 6. userPrincipalNorm[alice] = 9,970e6 × 1e12 = 9.97e21       │
   │ 7. rewardSystem.notifyDeposit(vault, alice, 9,970)           │
   │    referralVault.notifyDeposit(vault, alice, 9,970)          │
   │      → resolves BOB_CODE, credits Bob's tier-2 lane          │
   │ 8. 9,970 USDC sits IDLE                                      │
   └──────────────────────────────────────────────────────────────┘
   
   pps = 9,970e6 / (9.97e15 / 1e6) = 1.000000  ✓  (pps starts at 1.0)
```

### 11:30 — Carol adds to Alice's position (change #8)

```
   Carol: vault.deposit(7, 5,000)      ← Carol pays, ALICE benefits
   
   ┌──────────────────────────────────────────────────────────────┐
   │ owner = ownerOf[7] = ALICE       ← NOT msg.sender!           │
   │ pull 5,000 from CAROL                                        │
   │ fee = 15.00 → accruedFees;  net = 4,985.00                   │
   │                                                              │
   │ settle(ALICE):                                               │
   │   dt = 3.5h = 12,600s                                        │
   │   acc += 5e17 × 12,600 × 1e18 / (1e18 × 31,104,000)          │
   │       += 2.0254e14                                           │
   │   accumulated = 9.97e21 × 2.0254e14 / 1e18 = 2.0193e18       │
   │   pending     = 2.0193e18 − 0 → BANKED: 2.019 ARTHA to ALICE │
   │                                                              │
   │ prior  = 9,970 (totalLiquidity 14,955 − 4,985)               │
   │ shares = 4,985e6 × (9.97e15 + 1e6) / (9,970e6 + 1)           │
   │        = 4,985,000,000,000,000                               │
   │                                                              │
   │ positions[7].shares    = 9.97e15 + 4.985e15 = 1.4955e16      │
   │ positions[7].costBasis = 9,970 + 4,985      = 14,955.00      │
   │ userPrincipalNorm[ALICE] = 9.97e21 + 4.985e21 = 1.4955e22    │
   │                                                              │
   │ notifyDeposit(vault, ALICE, 4,985)  ← ALICE, not Carol       │
   └──────────────────────────────────────────────────────────────┘
   
   Carol paid 5,000. Alice's position grew. Alice's ARTHA accrues on it.
   Carol earns nothing. That's the design — she made a gift.
```

### 23:00 — Keeper deploys

```
   keeper: vault.deployIdle()
   
   idle           = 14,955.00
   totalLiquidity = 14,955.00
   bufferFloor    = 14,955 × 10% =  1,495.50
   deployable     = 14,955 − 1,495.50 = 13,459.50
   
   ┌──────────────────────────────────────────────────────────────┐
   │ Aave      = 13,459.50 × 5000/10,000 = 6,729.75               │
   │ Compound  = 13,459.50 × 4000/10,000 = 5,383.80               │
   │ (1000 bps unallocated → stays idle)                          │
   └──────────────────────────────────────────────────────────────┘
   
   AFTER:
     Aave         6,729.75
     Compound     5,383.80
     idle         2,841.45     (= 1,495.50 buffer + 1,345.95 unallocated)
     ─────────────────────
     TOTAL       14,955.00     ← UNCHANGED ✓  pps unchanged ✓
```

### Day 90 — the position matures

```
   Strategy performance over 90 days:
   ┌──────────────────────────────────────────────────────────────┐
   │ AAVE      6,729.75 → 6,830.70   (aToken rebase, +1.5%)       │
   │                                                              │
   │ COMPOUND  invested   5,383.80                                │
   │           interest      80.76   (in USDC — already base)     │
   │           COMP           1.85 × 42 = 77.70                   │
   │                              × 0.98 haircut = 76.15          │
   │           totalLiquidity = 5,383.80 + 80.76 + 76.15          │
   │                          = 5,540.71                          │
   │                                                              │
   │ IDLE      2,841.45  (earns nothing, counted at face value)   │
   └──────────────────────────────────────────────────────────────┘
   
   totalLiquidity = 6,830.70 + 5,540.71 + 2,841.45 = 15,212.86
   (accruedFees of 45.00 already swept — not double-counted)
   
   pps = 15,212.86e6 / (1.4955e16 / 1e6) = 1.0172419   (+1.72%)
```

### Day 90 — Alice withdraws everything

```
   alice: vault.withdraw(7, 15,212.86, alice)
   
   ┌──────────────────────────────────────────────────────────────┐
   │ 1. require(msg.sender == ownerOf[7])  ✓ alice                │
   │                                                              │
   │ 2. settle(alice):                                            │
   │      total ARTHA earned over the period (§ below)            │
   │                                                              │
   │ 3. value     = (1.4955e16/1e6) × 1.0172419 / 1e6 = 15,212.86 │
   │    fraction  = 15,212.86 / 15,212.86 = 1.00                  │
   │    basisUsed = 14,955.00 × 1.00      = 14,955.00             │
   │    profit    = 15,212.86 − 14,955.00 =    257.86             │
   │    fee (10%) =    257.86 × 0.10      =     25.79 → treasury  │
   │    payout    = 15,212.86 − 25.79     = 15,187.07             │
   │                                                              │
   │ 4. _ensureLiquidity(15,212.86):                              │
   │      idle 2,841.45 < need → pull 6,830.70 from Aave          │
   │                          → pull 5,540.71 from Compound       │
   │                            (harvests COMP → USDC on exit)    │
   │      idle now 15,212.86 ✓                                    │
   │                                                              │
   │ 5. positions[7].shares    = 0                                │
   │    positions[7].costBasis = 0                                │
   │                                                              │
   │ 6. userPrincipalNorm[alice] −= 14,955e6 × 1e12 → 0           │
   │                                  ▲                           │
   │                     basisUsed, NOT the 15,212.86 value!      │
   │                                                              │
   │ 7. notifyWithdraw(vault, alice, 14,955)  ← both systems      │
   │ 8. transfer 15,187.07 USDC → alice                           │
   └──────────────────────────────────────────────────────────────┘
```

### The ARTHA ledger

```
   ALICE's user rewards (rewardRatio 5e17 = 50%/yr):
   ─────────────────────────────────────────────────────────────
   9,970 for 90 days:      50% × 9,970 × 90/360      = 1,246.25
   4,985 for 89.52 days:   50% × 4,985 × 89.52/360   =   619.81
     (Carol deposited 11:30 → 89d 12.5h = 89.52 days)
                                                    ───────────
                                          TOTAL     = 1,866.06 ARTHA
   
   claim:  userRewardVault.claimAll(alice)   ← ONE TX (change #9)
   
   
   BOB's referral reward (tier 2 = 3e17, vault ratio 1e18):
   ─────────────────────────────────────────────────────────────
   rewardPerYear = 14,955e12 × 3e17 × 1e18 / 1e36
                 = 1.4955e22 × 3e17 / 1e18 = 4.4865e21 = 4,486.50/yr
   
   (approximating both deposits as full-90-day for readability)
   accrued ≈ 4,486.50 × 90/360 = 1,121.63 ARTHA
   
   claim:  referralVault.claimAll(BOB_CODE, bob)
```

### Final scoreboard

```
   ╔═══════════════════════════════════════════════════════════════════╗
   ║  ALICE                                                            ║
   ║    put in (own)        10,000.00                                  ║
   ║    put in (Carol's)     5,000.00   ← a gift; Alice keeps it       ║
   ║    ─────────────────────────────                                  ║
   ║    total in            15,000.00                                  ║
   ║    got out             15,187.07 USDC                             ║
   ║    + earned             1,866.06 ARTHA                            ║
   ║    net USDC            +  187.07  (+1.25% over 90d, after fees)   ║
   ╠═══════════════════════════════════════════════════════════════════╣
   ║  BOB (referrer)                                                   ║
   ║    put in                   0.00                                  ║
   ║    earned               1,121.63 ARTHA                            ║
   ╠═══════════════════════════════════════════════════════════════════╣
   ║  CAROL                                                            ║
   ║    put in               5,000.00                                  ║
   ║    got out                  0.00   ← she made a gift, knowingly   ║
   ╠═══════════════════════════════════════════════════════════════════╣
   ║  TREASURY                                                         ║
   ║    entry fees   30.00 + 15.00 =    45.00 USDC                     ║
   ║    perf fee                        25.79 USDC                     ║
   ║    ────────────────────────────────────────                       ║
   ║    total                           70.79 USDC                     ║
   ╠═══════════════════════════════════════════════════════════════════╣
   ║  ARTHA PAID                                                       ║
   ║    from UserRewardVault         1,866.06  (pool A)                ║
   ║    from ReferralVault           1,121.63  (pool B)                ║
   ║    ────────────────────────────────────────                       ║
   ║    two pools, two caps, zero shared state                         ║
   ╚═══════════════════════════════════════════════════════════════════╝
```

---

<a name="s24"></a>
## §24 · Invariants & audit checklist

### 24.1 Invariants — every one of these should be a fuzz test

```
   ACCOUNTING
   ──────────────────────────────────────────────────────────────────────
   I1   totalShares == Σ positions[id].shares  for all minted ids
   I2   totalLiquidity() >= 0 always; reverts never on a healthy vault
   I3   Σ positions[id].costBasis <= Σ (net deposits) − Σ (basis withdrawn)
   I4   convertToAssets(convertToShares(x)) <= x          (rounding favours vault)
   I5   pps is monotonically non-decreasing ABSENT strategy loss
   I6   deployIdle() does not change totalLiquidity()      ← §10.2
   I7   harvest() does not change totalLiquidity() by more than slippage  ← §8.8
   I8   accruedFees is excluded from totalLiquidity()      ← §12.4

   POSITIONS
   ──────────────────────────────────────────────────────────────────────
   I9   only ownerOf(id) can withdraw from id
   I10  anyone can deposit into any existing id
   I11  transferring id moves shares + basis, NOT unclaimed ARTHA  ← §20.4
   I12  burn(id) requires shares == 0

   FEES
   ──────────────────────────────────────────────────────────────────────
   I13  perf fee == 0 whenever assets <= basisUsed          ← §11.4 case C
   I14  entry fee <= MAX_ENTRY_FEE_BPS; perf fee <= MAX_PERF_FEE_BPS
   I15  withdrawing 100% once == withdrawing 25% four times (fee-wise) ← §11.3
   I16  costBasis == NET credited, never gross              ← §12.2

   REWARDS
   ──────────────────────────────────────────────────────────────────────
   I17  rewardRatio == 0  ⇒  pendingReward == 0 for every user  ← change #4
   I18  Σ credited <= maxDistributable            (the HARD CAP)
   I19  Σ claimed  <= Σ credited
   I20  userPrincipalNorm[v][u] == Σ costBasis of u's positions in v × scale
   I21  Σ userPrincipalNorm[v][*] == vaultMeta[v].totalPrincipalNorm
   I22  1 position of 17,800 earns == 3 positions summing 17,800  ← §20.3
   I23  changing rewardRatio is NEVER retroactive           ← §18.4
   I24  settle() twice in the same block banks zero the second time

   ACCESS
   ──────────────────────────────────────────────────────────────────────
   I25  superAdmin CANNOT addStrategy while emergency == false   ← change #5
   I26  users CANNOT deposit/withdraw while emergency == true    ← change #5
   I27  keeper CANNOT addStrategy / setFees / diamondCut ever
   I28  notifyDeposit(v,...) reverts unless msg.sender == v      ← §18.7
   I29  MIN_STRATEGIES <= strategies.length <= MAX_STRATEGIES
```

### 24.2 The bugs this design already fixes

| # | Bug | Where it was | Fix |
|---|---|---|---|
| 1 | First-deposit share dilution | v3 `LibShares.convertToShares` priced against post-deposit assets | `convertToSharesOnDeposit()` subtracts the incoming amount — §9.2 |
| 2 | Claim auth in delegatecall | v3 `RewardTracker.claim` gated on `msg.sender == manager`, but `claimFor` runs in vault context | `msg.sender == manager \|\| isVault[msg.sender]` |
| 3 | **Harvest front-run** | v3 `totalAssets()` ignored unclaimed COMP → pps jumped at harvest | Count reward tokens continuously — §8.3 |
| 4 | **Cross-vault reward forgery** | `ReferralVaultManager.onlyCaller` never checks `msg.sender == vault` | Bind the caller to the vault arg — §18.7 |
| 5 | Reward principal underflow on profit | Using `assets` instead of `basisUsed` in `notifyWithdraw` | Always use `basisUsed` — §11.5 step 7 |
| 6 | Fees inflating pps | `accruedFees` counted in `balanceOf(this)` | Subtract in `totalLiquidity()` — §12.4 |

### 24.3 Audit focus areas, ranked

```
   ┌────────────────────────────────────────────────────────────────────┐
   │ 1. totalLiquidity()  ── §8                                         │
   │    Everything depends on it. Check EVERY strategy's                │
   │    _pendingRewardsInBase(). One missing reward token = a           │
   │    permanent, silent, exploitable mispricing.                      │
   ├────────────────────────────────────────────────────────────────────┤
   │ 2. The oracle staleness check  ── §16.2                            │
   │    Two lines. Their absence is a drain.                            │
   ├────────────────────────────────────────────────────────────────────┤
   │ 3. onlyCaller(vault) binding  ── §18.7                             │
   │    In BOTH reward stacks. Currently missing in the referral one.   │
   ├────────────────────────────────────────────────────────────────────┤
   │ 4. settle → change → recheckpoint ordering  ── §18.6               │
   │    Every single place principal changes: deposit, withdraw,        │
   │    transfer, ratio change, tier change. Miss one and rewards       │
   │    are silently wrong.                                             │
   ├────────────────────────────────────────────────────────────────────┤
   │ 5. Rounding direction  ── §9, §11                                  │
   │    Shares round UP on burn, DOWN on mint. Assets round DOWN on     │
   │    payout. Every rounding must favour the vault.                   │
   ├────────────────────────────────────────────────────────────────────┤
   │ 6. Emergency gating  ── §22                                        │
   │    Both halves. superAdmin gated ON emergency; users gated OFF.    │
   ├────────────────────────────────────────────────────────────────────┤
   │ 7. Diamond storage collisions  ── §5                               │
   │    Every facet reads one AppStorage at one fixed slot. Any facet   │
   │    declaring its own state variables is a bug.                     │
   └────────────────────────────────────────────────────────────────────┘
```

---

<a name="s25"></a>
## §25 · Build order

### Phase 1 — the vault core

```
   1. LibVaultStorage        AppStorage, constants
   2. LibShares              offset math, convertToSharesOnDeposit
   3. Diamond + LibDiamond   proxy, cut, loupe
   4. PositionFacet          ERC-721 over AppStorage, mint/burn
   5. AccountingFacet        totalLiquidity, pps, views
   6. DepositFacet           deposit (anyone), entry fee, basis
   7. WithdrawFacet          withdraw (owner), profit fee, waterfall
   8. KeeperFacet            deployIdle, rebalance, setTargets
   9. AdminFacet             add/remove strategy, emergency gating

   TEST: deposit → shares → withdraw → correct payout.
         NO strategies yet. Use a vault with 100% idle.
         This isolates the share math completely.
```

### Phase 2 — strategies (no new infra)

```
   10. BaseStrategy               interface + totalLiquidity skeleton
   11. AaveUsdcStrategy           Shape 1. The reference.
   12. ERC4626WrapperStrategy     Shape 2. Unlocks sUSDS/sUSDe/wstETH/nested.
   13. MockAave / MockERC4626     with accrueTo() for yield simulation

   TEST: deposit → deployIdle → simulate yield → pps rises → withdraw.
         Still no oracle, no swap. Ship this. It's a real product.
```

### Phase 3 — rewards

```
   14. ArthaToken                 ERC20Votes, pre-mint the two pools
   15. UserRewardManager          access control
   16. UserRewardSystem           accrual, address-keyed
   17. UserRewardVault            cap, credit, claimAll
   18. Wire notify* into Deposit/Withdraw/Transfer facets

   TEST: I17 (ratio 0 → nothing), I18 (hard cap), I22 (1 position == 3),
         and the day-90 bank-before-change sequence from §18.6.
```

### Phase 4 — infrastructure

```
   19. ChainlinkOracle            with the staleness check
   20. SwapAdapter                oracle-priced minOut
   21. BaseCompoundStrategy       Shape 1+3
   22. CompoundUsdcStrategy       COMP → WETH → USDC
   23. CompoundWethStrategy       COMP → WETH

   TEST: harvest does NOT move pps (I7). Sandwich attempt reverts.
         This is where §8 finally earns its keep.
```

### Phase 5 — governance & referral

```
   24. ArthaTimelock + ArthaGovernor
   25. Hand every vault's `timelock` to the Timelock
   26. Fix ReferralVaultManager.onlyCaller  ← §18.7. DO THIS FIRST.
   27. Wire referralVault.notify* into the facets
   28. Register vaults in BOTH reward systems
```

### Phase 6 — advanced

```
   29. CurveConvexStrategy    Shape 2+3, two reward tokens
   30. PendlePtStrategy       Shape 4, time-dependent
   31. LooperStrategy         leverage — model the unwind under stress
   32. RwaQueueStrategy       queued exit — size against the buffer
```

### What to ship first

> **Phases 1–2 are a complete, honest product.** A USDC vault that lends to Aave and
> holds sUSDS, with NFT positions, an entry fee, and a profit-only exit fee. No
> oracle, no swap, no reward token, no governance. It works, it's auditable in a
> week, and it has *zero* Shape-3 risk.
>
> Everything after that is optional yield and optional complexity. Ship the boring
> version, prove the share math against real money, then add the parts that need an
> oracle.

---

## Appendix A — Constants

```solidity
uint256 constant BPS               = 10_000;
uint256 constant ACC               = 1e18;
uint256 constant YEAR              = 360 days;      // 31,104,000 seconds
uint8   constant OFFSET            = 6;             // virtual shares
uint256 constant RATIO_ONE         = 1e18;          // 100%
uint256 constant RATIO_SQ          = 1e36;          // for tier × vault products
uint8   constant MAX_TIERS         = 8;

uint256 constant MIN_STRATEGIES    = 1;
uint256 constant MAX_STRATEGIES    = 5;

uint16  constant MAX_ENTRY_FEE_BPS = 100;           // 1.00%
uint16  constant MAX_PERF_FEE_BPS  = 2_000;         // 20% of profit
uint16  constant DEFAULT_HAIRCUT   = 200;           // 2% on unrealised rewards
uint256 constant MAX_STALENESS     = 3600;          // 1 hour
uint256 constant MAX_EMERGENCY_DUR = 24 hours;      // recommended, §22.5
```

## Appendix B — The eleven changes → where they live

| # | Change | Sections |
|---|---|---|
| 1 | No PositionManager; vault is its own ERC-721 | §3, §4, §6 |
| 2 | Multiple positions per user per vault | §6.1, §6.2, §6.3 |
| 3 | rewardRatio keyed by vault address | §18.4, §17.2 |
| 4 | rewardRatio == 0 → no ARTHA | §18.4, §18.6, I17 |
| 5 | Emergency gates super-admin surgery | §7, §22 |
| 6 | totalLiquidity = invested + interest + rewards-in-base | **§8** (the core) |
| 7 | Entry fee + profit-only exit fee | §11, §12 |
| 8 | Anyone deposits, owner withdraws | §6.4, §11.5 |
| 9 | ARTHA keyed by address, not tokenId | §20 |
| 10 | User rewards split System + Vault | §18 |
| 11 | One mechanism → many strategy contracts | §14 |

## Appendix C — Open questions for governance

1. **Buffer size.** 10% is a guess. It should be a function of the illiquid sleeve —
   if you add an RWA strategy with a 7-day queue, 10% is far too low.
2. **Haircut per strategy.** 2% is right for COMP. It's wrong for a thin reward token
   with a $200k pool. Make it per-strategy and set it from a liquidity model.
3. **`updateDebt` vs `rebalance`.** §10.3 recommends adding the Yearn-shaped
   primitive. It's strictly better for partial moves. Worth doing before Phase 6.
4. **`MAX_EMERGENCY_DURATION`.** §22.5 recommends 24h + a permissionless
   `forceEndEmergency`. **This should be in v4, not deferred.**
5. **Referral retirement.** The spec says "deactivate all codes, pause, sweep." That
   loop is unbounded over codes. Needs a paginated implementation before launch.

---

*End of specification.*