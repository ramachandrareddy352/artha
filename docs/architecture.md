# Artha Protocol — Architecture

This document explains how the pieces fit together: the Diamond proxy, its facets, the vault/strategy/oracle/rewards/referral/governance modules, and exactly who is allowed to call what.

## 1. The system in one picture

```
                                    users / keeper / anyone
                                              │
                                              ▼
                                   ┌─────────────────────┐
                                   │       Diamond        │  ← one address, forever
                                   │  (fallback delegate-  │
                                   │   calls into facets)  │
                                   └──────────┬───────────┘
                    ┌───────────┬─────────────┼─────────────┬───────────┐
                    ▼           ▼             ▼             ▼           ▼
             DiamondCutFacet DiamondLoupe  Ownership   VaultAdmin   VaultDeposit
             (upgrade logic)   Facet        Facet         Facet        Facet
                                                              │           │
                    ┌───────────┬─────────────┬───────────────┘           │
                    ▼           ▼             ▼                           │
             VaultWithdraw  VaultHarvest  VaultView    VaultEmergency     │
                Facet          Facet        Facet          Facet          │
                    │           │                                        │
                    └─────┬─────┴────────────────────────────────────────┘
                          ▼
              AppStorage (slot 0, shared by every facet via delegatecall)
                          │
                          ▼
              ┌───────────────────────┐
              │  strategy contracts    │  ← external calls (NOT delegatecall)
              │  (Aave, Curve+Convex,  │     msg.sender == the Diamond
              │   Ethena, Lido, ...)   │
              └───────────────────────┘

    Separate, standalone contracts (each independently deployed, loosely coupled):
      VaultShareToken (one per vault)  —  oracle/PriceFeed  —  rewards/UserRewardVault
      referral/ReferralVault  —  governance/{ArthaTimelock, ArthaGovernor, ArthaToken}
```

## 2. Why Diamond (EIP-2535), and what delegatecall buys

The Diamond is one address with (almost) no logic of its own — a constructor that wires in `DiamondCutFacet`, and a `fallback()` that looks up `msg.sig` in `LibDiamond`'s selector map and `delegatecall`s into whichever facet implements it.

`delegatecall` runs the facet's CODE against the DIAMOND's STORAGE and the DIAMOND's `msg.sender`/`address(this)`:
- `AppStorage` (a single struct at storage slot 0) is shared by every facet — there is exactly one copy of every vault's state, no matter how many facets exist.
- Inside a facet, `msg.sender` is the ORIGINAL caller (a user, the keeper), and `address(this)` is the DIAMOND's own address — never the facet's. This is why `IStrategy(strategy).vault() == address(this)` (checked in `LibStrategyRegistry.addStrategy`) correctly validates against the Diamond, and why every strategy's `onlyVault` modifier correctly recognizes the Diamond as caller regardless of which facet triggered the call into it.
- Upgrading logic is a `diamondCut` — repointing a selector to a new facet address. No storage migration, no redeploy, no address change. Nothing holding a reference to the Diamond (share tokens, the oracle mapping in each strategy, external integrators) ever needs to update anything.

