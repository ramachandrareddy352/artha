// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CurveConvexStrategy} from "../../common/CurveConvexStrategy.sol";

/**
 * @title  CurveConvexUsdtStrategy — USDT into a Curve stable pool, staked in Convex
 * @notice Adds USDT single-sided to a pegged stable pool, stakes the LP in Convex for
 *         boosted CRV + CVX, and sells both back into USDT on every harvest. Pass
 *         USDT's coin index in the chosen pool (2 in the classic 3pool) and `nCoins`.
 *
 *   yield : trading fees + boosted CRV + CVX.
 *   risk  : any coin in the pool losing its peg hits the single-sided exit — and USDT
 *          is itself the coin most stable pools are LONG when stress hits, since
 *          arbitrageurs dump the weakest coin into the pool. See the pegged-pool
 *          warning in the base contract.
 */
contract CurveConvexUsdtStrategy is CurveConvexStrategy {
    constructor(address _vault, address _usdt, address _oracle, address _swapper, Config memory c)
        CurveConvexStrategy(_vault, _usdt, _oracle, _swapper, c)
    {}
}
