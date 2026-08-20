// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CurveConvexStrategy} from "../../common/CurveConvexStrategy.sol";

/**
 * @title  CurveConvexDaiStrategy — DAI into a Curve stable pool, staked in Convex
 * @notice Adds DAI single-sided to a pegged stable pool, stakes the LP in Convex for
 *         boosted CRV + CVX, and sells both back into DAI on every harvest. Pass DAI's
 *         coin index in the chosen pool (0 in the classic 3pool) and `nCoins`.
 *
 *   yield : trading fees + boosted CRV + CVX, all compounded back into the position.
 *   risk  : peg risk across every coin in the pool, plus emission risk. See the
 *           pegged-pool warning in the base contract.
 */
contract CurveConvexDaiStrategy is CurveConvexStrategy {
    constructor(address _vault, address _dai, address _oracle, address _swapper, Config memory c)
        CurveConvexStrategy(_vault, _dai, _oracle, _swapper, c)
    {}
}
