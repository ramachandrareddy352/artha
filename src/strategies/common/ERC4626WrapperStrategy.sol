// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseStrategy} from "../BaseStrategy.sol";
import {IERC4626} from "../interfaces/IERC4626.sol";

/**
 * @title  ERC4626WrapperStrategy  —  the universal Shape-2 adapter
 * @notice ONE strategy that covers a large slice of all of DeFi: deposit the base
 *         token into any external ERC-4626 vault and hold its shares. Value is pure
 *         exchange-rate appreciation — the share price rises, there is no reward
 *         token to claim or sell.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHAT THIS ONE FILE COVERS (deploy one instance per target, same code)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *      Sky        sUSDS / sDAI     — the Sky Savings Rate (RWA T-bills + fees)
 *      Ethena     sUSDe            — delta-neutral perp funding, wrapped
 *      Frax       sFRAX / sfrxETH  — protocol revenue / staking, wrapped
 *      Origin     wOUSD            — auto-allocated lending/LP yield, wrapped
 *      Morpho     any MetaMorpho   — curated isolated-market lending
 *      Yearn      any V3 vault     — vault-of-vaults leg
 *      any other yield-bearing ERC-4626 whose asset() == this strategy's base token
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW IT WORKS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   invest   : base -> external.deposit(assets, this)  -> holds external shares
 *   value    : external.convertToAssets(external.balanceOf(this))  (base token)
 *   harvest  : NOTHING to do — yield is the share price rising, not a claimable token.
 *              So `_harvestRewards` is left at the base default (0) and a harvest call
 *              is a pure no-op. This is why Shape-2 strategies need no oracle or swapper.
 *   withdraw : external.withdraw(assets, this, this)  (burns exactly enough shares)
 *   settle   : there is no per-position settle here; the vault reads `totalAssets`
 *              live off the current share price whenever it prices its own shares.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW YIELD IS GENERATED / GROWS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  The external vault runs its own strategy underneath (T-bills, funding, lending)
 *  and folds the proceeds into its share price. Our share count stays fixed while
 *  `convertToAssets` returns more each block — so `_positionValue` rises on its own,
 *  which lifts the Artha vault's own price-per-share, which lifts every user's
 *  balance. Nesting is where "yield on yield" comes from: this leg can point at a
 *  vault that itself points at more yield sources — just NEVER point it back into an
 *  Artha vault in its own dependency graph (circular-inflation / loop risk).
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ONE CONSTRAINT
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  external.asset() MUST equal the base token (asserted in the constructor). To reach
 *  a vault whose asset differs from the base (e.g. base USDC -> sUSDS on USDS), a
 *  cross-asset variant with a swap leg is needed — a separate, later strategy.
 */
contract ERC4626WrapperStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    /// @notice The external yield-bearing vault this strategy wraps.
    IERC4626 public immutable target;

    /// @param _oracle  unused by this Shape-2 strategy (no reward token); pass the
    ///                 oracle anyway for a uniform constructor, or address(0).
    /// @param _swapper likewise unused; pass address(0) is fine.
    constructor(address _vault, address _asset, address _oracle, address _swapper, address _target)
        BaseStrategy(_vault, _asset, _oracle, _swapper)
    {
        require(_target != address(0), "ZERO_ADDR");
        require(IERC4626(_target).asset() == _asset, "ASSET_MISMATCH");
        target = IERC4626(_target);
    }

    function _invest(uint256 amount) internal override {
        asset.forceApprove(address(target), amount);
        target.deposit(amount, address(this));
    }

    function _divest(uint256 amount) internal override returns (uint256 freed) {
        uint256 redeemable = target.maxWithdraw(address(this));
        uint256 toWithdraw = amount > redeemable ? redeemable : amount;
        if (toWithdraw == 0) return 0;
        target.withdraw(toWithdraw, address(this), address(this));
        return toWithdraw;
    }

    function _positionValue() internal view override returns (uint256) {
        return target.convertToAssets(target.balanceOf(address(this)));
    }

    /// @dev Exit uses redeem(all shares) so a rounding dust of shares can't strand value.
    function _withdrawAll() internal override returns (uint256 freed) {
        uint256 shares = target.balanceOf(address(this));
        if (shares == 0) return 0;
        return target.redeem(shares, address(this), address(this));
    }

    /// @dev Venue liquidity can cap what is withdrawable right now (e.g. a MetaMorpho
    ///      vault whose markets are fully utilized). Report the venue's own answer.
    function maxWithdraw() external view override returns (uint256) {
        return target.maxWithdraw(address(this));
    }
}
