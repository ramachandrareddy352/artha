// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CurveConvexStrategy} from "../../common/CurveConvexStrategy.sol";

/**
 * @title  CurveConvexUsdcStrategy — USDC into a Curve stable pool, staked in Convex
 * @notice The USDC vault's emission-farming leg: add USDC single-sided to a pegged
 *         stable pool (3pool and friends), stake the LP in Convex for the boosted CRV
 *         plus CVX, and sell both back into USDC on every harvest.
 *
 *         One strategy slot, three protocols — the vault never learns that Convex is
 *         involved. All logic lives in `CurveConvexStrategy`; pass USDC's coin index
 *         in the chosen pool (0 = DAI, 1 = USDC, 2 = USDT in the classic 3pool) and
 *         `nCoins = 3`.
 *
 *   yield : trading fees (the virtual price grinding up) + boosted CRV + CVX.
 *   risk  : a depeg in ANY coin of the pool hits the single-sided exit, and emissions
 *           are a variable, governance-set subsidy that can be cut. Higher tier than
 *           plain lending — see the pegged-pool warning in the base contract.
 */
contract CurveConvexUsdcStrategy is CurveConvexStrategy {
    constructor(address _vault, address _usdc, address _oracle, address _swapper, Config memory c)
        CurveConvexStrategy(_vault, _usdc, _oracle, _swapper, c)
    {}
}
