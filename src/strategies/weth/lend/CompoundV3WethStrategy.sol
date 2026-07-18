// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CompoundV3UsdcStrategy} from "../../usdc/lend/CompoundV3UsdcStrategy.sol";

/**
 * @title  CompoundV3WethStrategy  —  WETH deployment of the Compound V3 adapter
 * @notice Supplies WETH to Compound V3's WETH (Comet) market for supply interest,
 *         and harvests + compounds COMP emissions. Logic is token-agnostic and lives
 *         in CompoundV3UsdcStrategy; deploy this pointed at the WETH Comet.
 *
 *   invest   : comet.supply(WETH, amount)
 *   value    : comet.balanceOf(this) (present value, WETH) + haircut COMP (realized at harvest)
 *   withdraw : comet.withdraw(WETH, amount)
 *   harvest  : claim COMP -> swap COMP->WETH -> resupply
 *   yield    : ETH borrower interest + COMP emissions (sold every harvest, never held).
 */
contract CompoundV3WethStrategy is CompoundV3UsdcStrategy {
    constructor(
        address _vault,
        address _weth,
        address _oracle,
        address _swapper,
        address _comet,
        address _cometRewards,
        address _comp
    ) CompoundV3UsdcStrategy(_vault, _weth, _oracle, _swapper, _comet, _cometRewards, _comp) {}
}
