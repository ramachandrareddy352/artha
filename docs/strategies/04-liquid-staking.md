# Liquid staking strategies (yield Shape 2, ETH-specific)

| File | Protocol | Base token | Pattern |
|---|---|---|---|
| `weth/staking/LidoWstEthStrategy.sol` | Lido | WETH | Full implementation — see below |
| `weth/staking/FraxSFrxEthStrategy.sol` | Frax | WETH | Thin `CrossAssetERC4626Strategy` subclass (WETH → frxETH → sfrxETH) |

## `LidoWstEthStrategy`

- Entry/exit go through a SWAP (WETH ⇄ wstETH on a DEX), not Lido's native withdrawal queue — Lido's own unstaking queue can take days, which is incompatible with the vault's on-demand withdrawal model. A swap gives instant liquidity at the cost of potential DEX slippage/depeg risk instead of a guaranteed 1:1 (minus validator queue time) redemption.
- `_positionValue`: `wstEthBalance × IWstETH.getStETHByWstETH(1e18) / 1e18` — converts the wstETH holding to its stETH-equivalent value, then (if base is WETH, not stETH directly) an oracle conversion to WETH terms.
- **stETH/ETH depeg risk is explicit and documented in the file's header** — stETH has historically traded at a discount to ETH during periods of stress (e.g. the 2022 Terra/3AC contagion, where stETH briefly traded ~6% below ETH on secondary markets before recovering as withdrawals enabled arbitrage). Because exit is via swap rather than Lido's native 1:1 (eventually) redemption, a strategy exiting during a depeg realizes the DISCOUNTED price, not par. The NAV circuit breaker (`docs/formulas.md` §7) is the vault-level backstop against this showing up as an unexplained, oracle-manipulation-shaped value jump — but a genuine, market-wide depeg is a real, non-manipulation loss that no circuit breaker can prevent, only detect after the fact.

## Why this differs from a plain "hold WBTC" idle allocation

Liquid staking strategies actively stake — the yield comes from Ethereum's own consensus-layer rewards (and, depending on the LST, a share of execution-layer MEV), continuously accruing into the wstETH exchange rate, not from any external emission or lending spread.
