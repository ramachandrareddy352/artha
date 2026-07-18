# Common base contracts — `contracts/src/strategies/common/`

Reusable `BaseStrategy` subclasses that most concrete strategies inherit rather than reimplementing the same hooks from scratch.

| File | Pattern | Used by (examples) |
|---|---|---|
| `ERC4626WrapperStrategy.sol` | Universal same-asset ERC-4626 wrapper: asserts `target.asset() == this.asset()`, deposits/redeems shares of the target vault. Covers ANY ERC-4626-compliant vault whose asset matches this strategy's base token. | `MorphoUsdcStrategy`, `EulerV2UsdcStrategy`, `SkySDaiStrategy`, `YearnV3UsdcStrategy` |
| `CrossAssetERC4626Strategy.sol` | Same idea, but the target 4626 vault's asset is DIFFERENT from the strategy's base token — adds a swap leg on entry (base → intermediate) and exit (intermediate → base), with oracle-derived `minOut` floors on both. | `EthenaSUsdeStrategy`, `FraxSFraxStrategy`, `SkySUsdsStrategy`, `OriginOusdStrategy`, `FraxSFrxEthStrategy` |
| `BeefyStrategy.sol` | Wraps a non-4626 Beefy vault (`deposit(uint256)` / `withdraw(uint256 shares)` / `getPricePerFullShare()`). Asserts `beefy.want() == this.asset()`. | `BeefyUsdcStrategy` |
| `LpBoosterStrategy.sol` | For LP-token-as-base-asset vaults: stakes the LP into a Convex-shaped booster (`deposit(pid, amount, stake)`) for boosted emissions, claims + sells the reward set, reinvests. | `ConvexLpStrategy`, `AuraLpStrategy`, `StakeDaoLpStrategy` |
| `PendlePtStrategy.sol` | Holds a Pendle Principal Token (PT) to maturity for a fixed, discount-to-par return (yield Shape 4). Valued via `IPendlePtOracle.getPtToAssetRate` (TWAP-based). **⚠ ABI caution** — verify against the live Pendle deployment before use; interfaces vary by market version. | (base for any PT position) |

## Why a "wrapper" pattern instead of one bespoke strategy per protocol

Most lending/yield protocols today expose an ERC-4626-compliant vault (Morpho, Euler V2, Sky, Yearn V3 itself). `ERC4626WrapperStrategy` and `CrossAssetERC4626Strategy` mean adding support for a NEW same-shape protocol is a thin subclass (see `docs/strategies/02-lending.md` and `03-yield-bearing.md` — most of those files are 10-20 lines that just pass constructor arguments to one of these two bases), not a full reimplementation.

## Cross-asset conversion math (`CrossAssetERC4626Strategy`)

```
_baseToIntermediate(baseAmount)  = oracle-priced conversion, base → intermediate, then swap with minOut floored by that price
_intermediateToBase(interAmount) = oracle-priced conversion, intermediate → base, then swap with minOut floored by that price
```

The swap venue's OWN quote is never trusted for `minOut` — it is always derived from the oracle price independently, so a sandwich attack on the swap leg itself is bounded by `maxSlippageBps`, not by whatever the DEX happens to quote in the same block.
