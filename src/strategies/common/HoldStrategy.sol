// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseStrategy} from "../BaseStrategy.sol";

/**
 * @title  HoldStrategy — buy another token and simply hold it, in the vault
 * @notice The plainest cross-asset strategy there is: swap base into ONE other token
 *         and hold it. No venue, no lending, no emissions — the entire return is the
 *         held token's price moving against the base token.
 *
 *         For a USDC vault holding WBTC, that is a directional allocation ("this vault
 *         wants 10% BTC beta"). For a WBTC vault holding USDC, it is the opposite —
 *         a permanent de-risked sleeve. Which one it is depends only on how it is
 *         wired; the code is the same.
 *
 *   invest   : swap base -> held, then send the held token TO THE VAULT.
 *   value    : held.balanceOf(VAULT), oracle-converted to base.
 *   divest   : pull held back from the vault (transient allowance) and sell to base.
 *   harvest  : NO-OP. There is nothing to claim — that is the point of this strategy.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE RECEIPT IS THE ASSET ITSELF
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `receiptToken()` is the held token, so the vault custodies it exactly like an
 *  aToken or a 4626 share and grants the transient allowance that lets `divest` pull
 *  it back. Nothing is ever left in this strategy between calls.
 *
 *  ⚠ ONE HOLDER PER TOKEN. `positionValue()` reads the VAULT's whole balance of the
 *  held token, so two registered strategies holding the SAME token in the same vault
 *  would each report all of it and double it into NAV. This is the general rule for
 *  every receipt in this system (two Aave strategies on one market would do the same);
 *  it just bites hardest here, because plain tokens are the likeliest thing to collide.
 *
 *  ⚠ CIRCUIT BREAKER. Like every strategy whose value is a price rather than an
 *  interest accrual, a large move in the pair between two NAV refreshes can trip
 *  `strategyMaxDeltaBps`. Size that setting against the volatility of what is held.
 */
contract HoldStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    /// @notice The token this strategy buys and holds. Custodied by the VAULT.
    IERC20 public immutable held;
    uint8 public immutable heldDecimals;

    bytes public buyRoute; // base -> held
    bytes public sellRoute; // held -> base

    event RoutesSet();

    constructor(address _vault, address _asset, address _oracle, address _swapper, address _held)
        BaseStrategy(_vault, _asset, _oracle, _swapper)
    {
        require(_held != address(0) && _held != _asset, "BAD_HELD");
        held = IERC20(_held);
        heldDecimals = IERC20Metadata(_held).decimals();
    }

    function receiptToken() public view override returns (address) {
        return address(held);
    }

    // ─────────────────────────── invest / divest ────────────────────────────────

    function _invest(uint256 amount) internal override {
        uint256 minOut = _floor(_baseToHeld(amount));
        asset.forceApprove(address(swapper), amount);
        uint256 before = held.balanceOf(address(this));
        swapper.swap(address(asset), address(held), amount, minOut, buyRoute);
        uint256 bought = held.balanceOf(address(this)) - before;
        require(bought >= minOut, "MIN_OUT");

        held.safeTransfer(vault, bought); // custodied by the vault, like any receipt
    }

    function _divest(uint256 amount) internal override {
        // Sized so the EXPECTED proceeds are exactly `amount`, never grossed up for
        // slippage. Everything this sells is forwarded to the vault, so overshooting
        // would sell more of the held asset than the withdrawal needed and pay the
        // spread on the excess — every single withdrawal. Coming up a few basis points
        // short instead is explicitly allowed (`IStrategy.divest` returns what was
        // actually delivered) and the vault's queue takes the remainder from the next
        // strategy. Contrast `RotationStrategy`, which DOES gross up: it custodies its
        // own base, so its overshoot stays in the position rather than being sold off.
        uint256 needed = _baseToHeld(amount);
        uint256 heldByVault = held.balanceOf(vault);
        if (needed > heldByVault) needed = heldByVault;
        if (needed == 0) return;

        held.safeTransferFrom(vault, address(this), needed); // granted allowance
        _sellHeld(needed);
    }

    function _withdrawAll() internal override {
        uint256 heldByVault = held.balanceOf(vault);
        if (heldByVault == 0) return;
        held.safeTransferFrom(vault, address(this), heldByVault);
        _sellHeld(heldByVault);
    }

    function _sellHeld(uint256 amount) internal {
        uint256 minOut = _floor(_heldToBase(amount));
        held.forceApprove(address(swapper), amount);
        uint256 before = asset.balanceOf(address(this));
        swapper.swap(address(held), address(asset), amount, minOut, sellRoute);
        require(asset.balanceOf(address(this)) - before >= minOut, "MIN_OUT");
    }

    // ─────────────────────────────── valuation ──────────────────────────────────

    function _positionValue() internal view override returns (uint256) {
        return _heldToBase(held.balanceOf(vault));
    }

    /// @dev Overridable so a strategy holding a token with its own NATIVE exchange rate
    ///      (a liquid-staking token) can value it by that rate instead of by a market
    ///      price. See `LiquidStakingStrategy`.
    function _heldToBase(uint256 amount) internal view virtual returns (uint256) {
        return _convert(address(held), heldDecimals, amount, address(asset), assetDecimals);
    }

    function _baseToHeld(uint256 amount) internal view virtual returns (uint256) {
        return _convert(address(asset), assetDecimals, amount, address(held), heldDecimals);
    }

    function setRoutes(bytes calldata _buyRoute, bytes calldata _sellRoute) external onlyVault {
        buyRoute = _buyRoute;
        sellRoute = _sellRoute;
        emit RoutesSet();
    }
}
