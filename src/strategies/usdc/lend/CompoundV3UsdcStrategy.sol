// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseStrategy} from "../../BaseStrategy.sol";

/// @notice Compound V3 (Comet) — a single-base-asset market (e.g. the USDC Comet).
interface IComet {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function baseToken() external view returns (address);
    function balanceOf(address account) external view returns (uint256); // present-value supply, in base units
}

/// @notice Comet's separate rewards module (pays COMP).
interface ICometRewards {
    function claim(address comet, address src, bool shouldAccrue) external;
}

/**
 * @title  CompoundV3UsdcStrategy — Shape 1 (interest) + Shape 3 (COMP) — executor model
 * @notice Compound III's supply position is an INTERNAL LEDGER, not a transferable
 *         receipt token, so there is nothing to custody in the vault:
 *         `receiptToken()` returns `address(0)` and the strategy holds the Comet
 *         position directly. The vault fully controls it — `divest`/`emergencyWithdraw`
 *         unwind it and return base to the vault, and `positionValue()` reads it — so
 *         a compromised strategy still cannot exceed "lose its own position."
 *
 *   invest   : comet.supply(USDC, amount)            (this strategy becomes the supplier)
 *   value    : comet.balanceOf(this)                 (present value, interest included)
 *   divest   : comet.withdraw(USDC, amount)          (base to this strategy -> vault)
 *   harvest  : claim COMP -> swap COMP->USDC (to this strategy -> vault)
 */
contract CompoundV3UsdcStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IComet public immutable comet;
    ICometRewards public immutable cometRewards;
    address public immutable comp;
    uint8 public immutable compDecimals;

    bytes public compSwapRoute;

    event CompSwapRouteSet();

    constructor(
        address _vault,
        address _asset, // USDC
        address _oracle,
        address _swapper,
        address _comet,
        address _cometRewards,
        address _comp
    ) BaseStrategy(_vault, _asset, _oracle, _swapper) {
        require(_comet != address(0) && _cometRewards != address(0) && _comp != address(0), "ZERO_ADDR");
        require(IComet(_comet).baseToken() == _asset, "BASE_MISMATCH");
        comet = IComet(_comet);
        cometRewards = ICometRewards(_cometRewards);
        comp = _comp;
        compDecimals = IERC20Metadata(_comp).decimals();
    }

    /// @dev Internal-ledger venue: no transferable receipt for the vault to hold.
    function receiptToken() public pure override returns (address) {
        return address(0);
    }

    function _invest(uint256 amount) internal override {
        asset.forceApprove(address(comet), amount);
        comet.supply(address(asset), amount);
    }

    function _divest(uint256 amount) internal override {
        uint256 held = comet.balanceOf(address(this));
        uint256 toWithdraw = amount > held ? held : amount;
        if (toWithdraw == 0) return;
        comet.withdraw(address(asset), toWithdraw); // base delivered to this strategy
    }

    function _withdrawAll() internal override {
        uint256 held = comet.balanceOf(address(this));
        if (held == 0) return;
        comet.withdraw(address(asset), held);
    }

    function _positionValue() internal view override returns (uint256) {
        return comet.balanceOf(address(this)); // present value, in USDC, includes interest
    }

    function _harvestRewards() internal override {
        cometRewards.claim(address(comet), address(this), true);
        uint256 compBal = IERC20(comp).balanceOf(address(this));
        if (compBal == 0) return;

        uint256 minOut = _valueInAsset(comp, compBal, compDecimals);
        IERC20(comp).forceApprove(address(swapper), compBal);
        swapper.swap(comp, address(asset), compBal, minOut, compSwapRoute); // USDC to this strategy
    }

    function setCompSwapRoute(bytes calldata route) external onlyVault {
        compSwapRoute = route;
        emit CompSwapRouteSet();
    }
}
