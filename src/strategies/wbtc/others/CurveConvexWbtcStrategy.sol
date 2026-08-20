// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CurveConvexStrategy} from "../../common/CurveConvexStrategy.sol";

/**
 * @title  CurveConvexWbtcStrategy — WBTC into a BTC-pegged Curve pool, staked in Convex
 * @notice For 2-coin BTC pools (WBTC/tBTC and similar) where every coin is a claim on
 *         one BTC. Adds WBTC single-sided, stakes the LP in Convex for boosted CRV +
 *         CVX, sells both back into WBTC.
 *
 *         With BTC lending paying near zero (see `AaveV3WbtcStrategy`), emissions are
 *         one of the few things that actually pay a WBTC holder — but they come with
 *         the risk below, so this is a satellite leg, never the core.
 *
 *   risk  : CROSS-BTC PEG. Every coin here is a different custodian's or bridge's claim
 *           on BTC. If one of them breaks — and BTC wrappers are exactly the assets
 *           that have broken historically — the pool fills up with the broken one and
 *           our single-sided WBTC exit pays out of that. This is a bigger, more
 *           discrete risk than the stable pools' peg risk; weight it accordingly.
 */
contract CurveConvexWbtcStrategy is CurveConvexStrategy {
    constructor(address _vault, address _wbtc, address _oracle, address _swapper, Config memory c)
        CurveConvexStrategy(_vault, _wbtc, _oracle, _swapper, c)
    {}
}
