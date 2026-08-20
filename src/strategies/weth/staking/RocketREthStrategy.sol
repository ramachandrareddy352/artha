// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LiquidStakingStrategy} from "../../common/LiquidStakingStrategy.sol";

/// @notice rETH's native rate readers. rETH is non-rebasing: one rETH is worth strictly
///         more ETH over time, and that is the entire yield.
interface IREth {
    function getEthValue(uint256 rethAmount) external view returns (uint256);
    function getRethValue(uint256 ethAmount) external view returns (uint256);
}

/**
 * @title  RocketREthStrategy — Rocket Pool staking, held as rETH
 * @notice The decentralization diversifier next to `LidoWstEthStrategy`: same shape,
 *         same accounting, a completely different validator set and operator model.
 *         Holding both halves the exposure to any single staking protocol's failure
 *         at almost no cost in yield.
 *
 *   invest/divest : WETH <-> rETH through the swapper. Rocket's own burn path depends
 *                   on free capacity in the deposit pool and can be unavailable for
 *                   long stretches, so it is deliberately not used. No native ETH is
 *                   touched anywhere.
 *   value         : getEthValue(balance), or the market price when that is lower.
 *   harvest       : NO-OP — the rate climbing is the yield.
 *
 *   risk : rETH trades at a discount more often than wstETH does, because its secondary
 *          liquidity is thinner. The lower-of-two valuation rule already prices that
 *          in; keep the weight below the wstETH leg's.
 */
contract RocketREthStrategy is LiquidStakingStrategy {
    constructor(address _vault, address _weth, address _oracle, address _swapper, address _rEth)
        LiquidStakingStrategy(_vault, _weth, _oracle, _swapper, _rEth)
    {}

    function _nativeToBase(uint256 rethAmount) internal view override returns (uint256) {
        return IREth(address(held)).getEthValue(rethAmount);
    }

    function _nativeToHeld(uint256 wethAmount) internal view override returns (uint256) {
        return IREth(address(held)).getRethValue(wethAmount);
    }
}
