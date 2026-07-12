# Artha Protocol — NFT-Position Architecture (v3)

> **What changed from v2.** Three things:
> 1. **Positions are NFTs, not ERC-20 shares.** When a user first deposits, the protocol mints them **one ERC-721** ("position NFT"). Every vault assigns that `tokenId` its slice of the vault (shares in the strategies the vault runs). The NFT owner is the only one who can withdraw principal or claim rewards — and because it's an NFT, the whole position is **tradable**: sell the NFT, sell the portfolio.
> 2. **Users now earn ARTHA directly** (not only referrers). Each vault has a `rewardRatio ∈ [0, 1e18]`. ARTHA is **pre-minted** into a fixed pool; a user's NFT accrues ARTHA on *how much* they have invested × *how long*. When the whole pool has been allocated, governance sets every `rewardRatio` to `0` and accrual stops.
> 3. **Two central "files" govern rewards.** `RewardConfig` holds the per-vault ratios (read on every accrual); `RewardTracker` records how much ARTHA each NFT has earned **per vault** and enforces a hard **global cap** — the sum credited across all vaults can never exceed the pre-minted pool.
>
> The v2 referral system is **unchanged and runs in parallel**: a referred deposit still pays the *referrer*; the new system pays the *depositor*. Both draw from ARTHA pools with their own caps.

---

