// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CompoundV3Strategy} from "../../common/CompoundV3Strategy.sol";

/**
 * @title  CompoundV3WethStrategy — supply WETH to the Compound III WETH market
 * @notice The WETH Comet is where LST holders borrow ETH to loop staking yield, so its
 *         utilization — and therefore its supply rate — tends to run high and hold up
 *         better than Aave's WETH reserve. Plus COMP on top.
 *
 *   yield : WETH borrower interest + COMP, sold to WETH on every harvest.
 *   note  : the market's base token is WETH itself; no native ETH is involved on any
 *           path in or out.
 */
contract CompoundV3WethStrategy is CompoundV3Strategy {
    constructor(
        address _vault,
        address _weth,
        address _oracle,
        address _swapper,
        address _comet,
        address _cometRewards,
        address _comp
    ) CompoundV3Strategy(_vault, _weth, _oracle, _swapper, _comet, _cometRewards, _comp) {}
}
