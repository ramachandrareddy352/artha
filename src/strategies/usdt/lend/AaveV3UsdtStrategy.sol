// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3LendStrategy} from "../../common/AaveV3LendStrategy.sol";

/**
 * @title  AaveV3UsdtStrategy — supply USDT to Aave V3
 * @notice USDT's "do first". Borrow demand for USDT runs hotter than for USDC, so its
 *         supply APR is usually the highest of the three majors on the same pool —
 *         same protocol risk, better rate.
 *
 *   note : USDT's non-standard ERC-20 (`transfer` returns nothing) needs no special
 *          casing — `SafeERC20` in `BaseStrategy` already handles it, and the aUSDT
 *          receipt is a well-behaved token regardless.
 */
contract AaveV3UsdtStrategy is AaveV3LendStrategy {
    constructor(
        address _vault,
        address _usdt,
        address _oracle,
        address _swapper,
        address _pool,
        address _aUsdt,
        address _rewardsController,
        address[] memory _rewardTokens
    ) AaveV3LendStrategy(_vault, _usdt, _oracle, _swapper, _pool, _aUsdt, _rewardsController, _rewardTokens) {}
}
