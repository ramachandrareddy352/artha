// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 ════════════════════════════════════════════════════════════════════════════════
  ERC4626Strategy — wrap any external ERC-4626 yield-bearing vault
 ════════════════════════════════════════════════════════════════════════════════
  STRATEGY
    Deposits the base asset into an external ERC-4626 vault and holds its shares. The
    external vault's price-per-share rises as IT earns yield, so our position value
    grows via exchange-rate appreciation — there is no borrower and no reward token.
    This single strategy covers a huge slice of DeFi: Sky sDAI (asset DAI), Frax sFRAX
    (asset FRAX), a nested Yearn/Artha vault, an LST wrapper, Ethena sUSDe (asset USDe),
    etc. Requirement: the external vault's asset() MUST equal this strategy's asset().

  HOW USER FUNDS ARE USED
    deposit  -> _investCapital -> externalVault.deposit(asset) -> we hold ext-vault shares
    yield    -> the external vault's pricePerShare rises (interest / savings rate / staking)
    report   -> nothing to harvest; report simply recognises the appreciation and
                releases it smoothly via the base's profit lock
    withdraw -> _divestCapital -> externalVault.withdraw(asset) -> asset returned

  VALUATION  : _positionValue() = externalVault.convertToAssets(sharesHeld)
  EXIT       : as liquid as the external vault (usually instant; some have a cooldown)
  REWARD FLOW: none (yield is in the exchange rate) — _swapRewardToAsset is a no-op
 ════════════════════════════════════════════════════════════════════════════════
*/

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

import "./BaseStrategy.sol";

contract ERC4626Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IERC4626 public immutable externalVault;

    constructor(
        IERC20 _asset,
        IERC4626 _externalVault,
        string memory _name,
        string memory _symbol,
        address _management,
        address _keeper
    ) BaseStrategy(_asset, _name, _symbol, _management, _keeper) {
        require(_externalVault.asset() == address(_asset), "asset mismatch");
        externalVault = _externalVault;
        _asset.forceApprove(address(_externalVault), type(uint256).max);
    }

    function _investCapital(uint256 assets) internal override {
        externalVault.deposit(assets, address(this));
    }

    function _divestCapital(uint256 assets) internal override {
        // pull exactly `assets` of the underlying back (burns just enough ext-vault shares)
        externalVault.withdraw(assets, address(this), address(this));
    }

    function _claimRewards() internal override {
        /* no external rewards — yield lives in the share price */
    }

    function _swapRewardToAsset(address, uint256) internal override {
        /* unused */
    }

    function _positionValue() internal view override returns (uint256) {
        return externalVault.convertToAssets(externalVault.balanceOf(address(this)));
    }

    function _emergencyLiquidate(uint256 assets) internal override {
        uint256 maxAssets = externalVault.convertToAssets(externalVault.balanceOf(address(this)));
        if (assets > maxAssets) assets = maxAssets;
        externalVault.withdraw(assets, address(this), address(this));
    }
}
