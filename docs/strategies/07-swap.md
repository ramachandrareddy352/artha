# Swap adapters — `contracts/src/strategies/swap/`

Every strategy that needs to sell a reward token or cross an asset boundary routes through one of these, all implementing the same minimal interface:

```solidity
interface ISwapper {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata data)
        external returns (uint256 amountOut);
}
```

| File | Venue | Notes |
|---|---|---|
| `CurveSwapper.sol` | Curve pools | For stable/correlated-asset swaps where Curve offers the tightest pricing. |
| `UniswapV3Swapper.sol` | Uniswap V3 | Concentrated-liquidity routing. |
| `UniswapV2Swapper.sol` | Uniswap V2-style routers | Also serves any Uniswap V2 fork (PancakeSwap, SushiSwap, ...) sharing the same router ABI. |
| `BalancerV2Swapper.sol` | Balancer V2 | **⚠ ABI caution** — verify against the live deployment before use. |
| `AggregatorSwapper.sol` | Any whitelisted aggregator router (0x, 1inch, ...) | See below — different trust model from the others. |

## Why `minOut` is ALWAYS caller-supplied, never venue-quoted

Every strategy calling into any of these derives its `minOut` from the ORACLE price (see `BaseStrategy._valueInAsset`), never from the swap venue's own quote function. Trusting a DEX's own quote as the execution floor is a classic sandwich/MEV vulnerability — an attacker can move the venue's spot price within the same block, making the venue "agree" with its own manipulated price. An oracle-derived floor is independent of whatever the venue shows at execution time.

## `AggregatorSwapper` — a different trust model

Unlike the other four (which construct their own calldata against a known, fixed protocol interface), `AggregatorSwapper` forwards PRE-BUILT, off-chain-constructed calldata to one whitelisted router address. Because the calldata itself isn't independently verified on-chain, it measures the ACTUAL received amount via a balance-delta check after the call, rather than trusting the payload's claimed output — the same defensive pattern used for base-token deposits elsewhere in this protocol (`VaultDepositFacet._pullAndCredit`, `UserRewardVault.stake`). The whitelisted router address itself is the trust boundary: only a governance-approved aggregator router can ever be targeted.