## Table of contents
1. [The shift in one picture](#s1)
2. [Core idea: a position is an NFT](#s2)
3. [Contract map & responsibilities](#s3)
4. [The deposit → NFT → end-of-day-deploy flow](#s4)
5. [Per-vault share accounting (principal + strategy yield)](#s5)
6. [User ARTHA rewards — the new engine](#s6)
7. [The two central files: `RewardConfig` and `RewardTracker`](#s7)
8. [End-of-day strategy deployment](#s8)
9. [Access control & the call graph](#s9)
10. [Trading the position NFT](#s10)
11. [Reward math + worked example](#s11)
12. [Data structures per contract](#s12)
13. [Deployment & integration](#s13)
14. [Invariants & audit checklist](#s14)

---

<a name="s1"></a>
## 1. The shift in one picture

```
        v2 (shares)                                v3 (this doc — NFT positions)
 user ──deposit──► USDC Vault                 user ──deposit──► PositionManager
        mints ERC-20 vault shares                    mints ONE ERC-721 (first time)
        user holds shares                            manager routes into the vault
                                                     vault assigns tokenId its shares
                                                     vault accrues ARTHA to tokenId
                                                     NFT owner withdraws + claims
                                                     NFT is transferable = tradable
```

The user never holds ERC-20 shares. They hold **one NFT** whose id maps to: shares in each vault (principal + strategy yield) **and** accrued ARTHA. Everything is assigned to the `tokenId`.

---

<a name="s2"></a>
## 2. Core idea: a position is an NFT

- **One NFT per user.** Minted on the first deposit into *any* vault. Every later deposit — same vault or a different one — is assigned to the **same** `tokenId`. So a single NFT aggregates the user's entire Artha portfolio.
- **The NFT owns two kinds of value per vault:**
  - **Vault shares** — the tokenId's claim on that vault's assets (its deposited principal *plus* the strategy yield that principal has earned). Tracked as internal, non-transferable shares keyed by `tokenId`.
  - **Accrued ARTHA** — the reward the tokenId has earned for keeping capital in that vault, tracked in the central `RewardTracker`.
- **Only the current NFT owner** can withdraw principal or claim ARTHA. Transfer the NFT → the new owner inherits *both* the shares and the unclaimed ARTHA.
- **Variant (not the default):** if you want to sell *just* the USDC position and keep the DAI one, mint **one NFT per (user, vault)** instead of per user. Same contracts, different mint key. The default below is one-NFT-per-user because your description ("later we just assign to that id") implies a single reused id.

---

<a name="s3"></a>
## 3. Contract map & responsibilities

```
artha-v3/
├── PositionManager.sol      # user entry + the ERC-721. Mints the NFT (1st deposit),
│                            # routes deposits/withdrawals/claims to the right vault.
│                            # The ONLY external entry point for users.
├── ArthaVault.sol           # one per base token (USDC, DAI, WETH…). Holds strategy
│                            # shares; tracks per-tokenId vault shares; accrues ARTHA
│                            # per tokenId; batches end-of-day deployment. Callable
│                            # ONLY by the PositionManager (user ops) + keeper (deploy).
├── RewardConfig.sol         # "the ratio file": rewardRatio[vault] ∈ [0,1e18], set by
│                            # governance. Read by every vault when accruing ARTHA.
├── RewardTracker.sol        # "the user reward file": earnedByVault[tokenId][vault] +
│                            # a HARD global cap (≤ pre-minted ARTHA). Credits + pays.
├── strategies/              # BaseStrategy + AaveV3 / CompoundV3 / ERC4626 / CurveConvex
│                            # (ERC-4626; they mint shares TO the vault).
├── referral/                # v2 stack, unchanged (rewards the referrer, in parallel).
└── gov/  { ArthaToken, ArthaTimelock, ArthaGovernor }
```

Who talks to whom (enforced):

| Contract | Callable by | Never callable by |
|---|---|---|
| `PositionManager` | anyone (users) | — |
| `ArthaVault` (user ops) | **only** `PositionManager` | users directly |
| `ArthaVault` (deploy) | **only** keeper/executor | users |
| strategies (`deposit`/`withdraw`) | **only** their vault | manager, users |
| `RewardConfig` (setters) | **only** Timelock | — |
| `RewardTracker` (credit) | **only** registered vaults | — |
| `RewardTracker` (setCap) | **only** Timelock | — |

---

<a name="s4"></a>
## 4. The deposit → NFT → end-of-day-deploy flow

```
1. user calls  PositionManager.deposit(vault = USDC-vault, amount = 1000)
2. Manager pulls 1000 USDC; if the user has no NFT yet → _mint(user) → tokenId
3. Manager calls  USDC-vault.depositFor(tokenId, 1000, user)      (onlyManager)
4. Vault:
     a. _settleReward(tokenId)         → bank ARTHA accrued so far into RewardTracker
     b. shares = convertToShares(1000) → mint internal shares to tokenId
     c. rewardPrincipal[tokenId] += 1000 (normalised) ; re-checkpoint rewardDebt
     d. USDC sits IDLE in the vault (not deployed yet)
5. …more users deposit through the day, all landing as idle…
6. end of day: keeper calls  USDC-vault.deployIdle()             (onlyKeeper)
     → allocates idle across the vault's 1–5 strategies by governance target ratios
     → each strategy.deposit(amount, vault)  → the STRATEGY mints ERC-4626 shares
       TO THE VAULT. The vault now holds strategy shares; idle → deployed.
7. yield accrues inside the strategies; ARTHA accrues to each tokenId continuously
8. withdraw:  PositionManager.withdraw(tokenId, vault, assets)   (onlyNFTowner)
     → vault settles ARTHA, frees `assets` from strategies if idle short, burns the
       tokenId's shares pro-rata, reduces rewardPrincipal, returns USDC to the owner
9. claim:     PositionManager.claimRewards(tokenId, to)          (onlyNFTowner)
     → RewardTracker pays the tokenId's earned ARTHA from the pre-minted pool
```

**Why deposits sit idle until end-of-day:** batching one deployment per day (a) saves gas vs deploying every deposit, and (b) removes per-deposit front-running. Share accounting is *unaffected* by the timing, because idle USDC is counted in `totalAssets` exactly like deployed USDC — deploying just swaps "idle" for "strategy shares of equal value."

---

<a name="s5"></a>
## 5. Per-vault share accounting (principal + strategy yield)

Each `ArthaVault` behaves like an ERC-4626 vault, except **shares are internal balances keyed by `tokenId`** instead of a transferable ERC-20:

```solidity
mapping(uint256 tokenId => uint256) public shares;   // tokenId's share of THIS vault
uint256 public totalShares;
uint8   public constant OFFSET = 6;                  // inflation-attack defense (virtual)
```

- **Total assets** `A = idleAsset + Σ strategy.convertToAssets(vaultStrategyShares)`. The vault reads each strategy's ERC-4626 value of the shares the strategy minted to the vault.
- **Deposit** mints `s = assets·(totalShares + 10^OFFSET) / (A + 1)` to the `tokenId` (OZ-style rounding + virtual offset so a first-deposit donation can't inflate a victim's mint to zero).
- **Withdraw** returns `assets = s·A / totalShares` and burns `s` from the `tokenId`.
- **Strategy yield reaches the user automatically:** as the strategies earn, `A` rises, so `pps = A/totalShares` rises, so every tokenId's shares are worth more. No reward logic needed for yield — only for the *ARTHA bonus* (§6).

The vault "assigns values to the NFT" = it writes `shares[tokenId]` and (for rewards) credits the tracker.

---

<a name="s6"></a>
## 6. User ARTHA rewards — the new engine

On top of strategy yield, each tokenId earns **ARTHA** for keeping capital in a vault. This is the exact MasterChef accumulator from the referral system, now keyed by `tokenId` and driven by a **single per-vault ratio**.

**The reward base is the deposited *amount* (normalised principal), not shares** — so the reward is strictly proportional to how much the user put in, independent of the price-per-share at deposit time.

Per vault the accrual state is:

```solidity
uint256 accArthaPerPrincipal;   // scaled by ACC (1e18)
uint256 lastUpdate;
mapping(uint256 => uint256) rewardPrincipalNorm; // tokenId → normalised principal (18dp)
mapping(uint256 => uint256) rewardDebt;          // tokenId → checkpoint
```

Accrual over `dt` seconds (rate read from `RewardConfig`):

```
accArthaPerPrincipal += rewardRatio[vault] · dt · ACC / (1e18 · YEAR)
earned(tokenId)       = rewardPrincipalNorm[tokenId] · accArthaPerPrincipal / ACC − rewardDebt
```

- `rewardRatio ∈ [0,1e18]`: `1e18` = **100% of principal per year in ARTHA**, `5e17` = 50%/yr, `0` = off.
- **Bank-before-change:** every deposit/withdraw calls `_settleReward(tokenId)` *first* (moves accrued ARTHA into the tracker), then changes `rewardPrincipalNorm`, then re-checkpoints — so a growing position earns on the new amount going forward and a shrinking one keeps everything already earned. Identical guarantee to the referral engine.
- **Non-retroactive ratio changes:** governance changing `rewardRatio[vault]` advances that vault's accumulator to `now` before writing the new rate (old rate up to the change, new after).
- **Rewards go to the NFT owner:** accrual is on the `tokenId`; whoever holds the NFT at claim time is paid. A transfer moves the unclaimed ARTHA with the position.

Settlement credits the central tracker (capped):

```solidity
function _settleReward(uint256 tokenId) internal {
    _updateAccumulator();                                  // advance acc to now
    uint256 acc = accArthaPerPrincipal;
    uint256 accumulated = rewardPrincipalNorm[tokenId] * acc / ACC;
    uint256 pending = accumulated - rewardDebt[tokenId];   // monotonic → no underflow
    if (pending > 0) rewardTracker.credit(tokenId, address(this), pending); // capped inside
    rewardDebt[tokenId] = accumulated;
}
```

---

<a name="s7"></a>
## 7. The two central files: `RewardConfig` and `RewardTracker`

### 7.1 `RewardConfig` — the ratio file
Governance's single source of truth for per-vault reward rates. Vaults **read** it every accrual.

```solidity
mapping(address vault => uint256) public rewardRatio; // 0 … 1e18
function setRewardRatio(address vault, uint256 ratio) external onlyTimelock {
    require(ratio <= 1e18, "ratio>1e18");
    IArthaVault(vault).syncReward();   // advance the vault's accumulator FIRST (non-retroactive)
    rewardRatio[vault] = ratio;
}
function stopAll(address[] calldata vaults) external onlyTimelock { /* set each to 0 */ }
```
When the whole ARTHA pool is distributed, call `stopAll` → every vault's accrual halts. (The tracker's cap is the *hard* stop; this is the *clean* stop.)

### 7.2 `RewardTracker` — the user-reward file with the global cap
Records how much ARTHA each NFT earned **per vault**, enforces the pool cap, and pays claims. This is the "central contract that stores all the users' rewards to every vault," and the "max value that cannot exceed all distributed rewards."

```solidity
IERC20  public immutable artha;
uint256 public maxDistributable;   // = ARTHA pre-minted into the user-reward pool (the CAP)
uint256 public totalDistributed;   // running sum credited across ALL nfts and vaults
uint256 public totalClaimed;

mapping(uint256 => mapping(address => uint256)) public earnedByVault; // tokenId → vault → ARTHA
mapping(uint256 => uint256) public totalEarned;                       // tokenId → Σ across vaults
mapping(uint256 => uint256) public claimed;                           // tokenId → claimed

mapping(address => bool) public isVault;   // only registered vaults may credit

/// @notice Vault-only. Credits reward to a tokenId, hard-capped at the pool.
function credit(uint256 tokenId, address vault, uint256 amount) external {
    require(isVault[msg.sender] && msg.sender == vault, "!vault");
    uint256 room = maxDistributable - totalDistributed;      // never exceed the pool
    if (amount > room) amount = room;
    if (amount == 0) return;
    totalDistributed += amount;
    earnedByVault[tokenId][vault] += amount;
    totalEarned[tokenId] += amount;
}

/// @notice Manager-only (checks NFT ownership). Pays the tokenId's ARTHA.
function claim(uint256 tokenId, address to, uint256 amount) external onlyManager {
    uint256 owed = totalEarned[tokenId] - claimed[tokenId];
    require(amount <= owed, "exceeds earned");
    claimed[tokenId] += amount;
    totalClaimed += amount;
    artha.safeTransfer(to, amount);
}
```

**The cap is absolute:** `Σ credited = totalDistributed ≤ maxDistributable`, and `maxDistributable` = the ARTHA actually sitting in the pool. So the protocol can never promise more ARTHA than it holds — the exact "cannot exceed all distributed rewards from all vaults" guarantee. Once `totalDistributed == maxDistributable`, `credit` becomes a no-op (accrual still runs but pays nothing) — which is the signal to `stopAll` the ratios.

---

<a name="s8"></a>
## 8. End-of-day strategy deployment

Deposits accumulate as idle; a keeper deploys once per day:

```solidity
// ArthaVault
function deployIdle() external onlyKeeper {
    uint256 idle = IERC20(asset).balanceOf(address(this));
    // allocate across strategies by governance target ratios (bps), respecting maxDebt + buffer
    for (uint i; i < strategies.length; i++) {
        uint256 amt = idle * targetBps[strategies[i]] / 10_000;
        if (amt == 0) continue;
        IERC20(asset).forceApprove(strategies[i], amt);
        IStrategy(strategies[i]).deposit(amt, address(this)); // strategy mints shares TO the vault
    }
}
```

- **Strategies mint shares to the vault** (`receiver = address(this)`), so the vault holds the strategy positions and values them in `totalAssets`.
- A **liquidity buffer** (`minBufferBps`) is left idle so withdrawals are instant without unwinding a strategy.
- Rebalance/withdraw pull back via `strategy.withdraw(amt, vault, vault)`.

---

<a name="s9"></a>
## 9. Access control & the call graph

```
USER ──► PositionManager ──(onlyManager)──► ArthaVault ──(vault is depositor)──► Strategies
                │                                │                                   │
                │ mints/holds ERC-721            │ reads rewardRatio ◄── RewardConfig │ mint shares
                │                                │ credits earned   ──► RewardTracker │ to vault
                └──── claim ──────────────────────────────────────► RewardTracker.claim
GOV/Timelock ──► RewardConfig.setRewardRatio / RewardTracker.setCap / Vault.registerStrategy
KEEPER ──► ArthaVault.deployIdle()
```

Enforced rules (the "vault only callable / strategies mint to vault" requirements):
- **`ArthaVault` user ops are `onlyManager`.** Users can't call the vault directly; they go through `PositionManager`, which owns tokenId ↔ owner truth.
- **Strategies are `onlyVault`.** Only the owning vault deposits/withdraws; strategies mint shares to the vault.
- **`RewardTracker.credit` is vault-only**, and `msg.sender == vault` (a vault can only credit under its own key).
- **Ratios/cap are Timelock-only.** Keeper can only *trigger* deployment, never move funds outside targets.

---

<a name="s10"></a>
## 10. Trading the position NFT

Because the position is an ERC-721:
- `transferFrom(seller, buyer, tokenId)` moves the **entire** position — all vault shares + all unclaimed ARTHA — to the buyer. No settlement needed at transfer: accrual is on the `tokenId`, and `_settleReward` runs on the next deposit/withdraw/claim, crediting whoever holds it then. (If you want accrual banked at the transfer instant, add an `_beforeTokenTransfer` hook that calls `vault.syncReward(tokenId)` across the tokenId's vaults.)
- **Marketplaces work out of the box** (OpenSea, etc.) — the NFT's value is its underlying assets + rewards, so a buyer is purchasing a live yield position.
- **Valuation for buyers:** `PositionManager.positionValue(tokenId)` returns, per vault, `shares·pps` (principal + yield) and `RewardTracker.totalEarned − claimed` (claimable ARTHA) so a buyer can price it.

**Caveat to design around:** whoever holds the NFT at claim time gets the ARTHA — including ARTHA earned under a previous owner. That's the correct NFT semantic (you buy the accrued rewards too), but price it in. If instead rewards should stay with the *earner*, bank-and-pay-out on transfer via the hook above.

---

<a name="s11"></a>
## 11. Reward math + worked example

Single-ratio accumulator (no tiers for user rewards). `ACC = 1e18`, `YEAR = 360 days` (matching the referral engine).

```
accArthaPerPrincipal += rewardRatio[vault] · dt · ACC / (1e18 · YEAR)
earned(tokenId)       = rewardPrincipalNorm · accArthaPerPrincipal / ACC − rewardDebt
```

**Example — USDC vault, `rewardRatio = 5e17` (50%/yr), user deposits 1000 USDC, held 90 days.**

```
1) normalise:  rewardPrincipalNorm = 1000e6 · 1e12 = 1e21           (1000 in 18dp)
2) acc over 90d (dt = 7,776,000 s):
   acc = 5e17 · 7,776,000 · 1e18 / (1e18 · 31,104,000)
       = 5e17 · 7,776,000 / 31,104,000
       = 5e17 · 0.25 = 1.25e17
3) earned = 1e21 · 1.25e17 / 1e18 = 1.25e20 wei
```
**earned = 125 ARTHA.** Check: 50%/yr on 1000 = 500 ARTHA/yr × 90/360 = 125. ✔ The tracker credits 125 to `earnedByVault[tokenId][usdcVault]` (capped at the pool), and the NFT owner claims it.

If the user withdraws half at day 90, `_settleReward` banks the 125 first, then `rewardPrincipalNorm` halves to 5e20, so the next period accrues on 500 — exactly like the referral banking rule.

---

<a name="s12"></a>
## 12. Data structures per contract

**PositionManager (ERC-721)**
```solidity
mapping(address => uint256) public userToken;   // user → their tokenId (0 = none yet)
uint256 public nextId;
// deposit(vault, amount) ; withdraw(tokenId, vault, assets) ; claimRewards(tokenId, to)
// positionValue(tokenId) view
```

**ArthaVault (per base token)**
```solidity
address public asset; uint8 public assetDecimals; uint256 public scale; // 10^(18-dec)
mapping(uint256 => uint256) public shares; uint256 public totalShares;  // principal+yield
address[] public strategies; mapping(address => uint16) public targetBps; uint16 public minBufferBps;
// reward accrual:
uint256 public accArthaPerPrincipal; uint256 public lastUpdate;
mapping(uint256 => uint256) public rewardPrincipalNorm; mapping(uint256 => uint256) public rewardDebt;
// depositFor / withdrawFor / deployIdle / syncReward / totalAssets / convertToShares/Assets
```

**RewardConfig**
```solidity
mapping(address => uint256) public rewardRatio; // 0..1e18
```

**RewardTracker**
```solidity
uint256 public maxDistributable; uint256 public totalDistributed; uint256 public totalClaimed;
mapping(uint256 => mapping(address => uint256)) public earnedByVault;
mapping(uint256 => uint256) public totalEarned; mapping(uint256 => uint256) public claimed;
mapping(address => bool) public isVault;
```

---

<a name="s13"></a>
## 13. Deployment & integration

```solidity
// 1) token + config + tracker
ArthaToken   artha  = new ArthaToken();
RewardConfig config = new RewardConfig(timelock);
RewardTracker tracker = new RewardTracker(address(artha), timelock);
artha.transfer(address(tracker), USER_REWARD_POOL);   // pre-mint the pool; sets the cap basis
tracker.setCap(USER_REWARD_POOL);                     // maxDistributable = pool

// 2) manager (the ERC-721) + vaults
PositionManager manager = new PositionManager(timelock, address(tracker));
ArthaVault usdc = new ArthaVault(USDC, 6, address(manager), address(config), address(tracker), keeper);
tracker.setVault(address(usdc), true);                // allow usdc-vault to credit
config.setRewardRatio(address(usdc), 5e17);           // 50%/yr ARTHA on USDC principal

// 3) strategies (ERC-4626) registered to the vault, funded end-of-day
usdc.addStrategy(aaveUsdcStrategy, 6000);             // 60% target
usdc.addStrategy(susdsStrategy,    4000);             // 40% target
```

User path: `manager.deposit(address(usdc), 1000e6)` → NFT minted → shares assigned → (end of day) `usdc.deployIdle()` → later `manager.claimRewards(tokenId, me)` and `manager.withdraw(tokenId, address(usdc), amount)`.

---

<a name="s14"></a>
## 14. Invariants & audit checklist

**Positions / shares**
1. `Σ shares[tokenId] == totalShares` per vault.
2. `totalAssets == idle + Σ strategy.convertToAssets(vaultShares)` (no leak / double count).
3. Deposit-then-withdraw returns ≤ deposited (rounding + virtual offset favor the vault).
4. `pps` non-decreasing except on real strategy loss.
5. Withdraw succeeds from buffer + strategies; buffer floor respected after `deployIdle`.

**User ARTHA rewards**
6. `totalDistributed ≤ maxDistributable` **always** — the pool can never be over-promised.
7. `Σ claimed ≤ totalDistributed ≤ ARTHA held by the tracker` (no phantom pay).
8. `earned = principalNorm·acc/ACC − rewardDebt` never underflows (acc monotonic; re-checkpoint on every principal change).
9. Ratio changes are non-retroactive (accumulator advanced before the new rate is written).
10. Accrual on the `tokenId`; the current NFT owner is paid; transfer moves unclaimed ARTHA.

**Access**
11. `ArthaVault` user ops `onlyManager`; strategies `onlyVault`; `credit` vault-only under its own key; ratios/cap Timelock-only; `deployIdle` keeper-only.
12. NFT mint is idempotent per user (one id, reused) — a second deposit never mints a second NFT.

Run as a Foundry invariant suite + forked-mainnet integration (real Aave/Compound/Sky strategies + real ARTHA), `forge coverage ≥ 95%` on the vault share math and the reward accumulator, external audit before mainnet funds — the NFT ownership check and the tracker cap are the two invariants most worth fuzzing.

---

### Note on coexistence with the referral system (v2)
Both engines run on the same deposit. When `manager.deposit` calls `usdc.depositFor(tokenId, amount)`, the vault (a) accrues the *depositor's* ARTHA to the `tokenId` via `RewardTracker`, and (b) still calls `ReferralVault.notifyDeposit(strategy, user, amount)` to accrue the *referrer's* ARTHA — two separate pools, two separate caps, one deposit. Nothing about the referral contracts changes.