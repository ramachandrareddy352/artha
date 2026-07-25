// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {BaseStrategy} from "../../BaseStrategy.sol";

/// @notice A 3-coin Curve StableSwap pool (e.g. DAI/USDC/USDT "3pool"). Other pool
///         shapes (2-coin, uint256-index, metapools) need a sibling variant — the
///         add_liquidity array arity is baked into the ABI and cannot be generic.
interface ICurveStableSwap3 {
    function add_liquidity(uint256[3] calldata amounts, uint256 min_mint_amount) external;
    function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 min_amount) external;
    function get_virtual_price() external view returns (uint256); // 1e18, monotonic (fee accrual)
}

/// @notice Convex booster — stakes a Curve LP into its reward gauge in one call.
interface IConvexBooster {
    function deposit(uint256 pid, uint256 amount, bool stake) external returns (bool);
}

/// @notice Convex reward tracker for one pool id (the "crvRewards" contract).
interface IConvexRewards {
    function balanceOf(address account) external view returns (uint256); // staked LP
    function earned(address account) external view returns (uint256); // pending CRV
    function getReward() external returns (bool); // claims CRV (+ CVX + extras) to caller
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
}

/**
 * @title  CurveConvexUsdcStrategy  —  ONE strategy composing TWO protocols
 * @notice The canonical "invest in Curve, then stake the LP in Convex for extra
 *         yield" strategy. The vault sees a single USDC-in / USDC-out box; Curve and
 *         Convex are internal. This is why it occupies ONE of the vault's 1-5
 *         strategy slots, not two.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW WE INVEST  (deposit path, all in one tx)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   1. curvePool.add_liquidity([.,USDC,.], minLp)   USDC -> Curve LP (single-sided)
 *   2. booster.deposit(pid, lp, stake=true)          LP  -> staked in Convex
 *   Nothing sits idle: the LP is staked the same transaction it is minted.
 *
 *   minLp is derived from get_virtual_price() and maxSlippageBps — NOT from the pool's
 *   own spot quote — so a manipulated pool cannot make us accept a bad mint.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW WE VALUE  (feeds totalAssets / share price)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   position : stakedLp * get_virtual_price() / 1e30   (-> USDC, 6dp)
 *              get_virtual_price only ever RISES (it is fee accrual, not a spot
 *              reserve ratio), so it cannot be flash-loan-manipulated the way raw
 *              reserves can. Safe for continuous NAV.
 *   pending  : earned() CRV, oracle-priced at a haircut. CVX is under-counted (0) in
 *              the view and realized at harvest — the safe direction.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW WE HARVEST  (where the compounding happens)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   1. convexRewards.getReward()          claim CRV + CVX (+ any extras) to this
 *   2. swap CRV->USDC and CVX->USDC       via the swapper, minOut floored at oracle
 *   3. base wrapper calls _invest(usdc)   -> add_liquidity + stake AGAIN
 *   The reinvested USDC raises stakedLp, so price-per-share rises for every holder —
 *   no new shares minted. Vault-only, so nobody can force an uneconomic dust harvest.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW WE WITHDRAW
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   1. convexRewards.withdrawAndUnwrap(lp, claim=false)   unstake LP (skip harvest)
 *   2. curvePool.remove_liquidity_one_coin(lp, usdcIndex, minOut)   LP -> USDC
 *   Returns actual USDC received (single-sided withdrawal has real slippage, floored
 *   by maxSlippageBps).
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHERE THE EXTRA YIELD COMES FROM
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Curve alone pays trading fees + base CRV. Staking the LP in Convex instead of the
 *  Curve gauge adds Convex's pooled veCRV BOOST plus CVX on top — meaningfully higher
 *  than Curve-native staking, with the harvest/compound plumbing handled here. Watch
 *  impermanent loss on volatile pairs; for a stable 3pool it is minimal.
 */
