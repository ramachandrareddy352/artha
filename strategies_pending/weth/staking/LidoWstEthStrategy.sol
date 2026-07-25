// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseStrategy} from "../../BaseStrategy.sol";

/// @notice wstETH's native exchange-rate readers (stETH per wstETH and inverse).
interface IWstETH {
    function getStETHByWstETH(uint256 wstAmount) external view returns (uint256 stEthAmount);
    function getWstETHByStETH(uint256 stEthAmount) external view returns (uint256 wstAmount);
}

/**
 * @title  LidoWstEthStrategy  —  WETH's signature Shape-2 (exchange-rate) strategy
 * @notice Holds Lido wstETH and earns Ethereum staking rewards, which accrue as
 *         wstETH's stETH-exchange-rate rises. Entry and exit go through the SWAPPER
 *         (WETH <-> wstETH on a deep venue like Curve/Uniswap), deliberately avoiding
 *         Lido's native withdrawal QUEUE — swap liquidity for wstETH is deep and
 *         instant, the queue is not.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW WE INVEST
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   invest   : swapper.swap(WETH -> wstETH), minOut floored at the native rate.
 *              (No Lido submit/queue — we buy wstETH on the market.)
 *   value    : wstETH.getStETHByWstETH(balance). wstETH's stETH value only RISES as
 *              validator rewards accrue — that IS the yield. Reported in WETH terms,
 *              treating stETH ~ ETH ~ WETH (see the depeg note).
 *   withdraw : swapper.swap(wstETH -> WETH), minOut floored at the native rate.
 *   harvest  : NO-OP. There is no reward token — staking yield is the exchange rate
 *              climbing, already in `_positionValue`. This is a Shape-2 strategy.
 *   settle   : none; the rate accrues continuously and the vault reads it live.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE RISK TO KNOW
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  We value wstETH via its NATIVE stETH rate and assume stETH ~ ETH. In a stETH/ETH
 *  DEPEG (as in June 2022, ~6-8% discount during the Celsius/3AC stress), the market
 *  exit price via the swapper can be BELOW this reported value for a while, so an exit
 *  during stress realizes less than `_positionValue` implies. maxSlippageBps bounds
 *  each swap, but not a sustained depeg. Also: Lido validator slashing is a (small)
 *  tail on the underlying stake. Size accordingly; this belongs in the WETH vault, and
 *  ideally a higher-risk tier than plain Aave-WETH lending.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   YIELD
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  ~3-4%/yr in ETH terms, from consensus + execution-layer staking rewards, with no
 *  emission token to babysit and no lock. Compounds automatically — the rate just
 *  keeps rising — so there is nothing to harvest.
 */
contract LidoWstEthStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable wstETH;

    /// @notice Pre-set swap routes. buyRoute: WETH->wstETH. sellRoute: wstETH->WETH.
    bytes public buyRoute;
    bytes public sellRoute;

    event RoutesSet();

    constructor(address _vault, address _weth, address _oracle, address _swapper, address _wstETH)
        BaseStrategy(_vault, _weth, _oracle, _swapper)
    {
        require(_wstETH != address(0), "ZERO_ADDR");
        wstETH = IERC20(_wstETH);
    }

    function _invest(uint256 amount) internal override {
        // expected wstETH out for `amount` WETH (treating WETH as stETH 1:1), floored.
        uint256 expected = IWstETH(address(wstETH)).getWstETHByStETH(amount);
        uint256 minOut = (expected * (10_000 - maxSlippageBps)) / 10_000;

        asset.forceApprove(address(swapper), amount);
        swapper.swap(address(asset), address(wstETH), amount, minOut, buyRoute);
    }

    function _divest(uint256 amount) internal override returns (uint256 freed) {
        // wstETH needed to realize `amount` WETH (WETH ~ stETH), capped by holdings.
        uint256 wstNeeded = IWstETH(address(wstETH)).getWstETHByStETH(amount);
        uint256 held = wstETH.balanceOf(address(this));
        if (wstNeeded > held) wstNeeded = held;
        if (wstNeeded == 0) return 0;

        return _sellWst(wstNeeded);
    }

    function _withdrawAll() internal override returns (uint256 freed) {
        uint256 held = wstETH.balanceOf(address(this));
        if (held == 0) return 0;
        return _sellWst(held);
    }

    function _sellWst(uint256 wstAmount) internal returns (uint256 freed) {
        uint256 expectedWeth = IWstETH(address(wstETH)).getStETHByWstETH(wstAmount);
        uint256 minOut = (expectedWeth * (10_000 - maxSlippageBps)) / 10_000;

        wstETH.forceApprove(address(swapper), wstAmount);
        uint256 before = asset.balanceOf(address(this));
        swapper.swap(address(wstETH), address(asset), wstAmount, minOut, sellRoute);
        freed = asset.balanceOf(address(this)) - before;
    }

    function _positionValue() internal view override returns (uint256) {
        return IWstETH(address(wstETH)).getStETHByWstETH(wstETH.balanceOf(address(this)));
    }

    function setRoutes(bytes calldata _buyRoute, bytes calldata _sellRoute) external onlyVault {
        buyRoute = _buyRoute;
        sellRoute = _sellRoute;
        emit RoutesSet();
    }
}
