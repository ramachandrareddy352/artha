// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseStrategy} from "../BaseStrategy.sol";
import {IERC4626} from "../interfaces/IERC4626.sol";

/**
 * @title  ERC4626WrapperStrategy — the universal Shape-2 adapter (executor model)
 * @notice Deposit the base token into any external ERC-4626 vault whose asset() is
 *         the base token, and hold its shares IN THE ARTHA VAULT. Value is pure
 *         exchange-rate appreciation — no reward token to claim.
 *
 *  invest   : base (in this strategy) -> external.deposit(assets, VAULT)  (shares to vault)
 *  value    : external.convertToAssets(external.balanceOf(VAULT))
 *  divest   : external.withdraw(assets, this, VAULT)  (burns the vault's shares via the
 *             transient allowance the vault grants; base delivered to this strategy,
 *             then forwarded to the vault by BaseStrategy)
 *  harvest  : NO-OP (yield is the share price rising)
 */
contract ERC4626WrapperStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IERC4626 public immutable target;

    constructor(address _vault, address _asset, address _oracle, address _swapper, address _target)
        BaseStrategy(_vault, _asset, _oracle, _swapper)
    {
        require(_target != address(0), "ZERO_ADDR");
        require(IERC4626(_target).asset() == _asset, "ASSET_MISMATCH");
        target = IERC4626(_target);
    }

    function receiptToken() public view override returns (address) {
        return address(target);
    }

    function _invest(uint256 amount) internal override {
        asset.forceApprove(address(target), amount);
        target.deposit(amount, vault); // shares credited to the vault
    }

    function _divest(uint256 amount) internal override {
        uint256 redeemable = target.maxWithdraw(vault);
        uint256 toWithdraw = amount > redeemable ? redeemable : amount;
        if (toWithdraw == 0) return;
        // base to this strategy; burns the vault's shares via the granted allowance.
        target.withdraw(toWithdraw, address(this), vault);
    }

    function _withdrawAll() internal override {
        uint256 shares = target.balanceOf(vault);
        if (shares == 0) return;
        target.redeem(shares, address(this), vault);
    }

    function _positionValue() internal view override returns (uint256) {
        return target.convertToAssets(target.balanceOf(vault));
    }

    function maxWithdraw() external view override returns (uint256) {
        return target.maxWithdraw(vault);
    }
}
