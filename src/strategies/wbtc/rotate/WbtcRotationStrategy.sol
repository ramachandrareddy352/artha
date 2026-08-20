// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RotationStrategy} from "../../common/RotationStrategy.sol";

/**
 * @title  WbtcRotationStrategy — take profit into stables, buy the dip back into BTC
 * @notice THE WBTC vault's yield strategy. BTC lending pays near nothing (see
 *         `AaveV3WbtcStrategy`), so the way a BTC-denominated vault actually grows its
 *         BTC-per-share is by trading the pair: sell into strength, buy back weakness,
 *         and keep the difference in BTC.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHAT IT DOES, CONCRETELY
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   Deploy with base = WBTC (the vault's asset) and quote = a stablecoin (USDC/USDT).
 *
 *     BTC rallies past the band  ->  WBTC is sold for the stablecoin. The vault is now
 *                                    waiting in stables, earning the stable park's
 *                                    yield (an Aave/sDAI-style 4626) while it waits.
 *     BTC falls back past the    ->  the stablecoin buys BTC again — MORE BTC than was
 *     buy-back band                  sold, because it is bought at a lower price.
 *
 *   The vault accounts in WBTC, so that extra BTC is the return. It compounds: every
 *   completed round trip enlarges the stack that the next one operates on.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW TO PARAMETERIZE IT (base = WBTC, quote = USDC)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   Remember the price the bands are measured in: `p` is USDC priced in WBTC, so
 *   "p falls" means BTC got MORE expensive. Reading the params in BTC terms:
 *
 *     enterQuoteDropBps = 2000   sell WBTC once BTC is +25% from the last buy-back
 *                                (a 20% fall in p is a 25% rise in BTC).
 *     enterReboundBps   = 300    ...but only after BTC has ticked 3% back down, so a
 *                                vertical rally is not sold into its first hour.
 *     exitQuoteGainBps  = 2000   buy BTC back once it is 20% below where we sold.
 *     exitTrailingBps   = 500    or once it has bounced 5% off the low — bank the
 *                                round trip rather than wait for a target that passed.
 *     exitStopLossBps   = 1500   or if BTC ran another 15% away from us: admit the
 *                                trend, get back into BTC, stop bleeding BTC.
 *     maxQuoteHold      = 90 days  or simply because we have waited long enough.
 *     cooldown          = 1 days   never more than one rotation a day.
 *
 *   Every one of those is settable by governance after deployment (`setParams`), and
 *   `setRotationEnabled(false)` freezes the position where it stands while they are
 *   retuned.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   BEFORE DEPLOYING — TWO HARD REQUIREMENTS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   1. WIDEN THE VAULT'S CIRCUIT BREAKER. While this strategy holds stables, its value
 *      in WBTC terms moves with BTC — a 20% BTC drop makes the position worth 20% more
 *      WBTC. `LibVaultNav` reads that as a suspicious jump, trips the breaker and
 *      auto-pauses the vault. Set `strategyMaxDeltaBps` above the largest BTC move
 *      expected between two NAV refreshes.
 *   2. TEND ON A SCHEDULE. The trailing stop can only trail a peak it has actually
 *      observed, and bands are only checked when `tend()` runs. An hourly keeper tend
 *      is the intended operating mode.
 *
 *   And the honest caveat: this LOSES against simply holding BTC in a sustained
 *   one-way rally, because it sells and waits while BTC keeps going. `exitStopLossBps`
 *   and `maxQuoteHold` bound that; the strategy's weight is what sizes it.
 */
contract WbtcRotationStrategy is RotationStrategy {
    constructor(
        address _vault,
        address _wbtc,
        address _oracle,
        address _swapper,
        address _stable, // quote: USDC / USDT / DAI
        address _wbtcPark, // optional 4626 over WBTC to earn while holding BTC (0 = none)
        address _stablePark, // optional 4626 over the stable to earn while waiting (0 = none)
        Params memory _params
    ) RotationStrategy(_vault, _wbtc, _oracle, _swapper, _stable, _wbtcPark, _stablePark, _params) {}
}
