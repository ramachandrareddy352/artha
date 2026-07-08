// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title  BaseStrategy
 * @notice Shared logic for all LEND adapters. A single adapter instance serves
 *         every pool: it tracks each pool's slice of the position with internal
 *         "shares" (an ERC-4626-in-miniature over the underlying), so rebasing
 *         receipts (aToken) and yield are apportioned correctly per pool.
 *
 *      poolShares[poolId] / totalPoolShares  =  pool's fraction of the position
 *      totalValue(poolId) = underlyingValueUsdc * poolShares[poolId] / totalPoolShares
 *
 *  Only the Diamond ("vault") may deposit/withdraw. Concrete adapters implement
 *  the protocol-specific hooks: _supply, _redeem, _totalUnderlying, _claim.
 */
abstract contract BaseStrategy is IStrategy {
    using SafeERC20 for IERC20;

    address public immutable vault;      // the Diamond — only authorized caller
    address public immutable override underlying;
    address public immutable oracle;     // to value non-USDC underlying
    address public immutable usdc;

    mapping(uint8 => uint256) public override poolShares;
    uint256 public override totalPoolShares;

    event Deposited(uint8 indexed poolId, uint256 amount, uint256 shares);
    event Withdrawn(uint8 indexed poolId, uint256 amount, uint256 shares);
    event Harvested(uint8 indexed poolId, uint256 rewards);

    modifier onlyVault() {
        require(msg.sender == vault, "NOT_VAULT");
        _;
    }

    constructor(address _vault, address _underlying, address _oracle, address _usdc) {
        require(_vault != address(0) && _underlying != address(0), "ZERO_ADDR");
        vault = _vault;
        underlying = _underlying;
        oracle = _oracle;
        usdc = _usdc;
    }

    /*//////////////////////////////////////////////////////////////
                     PROTOCOL-SPECIFIC HOOKS (override)
    //////////////////////////////////////////////////////////////*/

    function _supply(uint256 amount) internal virtual;
    function _redeem(uint256 amount) internal virtual returns (uint256 redeemed);
    function _totalUnderlying() internal view virtual returns (uint256);

    function _claim() internal virtual returns (uint256) {
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                              VALUATION
    //////////////////////////////////////////////////////////////*/

    function _toUsdc(uint256 amountUnderlying) internal view returns (uint256) {
        if (underlying == usdc) return amountUnderlying;
        return IOracle(oracle).valueInUsdc(underlying, amountUnderlying);
    }

    function totalValue(uint8 poolId) external view override returns (uint256) {
        uint256 tps = totalPoolShares;
        if (tps == 0) return 0;
        uint256 underlyingUsdc = _toUsdc(_totalUnderlying());
        return Math.mulDiv(underlyingUsdc, poolShares[poolId], tps);
    }

    /*//////////////////////////////////////////////////////////////
                              VAULT ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint8 poolId, uint256 amount) external override onlyVault {
        require(amount != 0, "ZERO");
        uint256 beforeBal = _totalUnderlying();

        IERC20(underlying).safeTransferFrom(vault, address(this), amount);
        _supply(amount);

        // mint shares proportional to the pre-deposit position (1:1 for the first)
        uint256 shares =
            (totalPoolShares == 0 || beforeBal == 0) ? amount : Math.mulDiv(amount, totalPoolShares, beforeBal);
        poolShares[poolId] += shares;
        totalPoolShares += shares;
        emit Deposited(poolId, amount, shares);
    }

    function withdraw(uint8 poolId, uint256 amount) external override onlyVault returns (uint256 withdrawn) {
        uint256 total = _totalUnderlying();
        require(total != 0, "EMPTY");
        uint256 shares = Math.mulDiv(amount, totalPoolShares, total);
        require(shares <= poolShares[poolId], "EXCEEDS_POOL");

        poolShares[poolId] -= shares;
        totalPoolShares -= shares;

        withdrawn = _redeem(amount);
        IERC20(underlying).safeTransfer(vault, withdrawn);
        emit Withdrawn(poolId, amount, shares);
    }

    function withdrawShares(uint8 poolId, uint256 shareAmount)
        external
        override
        onlyVault
        returns (uint256 withdrawn)
    {
        require(shareAmount != 0 && shareAmount <= poolShares[poolId], "EXCEEDS_POOL");
        uint256 amount = Math.mulDiv(_totalUnderlying(), shareAmount, totalPoolShares);

        poolShares[poolId] -= shareAmount;
        totalPoolShares -= shareAmount;

        withdrawn = _redeem(amount);
        IERC20(underlying).safeTransfer(vault, withdrawn);
        emit Withdrawn(poolId, amount, shareAmount);
    }

    function harvest(uint8 poolId) external override onlyVault returns (uint256 rewards) {
        rewards = _claim();
        emit Harvested(poolId, rewards);
    }
}
