// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3UsdcStrategy} from "./AaveV3UsdcStrategy.sol";

/**
 * @title  SparkUsdcStrategy  —  Spark (Sky's Aave-V3 fork) USDC lending
 * @notice Spark's lending pool is Aave V3-shaped (supply/withdraw, rebasing spTokens),
 *         so it reuses the Aave adapter unchanged — pass Spark's pool + spUSDC.
 *
 *   yield : USDC borrower interest on Spark, whose rates are governance-set and tied to
 *           the Sky ecosystem — typically steadier than Aave's utilization-driven rate,
 *           and often subsidized. A good diversifier alongside AaveV3UsdcStrategy.
 */
contract SparkUsdcStrategy is AaveV3UsdcStrategy {
    constructor(
        address _vault,
        address _usdc,
        address _oracle,
        address _swapper,
        address _sparkPool,
        address _spUsdc
    ) AaveV3UsdcStrategy(_vault, _usdc, _oracle, _swapper, _sparkPool, _spUsdc) {}
}
