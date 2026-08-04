// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseStrategy} from "../../BaseStrategy.sol";

/// @notice Minimal Aave V3 Pool surface.
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
 
/// @notice Aave V3 liquidity-mining controller (optional; many markets have none).
///         `claimAllRewardsOnBehalf` claims a user's accrued rewards to `to`, and
///         requires the caller to be an authorized claimer set by that user.
interface IAaveRewardsController {
    function claimAllRewardsOnBehalf(address[] calldata assets, address user, address to)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}

/**
 * @title  AaveV3UsdcStrategy — reference Shape-1 strategy (executor model)
 * @notice Supplies USDC to Aave V3 with the aUSDC receipt credited to the VAULT.
 *
 *   invest   : pool.supply(USDC, amount, onBehalfOf = VAULT, 0)  -> aUSDC to the vault
 *   value    : aUSDC.balanceOf(VAULT). aUSDC rebases, so the balance IS the worth.
 *   divest   : pull the vault's aUSDC (granted allowance) into this strategy, then
 *              pool.withdraw(USDC, amt, this); base is forwarded to the vault.
 *   harvest  : usually a no-op (the core USDC market has no reward token). If a
 *              controller is set, claim the VAULT's rewards on-behalf and sell to USDC.
 *              (Requires the vault to have authorized this strategy as its claimer.)
 */
contract AaveV3UsdcStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IAaveV3Pool public immutable pool;
    IERC20 public immutable aToken; // aUSDC — rebasing 1:1 receipt, held by the vault

    IAaveRewardsController public rewardsController;
    mapping(address => bytes) public swapRoute;

    event RewardsControllerSet(address controller);

    constructor(address _vault, address _asset, address _oracle, address _swapper, address _pool, address _aToken)
        BaseStrategy(_vault, _asset, _oracle, _swapper)
    {
        require(_pool != address(0) && _aToken != address(0), "ZERO_ADDR");
        pool = IAaveV3Pool(_pool);
        aToken = IERC20(_aToken);
    }

    function receiptToken() public view override returns (address) {
        return address(aToken);
    }

    function _invest(uint256 amount) internal override {
        asset.forceApprove(address(pool), amount);
        pool.supply(address(asset), amount, vault, 0); // aUSDC minted to the vault
    }

    function _divest(uint256 amount) internal override {
        uint256 held = aToken.balanceOf(vault);
        uint256 toWithdraw = amount > held ? held : amount;
        if (toWithdraw == 0) return;
        aToken.safeTransferFrom(vault, address(this), toWithdraw); // granted allowance
        pool.withdraw(address(asset), toWithdraw, address(this)); // base to this strategy
    }

    function _withdrawAll() internal override {
        uint256 held = aToken.balanceOf(vault);
        if (held == 0) return;
        aToken.safeTransferFrom(vault, address(this), held);
        pool.withdraw(address(asset), type(uint256).max, address(this));
    }

    function _positionValue() internal view override returns (uint256) {
        return aToken.balanceOf(vault); // rebasing, already in USDC terms
    }

    function _harvestRewards() internal override {
        if (address(rewardsController) == address(0)) return;

        address[] memory assets = new address[](1);
        assets[0] = address(aToken);
        (address[] memory rewards, uint256[] memory amounts) =
            rewardsController.claimAllRewardsOnBehalf(assets, vault, address(this));

        for (uint256 i; i < rewards.length; ++i) {
            if (rewards[i] == address(asset) || amounts[i] == 0) continue;
            _sellReward(rewards[i], amounts[i]);
        }
    }
 
    function _sellReward(address reward, uint256 amount) internal {
        uint256 minOut = _valueInAsset(reward, amount, IERC20MetadataLike(reward).decimals());
        IERC20(reward).forceApprove(address(swapper), amount);
        swapper.swap(reward, address(asset), amount, minOut, swapRoute[reward]);
    }

    function setSwapRoute(address reward, bytes calldata route) external onlyVault {
        swapRoute[reward] = route;
    }

    function setRewardsController(address _controller) external onlyVault {
        rewardsController = IAaveRewardsController(_controller);
        emit RewardsControllerSet(_controller);
    }
}

interface IERC20MetadataLike {
    function decimals() external view returns (uint8);
}
