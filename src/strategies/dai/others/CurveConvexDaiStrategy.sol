// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CurveConvexUsdcStrategy} from "../../usdc/others/CurveConvexUsdcStrategy.sol";

/**
 * @title  CurveConvexDaiStrategy  —  DAI deployment of the Curve+Convex compounder
 * @notice Adds DAI single-sided into a 3-coin Curve stable pool, stakes the LP in
 *         Convex, compounds CRV+CVX. Base-token-agnostic logic; pass DAI as `asset`
 *         and DAI's coin index (for 3pool, DAI = 0).
 *
 *   yield : trading fees + boosted CRV + CVX, compounded into more staked LP.
 */
contract CurveConvexDaiStrategy is CurveConvexUsdcStrategy {
    constructor(address _vault, address _dai, address _oracle, address _swapper, Config memory c)
        CurveConvexUsdcStrategy(_vault, _dai, _oracle, _swapper, c)
    {}
}
