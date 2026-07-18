# Yield tokenization (yield Shape 4: discount-to-par)

| File | Protocol | Pattern |
|---|---|---|
| `common/PendlePtStrategy.sol` | Pendle | Holds a Principal Token (PT) to maturity |

## How PT yield works

Pendle splits a yield-bearing asset into a Principal Token (PT, redeemable 1:1 for the underlying AT maturity, trading below par beforehand) and a Yield Token (YT, which captures the yield stream until maturity). Holding PT alone is a FIXED-rate position: buy PT below par, redeem at par at maturity — the discount IS the yield, known and locked in at purchase time, unlike the floating rates every other strategy category in this repo exposes.

```
_positionValue() = ptBalance × IPendlePtOracle.getPtToAssetRate(market, twapDuration) / 1e18
```

The oracle call uses a TWAP (time-weighted average price) over `twapDuration`, not the market's instantaneous price — the same manipulation-resistance principle as Curve's `get_virtual_price()` (§`05-composed-boosters.md`), applied to an AMM-priced discount rather than a stableswap invariant.

## ⚠ Explicit ABI warning

Pendle's PT/market/oracle interfaces differ across market versions and have changed between Pendle's own protocol versions. `PendlePtStrategy.sol`'s header explicitly flags: **verify the exact interface against the live deployment before use** — this is not a plug-and-play integration the way the ERC-4626 wrapper strategies are.

## Exit before maturity

Selling PT before maturity realizes whatever the current TWAP-implied discount is (better or worse than the straight-line accrual to par, depending on market conditions) rather than the full fixed return — `_divest` executes a market sale, floored by the oracle-derived TWAP price, not a guaranteed par redemption (that guarantee only exists AT maturity).
