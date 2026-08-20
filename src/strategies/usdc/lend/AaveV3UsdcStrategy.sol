// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3LendStrategy} from "../../common/AaveV3LendStrategy.sol";

/**
 * @title  AaveV3UsdcStrategy — supply USDC to Aave V3
 * @notice The reference lending leg of the USDC vault, and the venue every other one
 *         is measured against: the deepest stablecoin market on-chain, instant exit
 *         while the reserve has liquidity, no emission token to babysit on the core
 *         market. All logic lives in `AaveV3LendStrategy`; this names the deployment.
 *
 *   yield : USDC borrower interest, floating with utilization. Lower than the exotic
 *           legs and far more reliable — this is the "do first" allocation.
 *   risk  : Aave protocol risk plus bad debt on any collateral in the same pool.
 *           Withdrawals fail while the reserve is paused or fully utilized; the vault's
 *           queue routes around that.
 */
contract AaveV3UsdcStrategy is AaveV3LendStrategy {
    constructor(
        address _vault,
        address _usdc,
        address _oracle,
        address _swapper,
        address _pool,
        address _aUsdc,
        address _rewardsController,
        address[] memory _rewardTokens
    ) AaveV3LendStrategy(_vault, _usdc, _oracle, _swapper, _pool, _aUsdc, _rewardsController, _rewardTokens) {}
}
