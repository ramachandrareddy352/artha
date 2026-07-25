// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {BaseStrategy} from "../../BaseStrategy.sol";

/// @notice A 3-coin Curve StableSwap pool (e.g. DAI/USDC/USDT "3pool").
interface ICurveStableSwap3 {
    function add_liquidity(uint256[3] calldata amounts, uint256 min_mint_amount) external;
    function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 min_amount) external;
    function get_virtual_price() external view returns (uint256); // 1e18, monotonic (fee accrual)
}

interface IConvexBooster {
    function deposit(uint256 pid, uint256 amount, bool stake) external returns (bool);
}

interface IConvexRewards {
    function balanceOf(address account) external view returns (uint256); // staked LP
    function earned(address account) external view returns (uint256); // pending CRV
    function getReward() external returns (bool);
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
}

/**
 * @title  CurveConvexUsdcStrategy — ONE strategy composing Curve + Convex (executor model)
 * @notice The canonical "add liquidity to Curve, stake the LP in Convex" strategy.
 *         The Convex staked position is an INTERNAL, non-transferable ledger keyed to
 *         the staker, so there is no receipt token for the vault to hold:
 *         `receiptToken()` returns `address(0)` and the strategy holds the LP/Convex
 *         position directly. The vault fully controls it via divest/emergencyWithdraw
 *         (which unwind to USDC and return it to the vault) and values it via
 *         positionValue(). All slippage floors derive from `get_virtual_price()` (a
 *         monotonic, non-spot value), never a manipulable pool quote.
 */
contract CurveConvexUsdcStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    ICurveStableSwap3 public immutable curvePool;
    IERC20 public immutable curveLp;
    IConvexBooster public immutable booster;
    IConvexRewards public immutable convexRewards;
    uint256 public immutable convexPid;
    uint256 public immutable usdcIndex;

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

    /// @dev Internal-ledger venue (Convex staking): no receipt token for the vault.
    function receiptToken() public pure override returns (address) {
        return address(0);
    }

    // ─────────────────────────── invest / divest ────────────────────────────────

    function _invest(uint256 amount) internal override {
        uint256 vp = curvePool.get_virtual_price();

        uint256[3] memory amounts;
        amounts[usdcIndex] = amount;

        uint256 expectedLp = Math.mulDiv(amount, 1e30, vp);
        uint256 minLp = (expectedLp * (10_000 - maxSlippageBps)) / 10_000;

        asset.forceApprove(address(curvePool), amount);
        uint256 lpBefore = curveLp.balanceOf(address(this));
        curvePool.add_liquidity(amounts, minLp);
        uint256 minted = curveLp.balanceOf(address(this)) - lpBefore;

        curveLp.forceApprove(address(booster), minted);
        booster.deposit(convexPid, minted, true);
    }

    function _divest(uint256 amount) internal override {
        uint256 vp = curvePool.get_virtual_price();
        uint256 lpNeeded = Math.mulDiv(amount, 1e30, vp);
        uint256 staked = convexRewards.balanceOf(address(this));
        if (lpNeeded > staked) lpNeeded = staked;
        if (lpNeeded == 0) return;
        _unwind(lpNeeded, vp);
    }

    function _withdrawAll() internal override {
        uint256 staked = convexRewards.balanceOf(address(this));
        if (staked == 0) return;
        _unwind(staked, curvePool.get_virtual_price());
    }

    /// @dev Unstake `lpAmount` from Convex and swap it out of Curve to USDC (into this
    ///      strategy; the base wrapper forwards it to the vault).
    function _unwind(uint256 lpAmount, uint256 vp) internal {
        convexRewards.withdrawAndUnwrap(lpAmount, false);

        uint256 expectedUsdc = Math.mulDiv(lpAmount, vp, 1e30);
        uint256 minOut = (expectedUsdc * (10_000 - maxSlippageBps)) / 10_000;

        curvePool.remove_liquidity_one_coin(lpAmount, int128(uint128(usdcIndex)), minOut);
    }

    // ──────────────────────────── value / harvest ───────────────────────────────

    function _positionValue() internal view override returns (uint256) {
        uint256 stakedLp = convexRewards.balanceOf(address(this));
        if (stakedLp == 0) return 0;
        return Math.mulDiv(stakedLp, curvePool.get_virtual_price(), 1e30);
    }

    function _pendingRewardsValue() internal view override returns (uint256) {
        return _valueInAsset(crv, convexRewards.earned(address(this)), crvDecimals);
    }

    function _harvestRewards() internal override {
        convexRewards.getReward();

        uint256 crvBal = IERC20(crv).balanceOf(address(this));
        if (crvBal != 0) {
            uint256 minOut = _valueInAsset(crv, crvBal, crvDecimals);
            IERC20(crv).forceApprove(address(swapper), crvBal);
            swapper.swap(crv, address(asset), crvBal, minOut, crvSwapRoute);
        }

        uint256 cvxBal = IERC20(cvx).balanceOf(address(this));
        if (cvxBal != 0) {
            uint256 minOut = _valueInAsset(cvx, cvxBal, cvxDecimals);
            IERC20(cvx).forceApprove(address(swapper), cvxBal);
            swapper.swap(cvx, address(asset), cvxBal, minOut, cvxSwapRoute);
        }
    }

    function setSwapRoutes(bytes calldata _crvRoute, bytes calldata _cvxRoute) external onlyVault {
        crvSwapRoute = _crvRoute;
        cvxSwapRoute = _cvxRoute;
        emit SwapRoutesSet();
    }
}
