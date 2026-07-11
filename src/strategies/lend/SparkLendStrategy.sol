// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseStrategy} from "../BaseStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISparkPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/**
 * @title  SparkLendStrategy
 * @notice Supplies `underlying` to SparkLend (Sky's Aave-V3-fork money market) and
 *         holds the (rebasing) spToken. Mechanically identical to the Aave adapter
 *         — same aToken accounting — but a separate deployment against Spark's pool.
 *
 *  Best for USDC/DAI/USDS and ETH-LST collateral. Spark's USDS rates are set by Sky
 *  governance (not pure utilization), which can make them more stable than Aave's.
 *  (Spark SAVINGS — sUSDS — is ERC-4626; use ERC4626Strategy for that instead.)
 */
contract SparkLendStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    ISparkPool public immutable pool;
    IERC20 public immutable spToken;

    constructor(
        address _vault,
        address _underlying,
        address _oracle,
        address _usdc,
        address _pool,
        address _spToken
    ) BaseStrategy(_vault, _underlying, _oracle, _usdc) {
        require(_pool != address(0) && _spToken != address(0), "ZERO_ADDR");
        pool = ISparkPool(_pool);
        spToken = IERC20(_spToken);
    }

    function _supply(uint256 amount) internal override {
        IERC20(underlying).forceApprove(address(pool), amount);
        pool.supply(underlying, amount, address(this), 0);
    }

    function _redeem(uint256 amount) internal override returns (uint256) {
        return pool.withdraw(underlying, amount, address(this));
    }

    function _totalUnderlying() internal view override returns (uint256) {
        return spToken.balanceOf(address(this));
    }
}
