// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RotationStrategy} from "../../common/RotationStrategy.sol";

/**
 * @title  DaiRotationStrategy — the DAI vault's buy-the-dip sleeve
 * @notice Identical in behaviour to `UsdcRotationStrategy`; see that file for the
 *         parameter walkthrough and the sizing argument for stable-based vaults.
 *
 *   Worth noting for DAI specifically: `SkySDaiStrategy` already gives this vault a
 *   strong, genuinely low-risk baseline. That raises the bar this sleeve has to clear
 *   to justify its risk, so keep its weight smaller here than in a USDC vault.
 */
contract DaiRotationStrategy is RotationStrategy {
    constructor(
        address _vault,
        address _dai,
        address _oracle,
        address _swapper,
        address _quote, // WBTC / WETH
        address _daiPark, // optional 4626 over DAI (sDAI) to earn while holding stables
        address _quotePark, // optional 4626 over the quote asset
        Params memory _params
    ) RotationStrategy(_vault, _dai, _oracle, _swapper, _quote, _daiPark, _quotePark, _params) {}
}
