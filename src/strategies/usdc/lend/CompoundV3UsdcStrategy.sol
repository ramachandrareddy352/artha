// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CompoundV3Strategy} from "../../common/CompoundV3Strategy.sol";

/**
 * @title  CompoundV3UsdcStrategy — supply USDC to the Compound III USDC market
 * @notice The USDC Comet is Compound III's flagship market and the one where COMP
 *         emissions are usually worth harvesting, which makes this the USDC vault's
 *         main emission-bearing lending leg (Aave's core USDC market pays none).
 *         All logic lives in `CompoundV3Strategy`.
 *
 *   yield : USDC borrower interest + COMP emissions, sold to USDC on every harvest.
 *   note  : Comet's supply position is an internal ledger, so this strategy is the
 *           registered supplier rather than the vault — see the base contract's
 *           custody note for why that is the right trade here.
 */
contract CompoundV3UsdcStrategy is CompoundV3Strategy {
    constructor(
        address _vault,
        address _usdc,
        address _oracle,
        address _swapper,
        address _comet,
        address _cometRewards,
        address _comp
    ) CompoundV3Strategy(_vault, _usdc, _oracle, _swapper, _comet, _cometRewards, _comp) {}
}
