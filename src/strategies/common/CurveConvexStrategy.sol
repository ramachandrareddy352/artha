// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {MultiRewardStrategy} from "./MultiRewardStrategy.sol";

interface ICurvePool {
    /// @dev 1e18, the pool's fee-accrual index. MONOTONIC — it cannot be moved by a
    ///      trade, which is exactly why every floor here is derived from it.
    function get_virtual_price() external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}

interface IConvexBooster {
    function deposit(uint256 pid, uint256 amount, bool stake) external returns (bool);
}

interface IConvexRewards {
    function balanceOf(address account) external view returns (uint256); // staked LP
    function earned(address account) external view returns (uint256); // pending CRV
    function getReward() external returns (bool); // CRV + CVX + any extras
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
}

/**
 * @title  CurveConvexStrategy — deposit into Curve, stake in Convex, compound the lot
 * @notice ONE strategy slot composing two protocols, generalized over pool size (2, 3
 *         or 4 coins) and over which coin the vault's base token is. Serves the
 *         3pool-style stable legs (USDC/USDT/DAI), the BTC legs (WBTC/tBTC) and the
 *         ETH legs (WETH/stETH) with the same code.
 *
 *   invest   : pool.add_liquidity([0,..,amount,..,0], minLp) -> stake the LP in Convex
 *   value    : stakedLp * get_virtual_price()  -> base units
 *   divest   : unstake -> remove_liquidity_one_coin(base) -> base to the vault
 *   harvest  : Convex getReward() -> sell CRV + CVX (+ any extras) -> base to the vault
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ⚠ PEGGED-ASSET POOLS ONLY
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Valuation treats one LP as `get_virtual_price()` worth of BASE token. That identity
 *  holds only while every coin in the pool is pegged to the same unit as the base coin
 *  — stables against stables, BTC wrappers against WBTC, ETH derivatives against WETH.
 *  Point this at a pool of uncorrelated assets (a volatile "crypto pool") and NAV will
 *  be wrong. Use `RotationStrategy` or a 4626 wrapper for those, never this.
 *
 *  Within a pegged pool, a coin that BREAKS its peg still hurts: single-sided exit
 *  through `remove_liquidity_one_coin` pays out of a pool that has become concentrated
 *  in the broken asset. `maxSlippageBps` bounds each exit, and the vault's withdrawal
 *  queue routes around a leg that cannot fill.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY EVERY FLOOR COMES FROM `get_virtual_price`
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `calc_token_amount` and `get_dy` are SPOT quotes — an attacker can skew the pool in
 *  the same block and make them agree with the skew. `get_virtual_price` is a
 *  fee-accrual index that a trade cannot move, so a sandwich on our add/remove is
 *  bounded by `maxSlippageBps` against a number the attacker does not control.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   CUSTODY AND PENDING REWARDS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  The Convex staked position is an internal, non-transferable ledger keyed to the
 *  staker, so `receiptToken()` is `address(0)` and this strategy holds the position.
 *  Pending rewards count CRV only (`earned`); CVX is minted pro-rata to CRV on claim
 *  by a schedule with no view — so it is under-reported until it lands, which is the
 *  safe direction and the rule stated in `MultiRewardStrategy`.
 */
