// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {BaseStrategy} from "../BaseStrategy.sol";

/// @notice Beefy "mooVault" surface. NOT ERC-4626 — its own deposit/withdraw shape,
///         priced by getPricePerFullShare (1e18).
interface IBeefyVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 shares) external;
    function balanceOf(address account) external view returns (uint256);
    function getPricePerFullShare() external view returns (uint256); // 1e18 want per share
    function want() external view returns (address); // the underlying token
}

/**
 * @title  BeefyStrategy  —  wrap a Beefy auto-compounding vault
 * @notice Beefy vaults already harvest and compound their underlying farm internally,
 *         so from our side this is a Shape-2 (exchange-rate) holding: deposit the
 *         `want` token, hold mooShares, value via getPricePerFullShare, no harvest.
 *
 *  Given its own base (not the 4626 wrapper) because Beefy's interface differs from
 *  ERC-4626: `deposit(uint256)` / `withdraw(uint256 shares)` and a 1e18
 *  price-per-share instead of convertToAssets.
 *
 *   invest   : beefy.deposit(amount)                       want -> mooShares
 *   value    : mooShares * getPricePerFullShare() / 1e18   -> want units (== base)
 *   withdraw : beefy.withdraw(shares)                       mooShares -> want
 *   harvest  : NO-OP — Beefy compounds internally; the yield is pps rising.
 *
 *  CONSTRAINT: beefy.want() MUST equal the base token (asserted). Deploy one instance
 *  per Beefy vault whose want is a token an Artha vault holds.
 */
contract BeefyStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IBeefyVault public immutable beefy;

    constructor(address _vault, address _asset, address _oracle, address _swapper, address _beefy)
        BaseStrategy(_vault, _asset, _oracle, _swapper)
    {
        require(_beefy != address(0), "ZERO_ADDR");
        require(IBeefyVault(_beefy).want() == _asset, "WANT_MISMATCH");
        beefy = IBeefyVault(_beefy);
    }

    function _invest(uint256 amount) internal override {
        asset.forceApprove(address(beefy), amount);
        beefy.deposit(amount);
    }

    function _divest(uint256 amount) internal override returns (uint256 freed) {
        uint256 pps = beefy.getPricePerFullShare();
        uint256 sharesNeeded = Math.mulDiv(amount, 1e18, pps);
        uint256 held = beefy.balanceOf(address(this));
        if (sharesNeeded > held) sharesNeeded = held;
        if (sharesNeeded == 0) return 0;

        uint256 before = asset.balanceOf(address(this));
        beefy.withdraw(sharesNeeded);
        freed = asset.balanceOf(address(this)) - before;
    }

    function _withdrawAll() internal override returns (uint256 freed) {
        uint256 held = beefy.balanceOf(address(this));
        if (held == 0) return 0;
        uint256 before = asset.balanceOf(address(this));
        beefy.withdraw(held);
        freed = asset.balanceOf(address(this)) - before;
    }

    function _positionValue() internal view override returns (uint256) {
        return Math.mulDiv(beefy.balanceOf(address(this)), beefy.getPricePerFullShare(), 1e18);
    }
}
