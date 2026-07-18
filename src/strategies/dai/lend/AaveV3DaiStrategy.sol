// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3UsdcStrategy} from "../../usdc/lend/AaveV3UsdcStrategy.sol";

/**
 * @title  AaveV3DaiStrategy  —  DAI deployment of the Aave V3 lending adapter
 * @notice Supplies DAI to Aave V3 for borrower interest via rebasing aDAI. Same
 *         token-agnostic logic as AaveV3UsdcStrategy, on the DAI market.
 *
 *   yield : DAI borrower interest. Note DAI also has a strong NON-lending option —
 *           sDAI (the Sky Savings Rate) — which is often the better risk-adjusted DAI
 *           venue with no borrower/liquidation exposure. See SkySDaiStrategy.
 */
contract AaveV3DaiStrategy is AaveV3UsdcStrategy {
    constructor(
        address _vault,
        address _dai,
        address _oracle,
        address _swapper,
        address _pool,
        address _aDai
    ) AaveV3UsdcStrategy(_vault, _dai, _oracle, _swapper, _pool, _aDai) {}
}
