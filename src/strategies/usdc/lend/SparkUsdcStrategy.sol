// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3LendStrategy} from "../../common/AaveV3LendStrategy.sol";

/**
 * @title  SparkUsdcStrategy — Spark (Sky's Aave-V3 fork) USDC lending
 * @notice Spark's pool is Aave-V3-shaped down to the rebasing spToken, so it reuses
 *         the Aave adapter unchanged — pass Spark's pool and spUSDC.
 *
 *   yield : USDC borrower interest on Spark, whose rates are GOVERNANCE-set and tied
 *           to the Sky ecosystem rather than purely to utilization — typically steadier
 *           than Aave's, and often subsidized.
 *   why both : holding Aave and Spark side by side is genuine diversification of
 *           protocol risk at almost identical market risk, and the two rates rarely
 *           move together — the allocator can lean toward whichever is paying.
 */
contract SparkUsdcStrategy is AaveV3LendStrategy {
    constructor(
        address _vault,
        address _usdc,
        address _oracle,
        address _swapper,
        address _sparkPool,
        address _spUsdc,
        address _rewardsController,
        address[] memory _rewardTokens
    ) AaveV3LendStrategy(_vault, _usdc, _oracle, _swapper, _sparkPool, _spUsdc, _rewardsController, _rewardTokens) {}
}
