// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LiquidStakingStrategy} from "../../common/LiquidStakingStrategy.sol";

/// @notice wstETH's native exchange-rate readers. `getStETHByWstETH` only ever rises —
///         it IS the accrued staking reward.
interface IWstETH {
    function getStETHByWstETH(uint256 wstAmount) external view returns (uint256 stEthAmount);
    function getWstETHByStETH(uint256 stEthAmount) external view returns (uint256 wstAmount);
}

/**
 * @title  LidoWstEthStrategy — the WETH vault's signature yield leg
 * @notice Holds Lido wstETH and earns Ethereum staking rewards. There is no reward
 *         token and nothing to harvest: the yield IS wstETH's stETH rate climbing,
 *         which `positionValue()` reads live, so it compounds by itself.
 *
 *   invest   : swapper.swap(WETH -> wstETH); wstETH custodied by the VAULT.
 *   value    : getStETHByWstETH(balance), treating stETH ~ ETH ~ WETH — but taking the
 *              market price instead whenever it is LOWER (see `LiquidStakingStrategy`).
 *   divest   : pull wstETH from the vault, swapper.swap(wstETH -> WETH).
 *   harvest  : NO-OP.
 *
 *   Entry and exit go through a deep WETH/wstETH pool rather than Lido's withdrawal
 *   QUEUE, which takes days to settle. No native ETH is touched at any point.
 *
 *   yield : ~3-4%/yr in ETH terms from consensus and execution-layer rewards. No lock,
 *           no emission to sell, no keeper action needed for it to accrue.
 *   risk  : a stETH/ETH dislocation (6-8% for weeks in June 2022) means an exit during
 *           stress realizes less than the native rate implies — which is exactly why
 *           valuation takes the lower of the two numbers. Validator slashing is a small
 *           tail on top. Higher tier than `AaveV3WethStrategy`; size accordingly.
 */
contract LidoWstEthStrategy is LiquidStakingStrategy {
    constructor(address _vault, address _weth, address _oracle, address _swapper, address _wstETH)
        LiquidStakingStrategy(_vault, _weth, _oracle, _swapper, _wstETH)
    {}

    /// @dev wstETH -> stETH, taken as 1:1 with WETH. Both are 18-decimal.
    function _nativeToBase(uint256 wstAmount) internal view override returns (uint256) {
        return IWstETH(address(held)).getStETHByWstETH(wstAmount);
    }

    function _nativeToHeld(uint256 wethAmount) internal view override returns (uint256) {
        return IWstETH(address(held)).getWstETHByStETH(wethAmount);
    }
}
