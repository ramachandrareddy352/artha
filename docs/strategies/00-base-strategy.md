# BaseStrategy — the shared skeleton

**Source:** `contracts/src/strategies/BaseStrategy.sol`, `contracts/src/strategies/interfaces/IStrategy.sol`

Every strategy in `contracts/src/strategies/` inherits `BaseStrategy` and fills in a small set of protocol-specific hooks. This document explains the shared contract so the per-category docs only need to describe what's DIFFERENT about each one.

## The interface the vault sees

```solidity
interface IStrategy {
    function asset() external view returns (IERC20);
    function vault() external view returns (address);
    function totalAssets() external view returns (uint256);
    function maxWithdraw() external view returns (uint256);
    function deposit(uint256 assets) external;
    function withdraw(uint256 assets) external returns (uint256 withdrawn);
    function harvest() external returns (uint256 harvested);
    function emergencyWithdraw() external returns (uint256 withdrawn);
}
```

The vault never learns which venue a strategy uses. Whatever protocols a strategy chains internally (deposit to Curve, stake the LP in Convex, sell CRV+CVX, redeposit), the vault only ever sees these eight functions — which is why "Curve + Convex, boosted" is ONE strategy slot, not two.

## Vault-only, always

Every state-changing function is `onlyVault nonReentrant`. Harvesting especially: reward-selling costs gas and eats slippage, so harvesting a trivial amount is a net loss. Gating it to the vault means only the vault's own keeper flow — which decides WHEN it's economic — can trigger it. No third party can grief a position with dust harvests.

## `totalAssets()` — continuous, haircut-adjusted valuation

```
totalAssets() = _positionValue() + _pendingRewardsValue()
```

Unclaimed reward tokens are counted into `totalAssets` AS THEY ACCRUE, valued via the oracle at a 2% haircut (`REWARD_HAIRCUT_BPS`). This is the anti-front-running rule: because pending rewards are already in the share price, the actual `harvest()` that realizes them is close to a price-per-share no-op — there is no reward "spike" for a depositor to jump in front of. When a venue makes pending rewards impossible to read in a view, a strategy under-reports them (returns less, never more) — under-reporting can never be gamed for profit.

## Where compounded yield goes — no new shares

`harvest()` claims rewards, swaps them to base, and reinvests via `_invest`. That raises `_positionValue` while share count is unchanged, so every holder's share simply becomes worth more. Reinvested yield NEVER mints shares — only a genuine outside deposit (or the vault's own performance-fee mint-to-treasury, see `docs/formulas.md` §4) does.

## The four hooks a concrete strategy fills in

| Hook | Required? | Purpose |
|---|---|---|
| `_invest(uint256 amount)` | always | Deploy base token already held by the contract into the venue. |
| `_divest(uint256 amount) returns (uint256 freed)` | always | Free up to `amount` of base token from the venue. Never returns more than requested. |
| `_positionValue() view returns (uint256)` | always | Current venue position, in base token (principal + accrued interest/appreciation). |
| `_pendingRewardsValue() view returns (uint256)` | optional, default 0 | Base-token value of unclaimed rewards, oracle-priced and haircut. |
| `_harvestRewards() returns (uint256 realized)` | optional, default 0 | Claim reward tokens and swap to base. Does NOT reinvest — the base `harvest()` wrapper does that. |
| `_withdrawAll() returns (uint256 freed)` | optional, default `_divest(_positionValue())` | Unwind the ENTIRE position. Override where a venue needs an exact "withdraw all" call. |

## Reward valuation math

`_valueInAsset(rewardToken, rewardAmount, rewardDecimals)`:

```
gross = rewardAmount × rewardPrice(8dp) × 10^assetDecimals / (assetPrice(8dp) × 10^rewardDecimals)
value = gross × (10,000 - 200) / 10,000        // 2% haircut
```

Both prices come from the strategy's own immutable `oracle` reference (`IPriceOracle`, satisfied by `oracle/PriceFeed.sol`) — the vault itself never calls an oracle directly; every strategy already reports in base-token terms.

## Slippage

`maxSlippageBps` (default 100 = 1%) bounds every LP/swap leg a strategy performs on its own entry/exit, vault-settable but hard-capped at `MAX_SLIPPAGE_BPS` (500 = 5%) so a compromised setter can't open the door to a full drain.

## The "one strategy, many protocols" pattern

A strategy is one address the vault treats as a black box. "Invest in Curve, stake the LP in Convex for boosted yield" is ONE strategy slot because the second protocol (Convex) is an internal implementation detail hidden behind the same four/six hooks above — see `docs/strategies/05-composed-boosters.md` for the concrete `CurveConvexUsdcStrategy` walkthrough.
