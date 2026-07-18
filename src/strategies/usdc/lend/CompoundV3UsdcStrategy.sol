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
 * @title  CompoundV3UsdcStrategy  —  Shape 1 (interest) + Shape 3 (COMP emissions)
 * @notice Supplies USDC to a Compound V3 (Comet) market for supply interest, and
 *         additionally harvests COMP emissions, sells them to USDC, and compounds.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW WE INVEST
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   invest   : comet.supply(USDC, amount). Comet tracks this contract's present-value
 *              supply balance internally (interest is baked into balanceOf).
 *   value    : comet.balanceOf(this) — already the current USDC worth including
 *              accrued interest — PLUS the haircut value of unclaimed COMP.
 *   withdraw : comet.withdraw(USDC, amount). Instant, exact, up to available liquidity.
 *   claim    : cometRewards.claim(comet, this, true) transfers accrued COMP here.
 *   harvest  : claim COMP -> swap COMP->USDC via the swapper (minOut floored at the
 *              oracle value) -> the base wrapper reinvests the USDC with comet.supply.
 *   settle   : none; interest accrues into balanceOf continuously.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ON VALUING UNCLAIMED COMP
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Comet's exact "COMP owed" reader is a mutating call, so it cannot be used from a
 *  view. Rather than over-report, `_pendingRewardsValue` returns 0 — COMP is realized
 *  only at harvest. Consequence: harvest nudges price-per-share UP slightly (the
 *  under-counted COMP becomes real). That is the safe direction (never gameable for
 *  profit), and COMP on a supply position is small next to principal. If that small
 *  step ever needs closing, feed a pending-COMP estimate in here or add profit-locking
 *  at the vault — deliberately left out to keep this adapter simple.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW YIELD IS GENERATED / GROWS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Two streams: borrower interest (baked into balanceOf) and COMP emissions (a
 *  separate governance-token stream). The COMP is "emissions yield" — only real if
 *  sold, so we sell it every harvest and never hold it betting on price. Compounding
 *  the proceeds back into the supply position is what turns a flat APR into a rising
 *  price-per-share.
 */
contract CompoundV3UsdcStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IComet public immutable comet;
    ICometRewards public immutable cometRewards;
    address public immutable comp;
    uint8 public immutable compDecimals;

    /// @notice Venue route for the COMP->USDC swap. Vault-settable.
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

    function _invest(uint256 amount) internal override {
        asset.forceApprove(address(comet), amount);
        comet.supply(address(asset), amount);
    }

    function _divest(uint256 amount) internal override returns (uint256 freed) {
        uint256 held = comet.balanceOf(address(this));
        uint256 toWithdraw = amount > held ? held : amount;
        if (toWithdraw == 0) return 0;
        uint256 before = asset.balanceOf(address(this));
        comet.withdraw(address(asset), toWithdraw);
        freed = asset.balanceOf(address(this)) - before;
    }

    function _positionValue() internal view override returns (uint256) {
        return comet.balanceOf(address(this)); // present value, in USDC, includes interest
    }

    function _withdrawAll() internal override returns (uint256 freed) {
        uint256 held = comet.balanceOf(address(this));
        if (held == 0) return 0;
        uint256 before = asset.balanceOf(address(this));
        comet.withdraw(address(asset), held);
        freed = asset.balanceOf(address(this)) - before;
    }

    function _harvestRewards() internal override returns (uint256 realized) {
        cometRewards.claim(address(comet), address(this), true);
        uint256 compBal = IERC20(comp).balanceOf(address(this));
        if (compBal == 0) return 0;

        uint256 minOut = _valueInAsset(comp, compBal, compDecimals);
        IERC20(comp).forceApprove(address(swapper), compBal);
        realized = swapper.swap(comp, address(asset), compBal, minOut, compSwapRoute);
    }

    function setCompSwapRoute(bytes calldata route) external onlyVault {
        compSwapRoute = route;
        emit CompSwapRouteSet();
    }
}