**Diamond → Strategy is a PLAIN external call, not delegatecall.** When a facet calls `IStrategy(strategy).deposit(...)`, that is a normal `CALL`, so the strategy executes in ITS OWN storage context, and sees `msg.sender == diamond` (since the facet code, running via the Diamond's own delegatecall context, has `address(this) == diamond`). This is exactly what makes `onlyVault` on every strategy correct.

## 3. One Diamond, many vaults

Every vault (a USDC vault, a WETH vault, an LP vault, ...) is a row in `AppStorage`'s vault-address-keyed mappings. The key IS the address of that vault's own `VaultShareToken` — a minimal ERC-20 deployed once per vault by `VaultAdminFacet.createVault`, mintable/burnable ONLY by the Diamond.

Using the share token's own address as the vault's identity (rather than inventing a parallel `uint256 vaultId`) means the already-built `ReferralVault.registerVault(vault, baseAsset, ...)` and `UserRewardVault.registerVault(vault, shareToken, ...)` — both of which take a `vault` address distinct from `shareToken`/`baseAsset` — can be pointed at this same address with zero code changes.

Shares are NOT tracked inside `AppStorage`. `IERC20(vault).totalSupply()` / `balanceOf()` on the `VaultShareToken` are the sole source of truth. This is what lets `UserRewardVault.stake()` pull a user's shares with a plain `transferFrom` — no Diamond involvement, no special-casing, full ERC-20 composability for free.

## 4. Facet map

| Facet | Access | Responsibility |
|---|---|---|
| `DiamondCutFacet` | `onlyGovernance` (== ArthaTimelock) | Add/replace/remove facet selectors — the only way protocol logic ever changes. |
| `DiamondLoupeFacet` | anyone (view) | Enumerate installed facets/selectors — off-chain tooling only. |
| `OwnershipFacet` | `onlyGovernance` to transfer | Standard ERC-173 `owner()`/`transferOwnership()` over `LibDiamond`'s stored owner. |
| `VaultAdminFacet` | `onlyGovernance` | Create vaults, strategy lifecycle (add/reweight/disable/remove/migrate), risk limits, fees, roles. |
| `VaultDepositFacet` | anyone (vault must be unpaused) | `deposit`/`mint` — the only way base token enters a vault. |
| `VaultWithdrawFacet` | anyone (vault must be unpaused) | `withdraw`/`redeem` — the normal exit path. |
| `VaultHarvestFacet` | `onlyKeeper` (`settle` is permissionless) | `harvest`/`harvestAll`/`settle`/`deployIdle`/`rebalance`. |
| `VaultViewFacet` | anyone (view) | All pricing/config reads: `totalAssets`, `pricePerShare`, `previewDeposit/Mint/Withdraw/Redeem`, `maxWithdraw`, `maxRedeem`, config dumps. |
| `VaultEmergencyFacet` | guardian pauses, governance unpauses, anyone can `emergencyWithdraw` | Pause/unpause and the guaranteed always-available exit. |

## 5. Access control map

```
ArthaTimelock  (== LibDiamond.contractOwner() == "governance" everywhere in this codebase)
   │
   ├─ can diamondCut (upgrade any facet)
   ├─ can call every VaultAdminFacet function (create vaults, strategies, fees, caps, roles)
   ├─ is the ONLY address that can unpause (pauseVault/pauseProtocol excluded)
   └─ receives PROPOSER_ROLE/CANCELLER_ROLE grants FROM ArthaGovernor (token-vote-gated proposals)

Guardian(s)  (s.isGuardian[addr], set BY governance)
   └─ can pauseVault / pauseProtocol ONLY — cannot unpause, cannot touch funds, cannot change any
      economic parameter. The asymmetry (pause instantly, unpause only via governance's public,
      delayed process) defeats a compromised guardian key pausing-then-unpausing as a distraction.

Keeper(s)  (s.isKeeper[addr], set BY governance)
   └─ can call harvest / harvestAll / deployIdle / rebalance. Cannot withdraw funds to any address
      other than the vault's own idle balance or between the vault's own strategies — a compromised
      keeper key can waste gas or delay yield, never move funds out of the vault.

Anyone
   ├─ deposit / mint / withdraw / redeem (subject to per-vault pause, caps, min-deposit)
   ├─ settle(vault) — permissionless NAV checkpoint refresh, no claim/swap
   └─ emergencyWithdraw(vault, shares, receiver, owner) — always available, no pause gate,
      never reverts on shortfall (pays out whatever can actually be recovered)
```

Users and the keeper both ONLY ever call the Diamond. The Diamond calls strategies; strategies never call back into the Diamond except to return control after a plain external call, and every strategy function is gated `onlyVault` (== only the Diamond).

## 6. Deposit-timing model (Model A)

Shares are minted IMMEDIATELY on deposit, priced against the vault's current checkpointed NAV — there is no pending-deposit batching and no waiting for an end-of-day settlement. The deposited base token sits as `idleBalance` until the keeper's next `deployIdle`/`rebalance` call actually deploys it into strategies. This is Yearn's real production model (instant shares, keeper-batched deployment), chosen deliberately over the repo's earlier, since-superseded "pending-bucket, pre-batch-NAV settlement" design (see `docs/formulas.md` §9 and the retired `LibNav`/`LibShares`/`LibStrategy` design it belonged to).

## 7. What this supersedes

Three earlier, mutually different vault designs existed in this repository at various points:
1. **`artha-v3-minimal/`** — an earlier working prototype.
2. **The root `README.md`'s "v4 architecture"** — ERC-721 positions, per-position cost-basis, entry+profit fees, an end-of-day batch-deploy model explicitly different from Yearn's real one.
3. **The (now-removed) `LibNav.sol`/`LibShares.sol`/`LibStrategy.sol`** — a 6-fixed-pool, multi-token-basket, pending-deposit-batched design, keyed by a `poolId` 0..5.

This implementation supersedes all three: single base asset per vault (not a multi-token basket), fungible ERC-4626-style shares (not ERC-721 positions), Model A deposit timing (matching Yearn's actual production behavior), vault-wide aggregate-high-water-mark performance fee (not per-position cost-basis), and an arbitrary number of vaults (not 6 fixed pools). `LibDiamond.sol`, the governance module, and the referral module needed no changes and are reused as-is.
