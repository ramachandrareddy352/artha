// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3UsdcStrategy} from "../../usdc/lend/AaveV3UsdcStrategy.sol";

/**
 * @title  SparkDaiStrategy  —  Spark DAI lending
 * @notice Spark is Sky's home market and DAI is its flagship asset, so Spark DAI is
 *         often the deepest, best-subsidized DAI lending venue. Aave-shaped pool, so
 *         it reuses the Aave adapter — pass Spark's pool + spDAI.
 */
contract SparkDaiStrategy is AaveV3UsdcStrategy {
    constructor(
        address _vault,
        address _dai,
        address _oracle,
        address _swapper,
        address _sparkPool,
        address _spDai
    ) AaveV3UsdcStrategy(_vault, _dai, _oracle, _swapper, _sparkPool, _spDai) {}
}
