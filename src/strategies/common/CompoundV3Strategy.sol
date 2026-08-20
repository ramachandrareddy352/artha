// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {MultiRewardStrategy} from "./MultiRewardStrategy.sol";

/// @notice Compound V3 (Comet) — one market per base asset (the USDC Comet, the WETH
///         Comet, the USDT Comet). Supplying the BASE asset earns interest; this
///         strategy never touches the collateral/borrow side.
interface IComet {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function baseToken() external view returns (address);
    /// @dev Present-value supply balance, in base units, interest included.
    function balanceOf(address account) external view returns (uint256);
    /// @dev Base tokens the market actually holds — the ceiling on any withdrawal.
    function getReserves() external view returns (int256);
    function totalSupply() external view returns (uint256);
    function totalBorrow() external view returns (uint256);
    function getSupplyRate(uint256 utilization) external view returns (uint64);
    function getUtilization() external view returns (uint256);
    /// @dev Reward accrual counter for `account`, 6-decimal scaled.
    function baseTrackingAccrued(address account) external view returns (uint64);
    function isSupplyPaused() external view returns (bool);
    function isWithdrawPaused() external view returns (bool);
}

/// @notice Comet's separate rewards module (pays COMP).
interface ICometRewards {
    struct RewardConfig {
        address token;
        uint64 rescaleFactor;
        bool shouldUpscale;
        uint256 multiplier;
    }

    function claim(address comet, address src, bool shouldAccrue) external;
    function rewardConfig(address comet) external view returns (RewardConfig memory);
    function rewardsClaimed(address comet, address account) external view returns (uint256);
}

/**
 * @title  CompoundV3Strategy — the Comet lending adapter, token-agnostic
 * @notice Supplies the base token to a Compound III market and sells the COMP it
 *         emits. One contract serves every Comet: USDC, USDT, WETH.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY THIS ONE CUSTODIES ITS OWN POSITION
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Compound III's supply position is an INTERNAL LEDGER entry, not a transferable
 *  receipt token, so there is nothing for the vault to hold: `receiptToken()` returns
 *  `address(0)` and this strategy is the registered supplier. Comet does expose
 *  `supplyTo`/`withdrawFrom`, which would credit the vault instead — but `withdrawFrom`
 *  requires the vault to have called `comet.allow(strategy, true)`, an approval the
 *  vault has no facet to make. Supplying as ourselves keeps the exit path entirely in
 *  our own hands, which matters far more than where the ledger row sits: the vault
 *  still fully controls the position through `divest`/`emergencyWithdraw`, and a
 *  compromised strategy still cannot exceed "lose its own allocation".
 *
 *   invest   : comet.supply(base, amount)
 *   value    : comet.balanceOf(this)      — present value, interest included
 *   divest   : comet.withdraw(base, amount)  -> base to this strategy -> vault
 *   harvest  : cometRewards.claim(...) -> sell COMP -> base -> vault
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   PENDING COMP IS DELIBERATELY UNDER-REPORTED
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `CometRewards.getRewardOwed` is NOT a view (it accrues first), so it cannot be
 *  reached from NAV. This reconstructs the same figure from `baseTrackingAccrued`
 *  minus `rewardsClaimed`, which omits the sliver that has accrued since this
 *  strategy last touched the market. That under-reports — the safe direction, and the
 *  rule stated in MultiRewardStrategy. Every read is guarded: a Comet or rewards
 *  module whose layout differs (older deployments have no `multiplier`) contributes 0
 *  rather than reverting NAV.
 */
