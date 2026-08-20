// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RotationStrategy} from "../../common/RotationStrategy.sol";

/**
 * @title  UsdcRotationStrategy — buy the dip, sell the rally, keep the USDC
 * @notice The `WbtcRotationStrategy` seen from the other side. Here the vault accounts
 *         in USDC, so the goal is to end every round trip with MORE USDC: buy the
 *         volatile quote asset (WBTC, WETH) after it has fallen, sell it after it has
 *         recovered, and bank the difference in stables.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW TO PARAMETERIZE IT (base = USDC, quote = WBTC)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   `p` is WBTC priced in USDC — the ordinary BTC price. So the params read directly:
 *
 *     enterQuoteDropBps = 2000   buy BTC once it is 20% below the last sale.
 *     enterReboundBps   = 300    ...only after it has bounced 3% off the low, so we are
 *                                not stepping in front of a crash still in progress.
 *     exitQuoteGainBps  = 2500   sell once it is +25% from where we bought.
 *     exitTrailingBps   = 700    or 7% off the peak, banking most of a move that
 *                                stalled before the target.
 *     exitStopLossBps   = 2000   or 20% below our entry: the dip kept dipping, take the
 *                                loss in USDC terms rather than ride it down.
 *     maxQuoteHold      = 180 days
 *     cooldown          = 1 days
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE DIFFERENCE THAT MATTERS VERSUS THE WBTC WIRING
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   A stable-based vault is DIRECTIONALLY EXPOSED while it holds the quote asset: its
 *   NAV is denominated in USDC, so BTC falling further after we buy is a straight loss
 *   to the share price. The WBTC vault has the mirror-image exposure but its depositors
 *   already chose BTC risk; USDC depositors did not choose BTC risk.
 *
 *   So for a stable vault: keep `exitStopLossBps` tight, keep the strategy's target
 *   weight small (a satellite sleeve, not the core), and treat it as a bounded,
 *   disclosed directional allocation rather than as yield. The lending legs are the
 *   yield; this is the sleeve that trades.
 *
 *   Both hard requirements from `WbtcRotationStrategy` apply unchanged: widen
 *   `strategyMaxDeltaBps`, and keep `tend()` on a keeper schedule.
 */
contract UsdcRotationStrategy is RotationStrategy {
    constructor(
        address _vault,
        address _usdc,
        address _oracle,
        address _swapper,
        address _quote, // WBTC / WETH
        address _usdcPark, // optional 4626 over USDC to earn while holding stables
        address _quotePark, // optional 4626 over the quote asset
        Params memory _params
    ) RotationStrategy(_vault, _usdc, _oracle, _swapper, _quote, _usdcPark, _quotePark, _params) {}
}
