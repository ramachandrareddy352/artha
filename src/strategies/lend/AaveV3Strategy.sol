// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseStrategy} from "../BaseStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/**
 * @title  AaveV3Strategy
 * @notice Supplies `underlying` to Aave V3 and holds the (rebasing) aToken.
 *         Position value = aToken.balanceOf(this), which grows with interest, so
 *         BaseStrategy's share math apportions the yield across pools automatically.
 *
 *  Best for stablecoins (USDC) and ETH-LSTs (wstETH). Reward-token incentives, if
 *  any, would be claimed in _claim() via the RewardsController (left as a no-op
 *  here; wire the controller + swap-to-underlying when a market has incentives).
 */
contract AaveV3Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IAavePool public immutable pool;
    IERC20 public immutable aToken;

    constructor(
        address _vault,
        address _underlying,
        address _oracle,
        address _usdc,
        address _pool,
        address _aToken
    ) BaseStrategy(_vault, _underlying, _oracle, _usdc) {
        require(_pool != address(0) && _aToken != address(0), "ZERO_ADDR");
        pool = IAavePool(_pool);
        aToken = IERC20(_aToken);
    }

    function _supply(uint256 amount) internal override {
        IERC20(underlying).forceApprove(address(pool), amount);
        pool.supply(underlying, amount, address(this), 0);
    }

    function _redeem(uint256 amount) internal override returns (uint256) {
        // withdraw sends `underlying` here; returns the actual amount withdrawn
        return pool.withdraw(underlying, amount, address(this));
    }

    function _totalUnderlying() internal view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }
}