contract CompoundV3Strategy is MultiRewardStrategy {
    using SafeERC20 for IERC20;

    /// @dev Comet's own fixed-point scale for the reward multiplier.
    uint256 private constant FACTOR_SCALE = 1e18;

    IComet public immutable comet;
    ICometRewards public immutable cometRewards;

    constructor(
        address _vault,
        address _asset,
        address _oracle,
        address _swapper,
        address _comet,
        address _cometRewards,
        address _comp
    ) MultiRewardStrategy(_vault, _asset, _oracle, _swapper, _singleton(_comp)) {
        require(_comet != address(0) && _cometRewards != address(0), "ZERO_ADDR");
        require(IComet(_comet).baseToken() == _asset, "BASE_MISMATCH");
        comet = IComet(_comet);
        cometRewards = ICometRewards(_cometRewards);
    }

    /// @dev COMP as a one-element reward set. A plain array literal cannot be built
    ///      inline in a constructor argument list.
    function _singleton(address token) private pure returns (address[] memory set) {
        require(token != address(0), "ZERO_ADDR");
        set = new address[](1);
        set[0] = token;
    }

    /// @dev Internal-ledger venue: no transferable receipt for the vault to hold.
    function receiptToken() public pure override returns (address) {
        return address(0);
    }

    // ─────────────────────────── invest / divest ────────────────────────────────

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
        return comet.balanceOf(address(this)); // present value, interest included
    }

    /// @notice Capped by what the market can actually pay out right now: supplied base
    ///         that borrowers have not taken. A fully-utilized Comet cannot be exited.
    function maxWithdraw() external view override returns (uint256) {
        uint256 position = comet.balanceOf(address(this));
        uint256 liquidity = asset.balanceOf(address(comet));
        return position < liquidity ? position : liquidity;
    }

    // ──────────────────────────────── rewards ───────────────────────────────────

    function _claimRewards() internal override {
        // `shouldAccrue = true` settles accrual first, so the claim takes everything
        // owed rather than only what was booked at our last interaction.
        cometRewards.claim(address(comet), address(this), true);
    }

    function _pendingRewardAmount(address token) internal view override returns (uint256) {
        (bool ok, address rewardToken, uint64 rescaleFactor, bool shouldUpscale, uint256 multiplier) = _rewardConfig();
        if (!ok || rewardToken != token || rescaleFactor == 0) return 0;

        uint256 accrued = comet.baseTrackingAccrued(address(this));
        if (accrued == 0) return 0;

        accrued = shouldUpscale ? accrued * rescaleFactor : accrued / rescaleFactor;
        if (multiplier != FACTOR_SCALE) accrued = Math.mulDiv(accrued, multiplier, FACTOR_SCALE);

        uint256 claimed;
        try cometRewards.rewardsClaimed(address(comet), address(this)) returns (uint256 c) {
            claimed = c;
        } catch {
            return 0;
        }
        return accrued > claimed ? accrued - claimed : 0;
    }

    /// @dev Read `rewardConfig` WITHOUT letting the ABI decoder abort valuation.
    ///
    ///      CometRewards ships in two shapes in production: the original three-field
    ///      `{token, rescaleFactor, shouldUpscale}` and a newer four-field version that
    ///      appends `multiplier`. Decoding the short one into the long struct fails —
    ///      and a return-data DECODING failure is NOT caught by `try/catch`, it reverts
    ///      straight through the caller. That would take `positionValue()` down with it,
    ///      which the vault's NAV loop reads as a broken strategy: circuit breaker
    ///      tripped, whole vault auto-paused, by nothing worse than a venue we read
    ///      one word too eagerly.
    ///
    ///      So the call is made raw and the return data is decoded by LENGTH, with a
    ///      missing `multiplier` defaulting to `FACTOR_SCALE` (i.e. no scaling), which
    ///      is exactly what the three-field version means.
    function _rewardConfig()
        internal
        view
        returns (bool ok, address token, uint64 rescaleFactor, bool shouldUpscale, uint256 multiplier)
    {
        (bool success, bytes memory data) = address(cometRewards).staticcall(
            abi.encodeWithSelector(ICometRewards.rewardConfig.selector, address(comet))
        );
        if (!success || data.length < 96) return (false, address(0), 0, false, 0);

        if (data.length >= 128) {
            (token, rescaleFactor, shouldUpscale, multiplier) =
                abi.decode(data, (address, uint64, bool, uint256));
        } else {
            (token, rescaleFactor, shouldUpscale) = abi.decode(data, (address, uint64, bool));
            multiplier = FACTOR_SCALE;
        }
        ok = true;
    }

    // ───────────────────────────────── views ────────────────────────────────────

    /// @notice Live supply rate, per second, 1e18-scaled — the allocator's comparison
    ///         number for this market.
    function supplyRatePerSecond() external view returns (uint64) {
        return comet.getSupplyRate(comet.getUtilization());
    }
}
