// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseStrategy} from "../BaseStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IStETH {
    function submit(address referral) external payable returns (uint256); // stakes ETH, mints stETH
}

interface IWstETH {
    function wrap(uint256 stETHAmount) external returns (uint256 wstETHAmount);
    function unwrap(uint256 wstETHAmount) external returns (uint256 stETHAmount);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface ICurveStEthPool {
    // Lido stETH/ETH pool: coin 0 = ETH (native), coin 1 = stETH
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
}

/**
 * @title  LidoWstETHStrategy  (liquid staking)
 * @notice Turns the pool's ETH leg into a YIELD-BEARING ETH position: on deposit it
 *         stakes WETH through Lido and holds wstETH, so the allocation earns ETH
 *         staking yield (~3%) ON TOP OF price exposure. `underlying` is WETH, so NAV
 *         values it with the WETH oracle; the staking yield shows up as the
 *         wstETH->stETH exchange rate (getStETHByWstETH) rising over time.
 *
 *  DEPOSIT:  WETH -> ETH -> Lido.submit -> stETH -> wrap -> wstETH (held).
 *  WITHDRAW: Lido native withdrawals are QUEUED (not instant), so for instant
 *            liquidity we exit via the Curve stETH/ETH pool: unwrap -> stETH ->
 *            Curve exchange -> ETH -> wrap -> WETH. A slippage guard bounds the swap.
 *
 *  NOTE: the value floor on exit is `maxSlippageBps` here; keep it tight (stETH/ETH
 *        trades ~1:1). For large exits prefer in-kind withdrawal (the Diamond takes
 *        wstETH directly) to avoid swap impact.
 */
contract LidoWstETHStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IWETH public immutable weth;
    IStETH public immutable stETH;
    IWstETH public immutable wstETH;
    ICurveStEthPool public immutable curve;
    uint16 public maxSlippageBps; // exit swap tolerance (e.g. 100 = 1%)

    event SlippageSet(uint16 bps);

    constructor(
        address _vault,
        address _weth, // = underlying
        address _oracle,
        address _usdc,
        address _stETH,
        address _wstETH,
        address _curveStEthPool,
        uint16 _maxSlippageBps
    ) BaseStrategy(_vault, _weth, _oracle, _usdc) {
        require(_stETH != address(0) && _wstETH != address(0) && _curveStEthPool != address(0), "ZERO_ADDR");
        require(_maxSlippageBps <= 1000, "SLIPPAGE_TOO_HIGH");
        weth = IWETH(_weth);
        stETH = IStETH(_stETH);
        wstETH = IWstETH(_wstETH);
        curve = ICurveStEthPool(_curveStEthPool);
        maxSlippageBps = _maxSlippageBps;
    }

    receive() external payable {} // accept ETH from WETH.withdraw and Curve

    /// @notice Vault admin can retune the exit slippage tolerance.
    function setMaxSlippageBps(uint16 bps) external onlyVault {
        require(bps <= 1000, "SLIPPAGE_TOO_HIGH");
        maxSlippageBps = bps;
        emit SlippageSet(bps);
    }

    function _supply(uint256 amount) internal override {
        weth.withdraw(amount);                                   // WETH -> ETH
        uint256 stAmount = stETH.submit{value: amount}(address(0)); // stake -> stETH
        IERC20(address(stETH)).forceApprove(address(wstETH), stAmount);
        wstETH.wrap(stAmount);                                   // stETH -> wstETH (held)
    }

    function _redeem(uint256 amount) internal override returns (uint256) {
        // `amount` = desired WETH (ETH-equivalent) out
        uint256 wstToUnwrap = wstETH.getWstETHByStETH(amount);
        uint256 wstBal = wstETH.balanceOf(address(this));
        if (wstToUnwrap > wstBal) wstToUnwrap = wstBal;

        uint256 stAmount = wstETH.unwrap(wstToUnwrap);           // wstETH -> stETH
        IERC20(address(stETH)).forceApprove(address(curve), stAmount);
        uint256 minOut = (stAmount * (10000 - maxSlippageBps)) / 10000;
        uint256 ethOut = curve.exchange(1, 0, stAmount, minOut); // stETH -> ETH (native)

        weth.deposit{value: ethOut}();                           // ETH -> WETH
        return ethOut;
    }

    function _totalUnderlying() internal view override returns (uint256) {
        // wstETH held, valued in stETH(~=ETH~=WETH) units; the rate rising = the yield
        return wstETH.getStETHByWstETH(wstETH.balanceOf(address(this)));
    }
}
