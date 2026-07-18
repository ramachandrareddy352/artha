// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {BaseStrategy} from "../BaseStrategy.sol";
import {IERC4626} from "../interfaces/IERC4626.sol";

/**
 * @title  CrossAssetERC4626Strategy  —  wrap a 4626 whose asset ISN'T the base token
 * @notice The universal wrapper (ERC4626WrapperStrategy) only works when the external
 *         vault's asset() equals our base token. Most yield-bearing tokens do NOT:
 *
 *      sUSDe  (Ethena)  -> asset USDe
 *      sFRAX  (Frax)    -> asset FRAX
 *      sUSDS  (Sky)     -> asset USDS
 *      wOUSD  (Origin)  -> asset OUSD
 *      sfrxETH(Frax)    -> asset frxETH
 *
 *  To hold any of these from a USDC / DAI / WETH vault, this strategy adds a SWAP LEG:
 *  base <-> intermediate (the 4626's asset) via the swapper, on both entry and exit.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW WE INVEST / WITHDRAW
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   invest   : swapper.swap(base -> intermediate)  then  target.deposit(intermediate)
 *   value    : target.convertToAssets(shares) = intermediate amount, then oracle-
 *              converted to base-token units (both are ~$1 stables, oracle handles
 *              the small delta).
 *   withdraw : target.withdraw(intermediate)  then  swapper.swap(intermediate -> base)
 *   harvest  : NO-OP — the underlying yield is the 4626 share price rising (Shape 2).
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE RISK THIS ADDS OVER A PLAIN WRAPPER
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Two extra exposures the same-asset wrapper does not have:
 *   1. PEG — NAV values the position in base via the oracle; if the intermediate
 *      stable depegs, reported value and realizable value diverge until it re-pegs.
 *   2. SWAP SLIPPAGE — every deposit and withdrawal crosses the swapper, so each
 *      round-trip pays spread + slippage (bounded by maxSlippageBps). This makes the
 *      strategy best for LONGER holds, not rapid in/out.
 *
 *  For sUSDe specifically this is the README's "wrap it, never build the hedge" —
 *  we take Ethena's funding yield by holding sUSDe, and never run the perp hedge
 *  ourselves.
 */
contract CrossAssetERC4626Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    /// @notice The 4626's underlying (what we must swap base into). e.g. USDe.
    IERC20 public immutable intermediate;
    uint8 public immutable intermediateDecimals;
    /// @notice The external yield-bearing 4626 (e.g. sUSDe).
    IERC4626 public immutable target;

    /// @notice buyRoute: base -> intermediate. sellRoute: intermediate -> base.
    bytes public buyRoute;
    bytes public sellRoute;

    event RoutesSet();

    constructor(
        address _vault,
        address _asset, // base token (USDC / DAI / WETH ...)
        address _oracle,
        address _swapper,
        address _target, // the 4626 (sUSDe / sFRAX / sUSDS / wOUSD ...)
        address _intermediate // the 4626's asset (USDe / FRAX / USDS / OUSD ...)
    ) BaseStrategy(_vault, _asset, _oracle, _swapper) {
        require(_target != address(0) && _intermediate != address(0), "ZERO_ADDR");
        require(IERC4626(_target).asset() == _intermediate, "ASSET_MISMATCH");
        target = IERC4626(_target);
        intermediate = IERC20(_intermediate);
        intermediateDecimals = IERC20Metadata(_intermediate).decimals();
    }

    // ─────────────────────────── invest / divest ────────────────────────────────

    function _invest(uint256 amount) internal override {
        uint256 minInt = (_baseToIntermediate(amount) * (10_000 - maxSlippageBps)) / 10_000;
        asset.forceApprove(address(swapper), amount);
        uint256 intOut = swapper.swap(address(asset), address(intermediate), amount, minInt, buyRoute);

        intermediate.forceApprove(address(target), intOut);
        target.deposit(intOut, address(this));
    }

    function _divest(uint256 amount) internal override returns (uint256 freed) {
        uint256 intNeeded = _baseToIntermediate(amount);
        uint256 redeemable = target.maxWithdraw(address(this));
        if (intNeeded > redeemable) intNeeded = redeemable;
        if (intNeeded == 0) return 0;

        target.withdraw(intNeeded, address(this), address(this));
        return _sellIntermediate(intNeeded);
    }

    function _withdrawAll() internal override returns (uint256 freed) {
        uint256 shares = target.balanceOf(address(this));
        if (shares == 0) return 0;
        uint256 intOut = target.redeem(shares, address(this), address(this));
        return _sellIntermediate(intOut);
    }

    function _sellIntermediate(uint256 intAmount) internal returns (uint256 freed) {
        uint256 minBase = (_intermediateToBase(intAmount) * (10_000 - maxSlippageBps)) / 10_000;
        intermediate.forceApprove(address(swapper), intAmount);
        uint256 before = asset.balanceOf(address(this));
        swapper.swap(address(intermediate), address(asset), intAmount, minBase, sellRoute);
        freed = asset.balanceOf(address(this)) - before;
    }

    // ─────────────────────────────── value ──────────────────────────────────────

    function _positionValue() internal view override returns (uint256) {
        uint256 intAmount = target.convertToAssets(target.balanceOf(address(this)));
        return _intermediateToBase(intAmount);
    }

    function maxWithdraw() external view override returns (uint256) {
        return _intermediateToBase(target.maxWithdraw(address(this)));
    }

    // ───────────────────────── oracle conversions ───────────────────────────────

    /// @dev intermediate units -> base units, via oracle USD prices (both 8dp).
    function _intermediateToBase(uint256 intAmount) internal view returns (uint256) {
        if (intAmount == 0) return 0;
        uint256 pInt = oracle.getPrice(address(intermediate));
        uint256 pBase = oracle.getPrice(address(asset));
        require(pInt != 0 && pBase != 0, "NO_PRICE");
        return Math.mulDiv(intAmount, pInt * (10 ** assetDecimals), pBase * (10 ** intermediateDecimals));
    }

    /// @dev base units -> intermediate units.
    function _baseToIntermediate(uint256 baseAmount) internal view returns (uint256) {
        if (baseAmount == 0) return 0;
        uint256 pInt = oracle.getPrice(address(intermediate));
        uint256 pBase = oracle.getPrice(address(asset));
        require(pInt != 0 && pBase != 0, "NO_PRICE");
        return Math.mulDiv(baseAmount, pBase * (10 ** intermediateDecimals), pInt * (10 ** assetDecimals));
    }

    function setRoutes(bytes calldata _buyRoute, bytes calldata _sellRoute) external onlyVault {
        buyRoute = _buyRoute;
        sellRoute = _sellRoute;
        emit RoutesSet();
    }
}
