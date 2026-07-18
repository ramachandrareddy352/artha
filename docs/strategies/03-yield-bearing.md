# Yield-bearing wrapper strategies (yield Shape 2: exchange-rate appreciation)

Hold a token whose exchange rate against the base asset climbs over time (a "share price" token, not a rebasing balance) — sUSDS, sDAI, sUSDe, sFRAX, wOUSD, yvUSDC-style vault shares.

| File | Protocol | Base token | Target asset | Pattern |
|---|---|---|---|---|
| `dai/yield/SkySDaiStrategy.sol` | Sky (MakerDAO) | DAI | sDAI | `ERC4626WrapperStrategy` — sDAI's own asset IS DAI, no swap leg needed |
| `usdc/yield/SkySUsdsStrategy.sol` | Sky | USDC | sUSDS | `CrossAssetERC4626Strategy` — USDC → USDS swap leg, then wrap |
| `usdc/yield/EthenaSUsdeStrategy.sol` | Ethena | USDC | sUSDe | `CrossAssetERC4626Strategy` — USDC → USDe swap leg, then wrap |
| `usdc/yield/FraxSFraxStrategy.sol` | Frax | USDC | sFRAX | `CrossAssetERC4626Strategy` — USDC → FRAX swap leg, then wrap |
| `usdc/yield/OriginOusdStrategy.sol` | Origin | USDC | wOUSD | `CrossAssetERC4626Strategy` — explicitly uses the WRAPPED wOUSD (a standard, non-rebasing 4626 share), not rebasing OUSD directly, since a rebasing balance breaks share-price-based strategy accounting |
| `usdc/yield/YearnV3UsdcStrategy.sol` | Yearn V3 | USDC | yvUSDC | `ERC4626WrapperStrategy` — Yearn V3 vaults are themselves ERC-4626 |
| `usdc/yield/BeefyUsdcStrategy.sol` | Beefy | USDC | mooUSDC-style | `BeefyStrategy` (non-4626 interface) |

## Why "wrap a vault inside a vault" is a legitimate strategy, not just fees-on-fees

Artha's own performance fee (§4 of `docs/formulas.md`) is charged on Artha's OWN price-per-share growth, independent of whatever fee Yearn V3, Beefy, or any wrapped protocol already charges internally — the wrapped vault's share price net of ITS OWN fees is simply the `_positionValue()` this strategy reports. There is no double-fee bug: Artha only ever fees its own net-of-everything growth (see `LibVaultFee`'s header), same as it would on a plain lending position.

## `_positionValue` for a share-price wrapper

```
_positionValue() = ourShareBalanceOfTarget × target.convertToAssets(1 share) / 1 share      (same-asset case)
_positionValue() = intermediateValue × oracle price → base                                   (cross-asset case)
```

Both ultimately read the wrapped vault's own `convertToAssets`/`pricePerShare`-equivalent, so Artha's NAV inherits the target protocol's own accounting rather than re-deriving it.
