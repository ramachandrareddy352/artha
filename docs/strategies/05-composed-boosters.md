# Composed / boosted strategies (yield Shapes 1+3 combined: LP fees + boosted emissions)

Where "one strategy, two-or-three protocols" is used to extract more yield than any single protocol offers alone.

| File | Base token | Composition |
|---|---|---|
| `usdc/others/CurveConvexUsdcStrategy.sol` | USDC | Curve (LP) → Convex (boost) — the flagship reference, see below |
| `usdt/others/CurveConvexUsdtStrategy.sol` | USDT | Same pattern |
| `dai/others/CurveConvexDaiStrategy.sol` | DAI | Same pattern |
| `lp/boost/ConvexLpStrategy.sol` | a Curve LP token itself | For LP-token-as-base vaults: stake the LP directly in Convex |
| `lp/boost/AuraLpStrategy.sol` | a Balancer BPT | Same pattern on Balancer/Aura (Aura is a Convex fork) |
| `lp/boost/StakeDaoLpStrategy.sol` | a Curve/Balancer LP | Same pattern on StakeDAO's liquid locker. **⚠ ABI caution** — StakeDAO's gauge/vault surface varies by product version; verify against the live deployment |

## `CurveConvexUsdcStrategy` — how one strategy slot spans two protocols

```
_invest(amount):
    curvePool.add_liquidity([amount, 0, 0], minLpOut)      // USDC -> Curve LP, oracle-floored minOut
    convexBooster.deposit(pid, lpBalance, stake=true)       // stake the LP in Convex for boosted CRV+CVX

_positionValue():
    convexRewards.balanceOf(this) × curvePool.get_virtual_price() / 1e18
```

`get_virtual_price()` — not the pool's raw, spot reserve ratio — is the valuation source. It is MONOTONIC (only increases as trading fees accrue to the pool) and cannot be moved within a single transaction the way spot reserves can via a flash-loan-funded imbalanced swap. This is the same "don't trust a flash-loan-manipulable spot price for NAV" principle the NAV circuit breaker (`docs/formulas.md` §7) exists to catch if it were ever violated elsewhere.

```
_pendingRewardsValue():
    counts CRV only, oracle-priced and haircut. CVX is safely under-reported as 0 in the view
    (Convex's exact CVX-per-CRV emission curve isn't cheaply computable in a view call) —
    consistent with "always under-report, never over-report."

_harvestRewards():
    convexRewards.getReward()                    // claims BOTH CRV and CVX
    swap CRV -> USDC, oracle-floored minOut
    swap CVX -> USDC, oracle-floored minOut
    returns total USDC realized (reinvested by the base harvest() wrapper via add_liquidity again)
```

## Withdrawal

```
_divest(amount):
    lpNeeded = amount × 1e18 / curvePool.get_virtual_price()
    convexRewards.withdrawAndUnwrap(lpNeeded, claim=false)   // unstake from Convex, no reward claim (harvest handles that separately)
    curvePool.remove_liquidity_one_coin(lpNeeded, usdcIndex, minOut)   // Curve LP -> USDC, oracle-floored minOut
```

Two distinct slippage surfaces exist here and are handled separately: `get_virtual_price()` for VALUATION (manipulation-resistant, used in `_positionValue`), and `calc_withdraw_one_coin()`-implied execution slippage for the ACTUAL exit transaction (bounded by `maxSlippageBps`). Conflating the two — e.g. trusting virtual price as the execution floor too — would ignore genuine, non-manipulation exit slippage from a large single-sided withdrawal against Curve's own bonding curve.
