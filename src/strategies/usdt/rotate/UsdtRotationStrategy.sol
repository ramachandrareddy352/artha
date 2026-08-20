// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RotationStrategy} from "../../common/RotationStrategy.sol";

/**
 * @title  UsdtRotationStrategy — the USDT vault's buy-the-dip sleeve
 * @notice Identical in behaviour to `UsdcRotationStrategy` — buy the volatile quote
 *         asset after a drawdown, sell it into strength, keep the difference in USDT.
 *         See that file for the parameter walkthrough and for why a stable-based
 *         vault must keep this sleeve small and its stop-loss tight: USDT depositors
 *         did not sign up for BTC or ETH exposure, so it is a bounded, disclosed
 *         directional allocation rather than yield.
 *
 *   Both hard requirements apply: widen the vault's `strategyMaxDeltaBps`, and keep
 *   `tend()` on a keeper schedule.
 */
contract UsdtRotationStrategy is RotationStrategy {
    constructor(
        address _vault,
        address _usdt,
        address _oracle,
        address _swapper,
        address _quote, // WBTC / WETH
        address _usdtPark, // optional 4626 over USDT to earn while holding stables
        address _quotePark, // optional 4626 over the quote asset
        Params memory _params
    ) RotationStrategy(_vault, _usdt, _oracle, _swapper, _quote, _usdtPark, _quotePark, _params) {}
}