contract CurveConvexUsdcStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    ICurveStableSwap3 public immutable curvePool;
    IERC20 public immutable curveLp;
    IConvexBooster public immutable booster;
    IConvexRewards public immutable convexRewards;
    uint256 public immutable convexPid;
    uint256 public immutable usdcIndex; // USDC's position in the pool's coin list

    address public immutable crv;
    address public immutable cvx;
    uint8 public immutable crvDecimals;
    uint8 public immutable cvxDecimals;

    bytes public crvSwapRoute;
    bytes public cvxSwapRoute;

    event SwapRoutesSet();

    struct Config {
        address curvePool;
        address curveLp;
        address booster;
        address convexRewards;
        uint256 convexPid;
        uint256 usdcIndex;
        address crv;
        address cvx;
    }

    constructor(address _vault, address _asset, address _oracle, address _swapper, Config memory c)
        BaseStrategy(_vault, _asset, _oracle, _swapper)
    {
        require(
            c.curvePool != address(0) && c.curveLp != address(0) && c.booster != address(0)
                && c.convexRewards != address(0) && c.crv != address(0) && c.cvx != address(0),
            "ZERO_ADDR"
        );
        require(c.usdcIndex < 3, "BAD_INDEX");
        curvePool = ICurveStableSwap3(c.curvePool);
        curveLp = IERC20(c.curveLp);
        booster = IConvexBooster(c.booster);
        convexRewards = IConvexRewards(c.convexRewards);
        convexPid = c.convexPid;
        usdcIndex = c.usdcIndex;
        crv = c.crv;
        cvx = c.cvx;
        crvDecimals = IERC20Metadata(c.crv).decimals();
        cvxDecimals = IERC20Metadata(c.cvx).decimals();
    }

    // ─────────────────────────── invest / divest ────────────────────────────────

    function _invest(uint256 amount) internal override {
        uint256 vp = curvePool.get_virtual_price();

        uint256[3] memory amounts;
        amounts[usdcIndex] = amount;

        // expected LP (18dp) for `amount` (6dp) USDC, floored by slippage.
        uint256 expectedLp = Math.mulDiv(amount, 1e30, vp);
        uint256 minLp = (expectedLp * (10_000 - maxSlippageBps)) / 10_000;

        asset.forceApprove(address(curvePool), amount);
        uint256 lpBefore = curveLp.balanceOf(address(this));
        curvePool.add_liquidity(amounts, minLp);
        uint256 minted = curveLp.balanceOf(address(this)) - lpBefore;

        curveLp.forceApprove(address(booster), minted);
        booster.deposit(convexPid, minted, true);
    }

    function _divest(uint256 amount) internal override returns (uint256 freed) {
        uint256 vp = curvePool.get_virtual_price();

        uint256 lpNeeded = Math.mulDiv(amount, 1e30, vp);
        uint256 staked = convexRewards.balanceOf(address(this));
        if (lpNeeded > staked) lpNeeded = staked;
        if (lpNeeded == 0) return 0;

        return _unwind(lpNeeded, vp);
    }

    function _withdrawAll() internal override returns (uint256 freed) {
        uint256 staked = convexRewards.balanceOf(address(this));
        if (staked == 0) return 0;
        return _unwind(staked, curvePool.get_virtual_price());
    }

    /// @dev Unstake `lpAmount` from Convex and swap it out of Curve to USDC single-sided.
    function _unwind(uint256 lpAmount, uint256 vp) internal returns (uint256 freed) {
        convexRewards.withdrawAndUnwrap(lpAmount, false);

        uint256 expectedUsdc = Math.mulDiv(lpAmount, vp, 1e30);
        uint256 minOut = (expectedUsdc * (10_000 - maxSlippageBps)) / 10_000;

        uint256 before = asset.balanceOf(address(this));
        curvePool.remove_liquidity_one_coin(lpAmount, int128(uint128(usdcIndex)), minOut);
        freed = asset.balanceOf(address(this)) - before;
    }

    // ──────────────────────────── value / harvest ───────────────────────────────

    function _positionValue() internal view override returns (uint256) {
        uint256 stakedLp = convexRewards.balanceOf(address(this));
        if (stakedLp == 0) return 0;
        return Math.mulDiv(stakedLp, curvePool.get_virtual_price(), 1e30);
    }

    function _pendingRewardsValue() internal view override returns (uint256) {
        // CRV only; CVX under-counted (realized at harvest). Safe under-report.
        return _valueInAsset(crv, convexRewards.earned(address(this)), crvDecimals);
    }

    function _harvestRewards() internal override returns (uint256 realized) {
        convexRewards.getReward();

        uint256 crvBal = IERC20(crv).balanceOf(address(this));
        if (crvBal != 0) {
            uint256 minOut = _valueInAsset(crv, crvBal, crvDecimals);
            IERC20(crv).forceApprove(address(swapper), crvBal);
            realized += swapper.swap(crv, address(asset), crvBal, minOut, crvSwapRoute);
        }

        uint256 cvxBal = IERC20(cvx).balanceOf(address(this));
        if (cvxBal != 0) {
            uint256 minOut = _valueInAsset(cvx, cvxBal, cvxDecimals);
            IERC20(cvx).forceApprove(address(swapper), cvxBal);
            realized += swapper.swap(cvx, address(asset), cvxBal, minOut, cvxSwapRoute);
        }
    }

    function setSwapRoutes(bytes calldata _crvRoute, bytes calldata _cvxRoute) external onlyVault {
        crvSwapRoute = _crvRoute;
        cvxSwapRoute = _cvxRoute;
        emit SwapRoutesSet();
    }
}
