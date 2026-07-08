// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseStrategy} from "../BaseStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IComet {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256); // base-asset supply balance (grows)
}

/**
 * @title  CompoundV3Strategy
 * @notice Supplies the Comet BASE asset (e.g. USDC) to earn supply APY. Comet's
 *         balanceOf(account) returns the base supply balance including accrued
 *         interest, which is exactly the position's underlying value.
 *
 *  IMPORTANT: `underlying` here MUST be the Comet's base asset (only the base
 *  asset earns as a supplier in Compound V3).
 */
contract CompoundV3Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IComet public immutable comet;

    constructor(address _vault, address _underlying, address _oracle, address _usdc, address _comet)
        BaseStrategy(_vault, _underlying, _oracle, _usdc)
    {
        require(_comet != address(0), "ZERO_ADDR");
        comet = IComet(_comet);
    }

    function _supply(uint256 amount) internal override {
        IERC20(underlying).forceApprove(address(comet), amount);
        comet.supply(underlying, amount);
    }

    function _redeem(uint256 amount) internal override returns (uint256) {
        comet.withdraw(underlying, amount); // sends `underlying` to this adapter
        return amount;
    }

    function _totalUnderlying() internal view override returns (uint256) {
        return comet.balanceOf(address(this));
    }
}