contract CurveConvexStrategy is MultiRewardStrategy {
    using SafeERC20 for IERC20;

    ICurvePool public immutable curvePool;
    IERC20 public immutable curveLp;
    IConvexBooster public immutable booster;
    IConvexRewards public immutable convexRewards;
    uint256 public immutable convexPid;

    /// @notice Which coin of the pool is the vault's base token.
    uint256 public immutable baseIndex;
    /// @notice Number of coins in the pool (2, 3 or 4) — fixes the add_liquidity shape.
    uint256 public immutable nCoins;
    /// @dev `add_liquidity(uint256[nCoins],uint256)`, resolved once at construction.
    bytes4 private immutable addLiquiditySelector;
    /// @dev 10 ** (36 - assetDecimals): converts between 1e18 LP units and base units
    ///      across the virtual price. 1e30 for USDC, 1e28 for WBTC, 1e18 for DAI/WETH.
    uint256 private immutable lpScale;

    /// @notice CRV — the one reward whose accrual Convex exposes in a view.
    address public immutable crv;

    struct Config {
        address curvePool;
        address curveLp;
        address booster;
        address convexRewards;
        uint256 convexPid;
        uint256 baseIndex;
        uint256 nCoins;
        address crv;
        address[] rewardTokens; // [CRV, CVX, ...extras]
    }

    constructor(address _vault, address _asset, address _oracle, address _swapper, Config memory c)
        MultiRewardStrategy(_vault, _asset, _oracle, _swapper, c.rewardTokens)
    {
        require(
            c.curvePool != address(0) && c.curveLp != address(0) && c.booster != address(0)
                && c.convexRewards != address(0) && c.crv != address(0),
            "ZERO_ADDR"
        );
        require(c.nCoins >= 2 && c.nCoins <= 4, "BAD_NCOINS");
        require(c.baseIndex < c.nCoins, "BAD_INDEX");
        // The pool must really hold our base token at the index we were given — a
        // mis-set index would deposit into, and value against, the wrong coin.
        require(ICurvePool(c.curvePool).coins(c.baseIndex) == _asset, "COIN_MISMATCH");

        curvePool = ICurvePool(c.curvePool);
        curveLp = IERC20(c.curveLp);
        booster = IConvexBooster(c.booster);
        convexRewards = IConvexRewards(c.convexRewards);
        convexPid = c.convexPid;
        baseIndex = c.baseIndex;
        nCoins = c.nCoins;
        crv = c.crv;

        addLiquiditySelector = c.nCoins == 2
            ? bytes4(keccak256("add_liquidity(uint256[2],uint256)"))
            : (
                c.nCoins == 3
                    ? bytes4(keccak256("add_liquidity(uint256[3],uint256)"))
                    : bytes4(keccak256("add_liquidity(uint256[4],uint256)"))
            );

        lpScale = 10 ** (36 - IERC20MetadataLike(_asset).decimals());
    }

    /// @dev Internal-ledger venue (Convex staking): no receipt token for the vault.
    function receiptToken() public pure override returns (address) {
        return address(0);
    }

    // ─────────────────────────── invest / divest ────────────────────────────────

    function _invest(uint256 amount) internal override {
        uint256 vp = curvePool.get_virtual_price();
        uint256 minLp = _floor(_baseToLp(amount, vp));

        asset.forceApprove(address(curvePool), amount);
        uint256 lpBefore = curveLp.balanceOf(address(this));
        _addLiquidity(amount, minLp);
        uint256 minted = curveLp.balanceOf(address(this)) - lpBefore;
        require(minted >= minLp, "MIN_LP");

        curveLp.forceApprove(address(booster), minted);
        booster.deposit(convexPid, minted, true);
    }

    function _divest(uint256 amount) internal override {
        uint256 vp = curvePool.get_virtual_price();
        // Ask for slightly more LP than the face amount, so the exit still clears
        // `amount` after the pool's fee and imbalance charge.
        uint256 lpNeeded = Math.mulDiv(_baseToLp(amount, vp), 10_000, 10_000 - maxSlippageBps);
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

    /// @dev Unstake from Convex and exit the pool single-sided into base.
    function _unwind(uint256 lpAmount, uint256 vp) internal {
        convexRewards.withdrawAndUnwrap(lpAmount, false);
        uint256 minOut = _floor(_lpToBase(lpAmount, vp));
        // int128 index: the StableSwap shape. NG/crypto pools taking uint256 here are
        // out of scope (see the pegged-pool note in the header).
        (bool ok,) = address(curvePool).call(
            abi.encodeWithSignature(
                "remove_liquidity_one_coin(uint256,int128,uint256)", lpAmount, int128(uint128(baseIndex)), minOut
            )
        );
        require(ok, "REMOVE_LIQUIDITY_FAILED");
    }

    /// @dev Curve's `add_liquidity` takes a FIXED-size array whose length is part of the
    ///      signature, so the calldata is built by hand: selector, `nCoins` words with
    ///      our amount at `baseIndex`, then the minimum.
    function _addLiquidity(uint256 amount, uint256 minLp) internal {
        bytes memory data = abi.encodePacked(addLiquiditySelector);
        for (uint256 i; i < nCoins; ++i) {
            data = abi.encodePacked(data, i == baseIndex ? amount : uint256(0));
        }
        data = abi.encodePacked(data, minLp);

        (bool ok,) = address(curvePool).call(data);
        require(ok, "ADD_LIQUIDITY_FAILED");
    }

    // ──────────────────────────── value / rewards ───────────────────────────────

    function _positionValue() internal view override returns (uint256) {
        uint256 stakedLp = convexRewards.balanceOf(address(this));
        if (stakedLp == 0) return 0;
        return _lpToBase(stakedLp, curvePool.get_virtual_price());
    }

    function _lpToBase(uint256 lpAmount, uint256 vp) internal view returns (uint256) {
        return Math.mulDiv(lpAmount, vp, lpScale);
    }

    function _baseToLp(uint256 baseAmount, uint256 vp) internal view returns (uint256) {
        return Math.mulDiv(baseAmount, lpScale, vp);
    }

    function _claimRewards() internal override {
        convexRewards.getReward(); // CRV + CVX + any extra reward contracts
    }

    function _pendingRewardAmount(address token) internal view override returns (uint256) {
        return token == crv ? convexRewards.earned(address(this)) : 0;
    }

    /// @notice LP currently staked in Convex for this vault.
    function stakedLpBalance() external view returns (uint256) {
        return convexRewards.balanceOf(address(this));
    }
}

interface IERC20MetadataLike {
    function decimals() external view returns (uint8);
}
