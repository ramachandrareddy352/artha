// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseStrategy} from "../BaseStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMetaMorpho {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title  MorphoStrategy
 * @notice Supplies `underlying` into a curated MetaMorpho (ERC-4626) vault. The
 *         adapter holds the MetaMorpho shares; underlying value =
 *         convertToAssets(vaultShares held). BaseStrategy layers its own per-pool
 *         shares on top so multiple Artha pools can share one adapter safely.
 *
 *  NOTE: Morpho does not socialize bad debt — the specific MetaMorpho vault
 *  (its curator + markets) is a governance choice; point `_metaMorpho` at a
 *  vetted vault whose underlying asset == `_underlying`.
 */
contract MorphoStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IMetaMorpho public immutable metaMorpho;

    constructor(address _vault, address _underlying, address _oracle, address _usdc, address _metaMorpho)
        BaseStrategy(_vault, _underlying, _oracle, _usdc)
    {
        require(_metaMorpho != address(0), "ZERO_ADDR");
        metaMorpho = IMetaMorpho(_metaMorpho);
    }

    function _supply(uint256 amount) internal override {
        IERC20(underlying).forceApprove(address(metaMorpho), amount);
        metaMorpho.deposit(amount, address(this));
    }

    function _redeem(uint256 amount) internal override returns (uint256) {
        // withdraw exactly `amount` assets to this adapter (burns the needed shares)
        metaMorpho.withdraw(amount, address(this), address(this));
        return amount;
    }

    function _totalUnderlying() internal view override returns (uint256) {
        return metaMorpho.convertToAssets(metaMorpho.balanceOf(address(this)));
    }
}
