// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {BaseStrategy} from "../BaseStrategy.sol";
import {IERC4626} from "../interfaces/IERC4626.sol";

/**
 * @title  CrossAssetERC4626Strategy — wrap a 4626 whose asset ISN'T the base token
 * @notice base <-> intermediate (the 4626's asset) via the swapper, on both entry
 *         and exit; the 4626 shares are held IN THE ARTHA VAULT.
 *
 *   invest   : base -> swap -> intermediate -> target.deposit(int, VAULT)  (shares to vault)
 *   value    : target.convertToAssets(target.balanceOf(VAULT)) -> oracle-converted to base
 *   divest   : target.withdraw(int, this, VAULT) -> swap intermediate -> base (to strategy)
 *   harvest  : NO-OP (yield is the 4626 share price rising)
 *
 *  RISK: peg (oracle vs realizable value) + swap slippage on every round-trip.
 */
contract CrossAssetERC4626Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable intermediate;
    uint8 public immutable intermediateDecimals;
    IERC4626 public immutable target;

    bytes public buyRoute; // base -> intermediate
    bytes public sellRoute; // intermediate -> base

    event RoutesSet();

    constructor(
        address _vault,
        address _asset,
        address _oracle,
        address _swapper,
        address _target,
        address _intermediate
    ) BaseStrategy(_vault, _asset, _oracle, _swapper) {
        require(_target != address(0) && _intermediate != address(0), "ZERO_ADDR");
        require(IERC4626(_target).asset() == _intermediate, "ASSET_MISMATCH");
        target = IERC4626(_target);
        intermediate = IERC20(_intermediate);
        intermediateDecimals = IERC20Metadata(_intermediate).decimals();
    }

    function receiptToken() public view override returns (address) {
        return address(target);
    }

    // ─────────────────────────── invest / divest ────────────────────────────────

    function _invest(uint256 amount) internal override {
        uint256 minInt = (_baseToIntermediate(amount) * (10_000 - maxSlippageBps)) / 10_000;
        asset.forceApprove(address(swapper), amount);
        uint256 intOut = swapper.swap(address(asset), address(intermediate), amount, minInt, buyRoute);

        intermediate.forceApprove(address(target), intOut);
        target.deposit(intOut, vault); // shares credited to the vault
    }

    function _divest(uint256 amount) internal override {
        uint256 intNeeded = _baseToIntermediate(amount);
        uint256 redeemable = target.maxWithdraw(vault);
        if (intNeeded > redeemable) intNeeded = redeemable;
        if (intNeeded == 0) return;

        // intermediate to this strategy; burns the vault's shares via granted allowance.
        target.withdraw(intNeeded, address(this), vault);
        _sellIntermediate(intNeeded);
    }

    function _withdrawAll() internal override {
        uint256 shares = target.balanceOf(vault);
        if (shares == 0) return;
        uint256 intOut = target.redeem(shares, address(this), vault);
        _sellIntermediate(intOut);
    }

    function _sellIntermediate(uint256 intAmount) internal {
        if (intAmount == 0) return;
        uint256 minBase = (_intermediateToBase(intAmount) * (10_000 - maxSlippageBps)) / 10_000;
        intermediate.forceApprove(address(swapper), intAmount);
        swapper.swap(address(intermediate), address(asset), intAmount, minBase, sellRoute); // base to this strategy
    }

    // ─────────────────────────────── value ──────────────────────────────────────

    function _positionValue() internal view override returns (uint256) {
        uint256 intAmount = target.convertToAssets(target.balanceOf(vault));
        return _intermediateToBase(intAmount);
    }

    function maxWithdraw() external view override returns (uint256) {
        return _intermediateToBase(target.maxWithdraw(vault));
    }

    // ───────────────────────── oracle conversions ───────────────────────────────

    function _intermediateToBase(uint256 intAmount) internal view returns (uint256) {
        if (intAmount == 0) return 0;
        uint256 pInt = oracle.getPrice(address(intermediate));
        uint256 pBase = oracle.getPrice(address(asset));
        require(pInt != 0 && pBase != 0, "NO_PRICE");
        return Math.mulDiv(intAmount, pInt * (10 ** assetDecimals), pBase * (10 ** intermediateDecimals));
    }

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
