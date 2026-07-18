# Lending strategies (yield Shape 1: exchange-rate / interest accrual, some with Shape 3: emissions)

Deposit the base asset into a money-market protocol; the position's value climbs continuously as borrowers pay interest. Some also emit a separate reward token on top.

| File | Protocol | Base token | Pattern | Emissions? |
|---|---|---|---|---|
| `usdc/lend/AaveV3UsdcStrategy.sol` | Aave V3 | USDC | Full reference implementation (see below) | Optional `IAaveRewardsController` |
| `usdc/lend/CompoundV3UsdcStrategy.sol` | Compound V3 (Comet) | USDC | Direct Comet integration | COMP (Shape 1+3) |
| `usdc/lend/MorphoUsdcStrategy.sol` | Morpho | USDC | Thin `ERC4626WrapperStrategy` subclass | — |
| `usdc/lend/SparkUsdcStrategy.sol` | Spark | USDC | Thin `AaveV3UsdcStrategy` subclass (Spark is Aave-V3-shaped) | Optional |
| `usdc/lend/EulerV2UsdcStrategy.sol` | Euler V2 | USDC | Thin `ERC4626WrapperStrategy` subclass | — |
| `usdt/lend/AaveV3UsdtStrategy.sol` | Aave V3 | USDT | Thin subclass | Optional |
| `dai/lend/AaveV3DaiStrategy.sol` | Aave V3 | DAI | Thin subclass | Optional |
| `dai/lend/SparkDaiStrategy.sol` | Spark | DAI | Thin subclass (Spark's native market — DAI is its origin asset) | Optional |
| `weth/lend/AaveV3WethStrategy.sol` | Aave V3 | WETH | Thin subclass | Optional |
| `weth/lend/CompoundV3WethStrategy.sol` | Compound V3 | WETH | Thin subclass | COMP |
| `wbtc/lend/AaveV3WbtcStrategy.sol` | Aave V3 | WBTC | Thin subclass — WBTC realistically has only this one simple, liquid lending strategy today | Optional |

## `AaveV3UsdcStrategy` — the reference lending implementation

- `_invest`: `pool.supply(asset, amount, address(this), 0)`.
- `_divest`: `pool.withdraw(asset, amount, address(this))`.
- `_positionValue`: the aToken balance (rebasing 1:1 with underlying + accrued interest — Aave's aTokens accrue interest directly into balance, no separate "claim" step needed for the base yield).
- `_pendingRewardsValue`: if `IAaveRewardsController` is configured, queries `getUserRewards` for each configured reward token, oracle-values and haircuts them.
- `_harvestRewards`: claims all configured rewards via the controller, swaps each to base with an oracle-floored `minOut` (per-reward `swapRoute` mapping), returns total base realized.

## `CompoundV3UsdcStrategy` — the documented under-reporting case

Comet's real pending-COMP reader (`accrueAccount` + `baseTrackingAccrued`) MUTATES state, so it cannot be called from a `view` function. `_pendingRewardsValue()` therefore reports COMP as **0** in every view/NAV read — consistent with the "always under-report, never over-report" rule (see `docs/strategies/00-base-strategy.md`) — and the true pending COMP is only realized and counted the moment `harvest()` actually claims it. This means Compound V3 strategies' displayed `totalAssets()` is a knowingly conservative lower bound versus Aave-style strategies where pending rewards ARE estimable in a view.

## Why Spark and Aave share code

Spark Protocol is a fork of Aave V3 with an (almost) identical pool interface, so `SparkUsdcStrategy`/`SparkDaiStrategy` are thin subclasses of `AaveV3UsdcStrategy`/`AaveV3DaiStrategy` passing Spark's own pool address — no separate implementation needed.
