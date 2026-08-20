// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CompoundV3Strategy} from "../../common/CompoundV3Strategy.sol";

/**
 * @title  CompoundV3UsdtStrategy — supply USDT to the Compound III USDT market
 * @notice Compound III runs a dedicated USDT Comet (a separate market from the USDC
 *         one, with its own collateral set and its own COMP emission schedule).
 *
 *   yield : USDT borrower interest + COMP, sold to USDT on every harvest.
 */
contract CompoundV3UsdtStrategy is CompoundV3Strategy {
    constructor(
        address _vault,
        address _usdt,
        address _oracle,
        address _swapper,
        address _comet,
        address _cometRewards,
        address _comp
    ) CompoundV3Strategy(_vault, _usdt, _oracle, _swapper, _comet, _cometRewards, _comp) {}
}
