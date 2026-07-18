// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CurveConvexUsdcStrategy} from "../../usdc/others/CurveConvexUsdcStrategy.sol";

/**
 * @title  CurveConvexUsdtStrategy  —  USDT deployment of the Curve+Convex compounder
 * @notice Adds USDT single-sided into a 3-coin Curve stable pool (e.g. 3pool), stakes
 *         the LP in Convex, and compounds CRV+CVX. Same composed logic as the USDC
 *         version; pass USDT as `asset` and USDT's coin index in the pool.
 *
 *   The Curve+Convex adapter is base-token-agnostic — only the coin `usdcIndex`
 *   (really "this token's index") and the reward swap routes differ per token. For
 *   3pool, DAI=0, USDC=1, USDT=2, so pass usdcIndex = 2 here.
 *
 *   yield : trading fees + boosted CRV + CVX, compounded. Watch that the target pool's
 *           USDT leg stays healthy (a depegged coin in the basket is shared IL).
 */
contract CurveConvexUsdtStrategy is CurveConvexUsdcStrategy {
    constructor(address _vault, address _usdt, address _oracle, address _swapper, Config memory c)
        CurveConvexUsdcStrategy(_vault, _usdt, _oracle, _swapper, c)
    {}
}
