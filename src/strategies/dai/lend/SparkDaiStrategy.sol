// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3LendStrategy} from "../../common/AaveV3LendStrategy.sol";

/**
 * @title  SparkDaiStrategy — DAI lending on Spark
 * @notice Spark is Sky's own money market and DAI is its flagship asset, so Spark DAI
 *         is usually the deepest and best-subsidized DAI lending venue there is. The
 *         pool is Aave-V3-shaped, so the Aave adapter serves it unchanged — pass
 *         Spark's pool and spDAI.
 */
contract SparkDaiStrategy is AaveV3LendStrategy {
    constructor(
        address _vault,
        address _dai,
        address _oracle,
        address _swapper,
        address _sparkPool,
        address _spDai,
        address _rewardsController,
        address[] memory _rewardTokens
    ) AaveV3LendStrategy(_vault, _dai, _oracle, _swapper, _sparkPool, _spDai, _rewardsController, _rewardTokens) {}
}
