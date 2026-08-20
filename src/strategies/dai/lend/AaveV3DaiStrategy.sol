// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3LendStrategy} from "../../common/AaveV3LendStrategy.sol";

/**
 * @title  AaveV3DaiStrategy — supply DAI to Aave V3
 * @notice The lending leg of the DAI vault.
 *
 *   note : DAI is the one major where lending is usually NOT the best option. sDAI —
 *          the Sky Savings Rate, with no borrower and no liquidation exposure at all —
 *          typically pays more for strictly less risk, which is why `SkySDaiStrategy`
 *          is the DAI vault's "do first" and this is the diversifier beside it.
 */
contract AaveV3DaiStrategy is AaveV3LendStrategy {
    constructor(
        address _vault,
        address _dai,
        address _oracle,
        address _swapper,
        address _pool,
        address _aDai,
        address _rewardsController,
        address[] memory _rewardTokens
    ) AaveV3LendStrategy(_vault, _dai, _oracle, _swapper, _pool, _aDai, _rewardsController, _rewardTokens) {}
}
