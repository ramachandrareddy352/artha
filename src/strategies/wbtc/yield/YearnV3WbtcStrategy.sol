// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  YearnV3WbtcStrategy — nest into a Yearn V3 WBTC vault
 * @notice ERC-4626 over WBTC; our vault holds Yearn's and inherits whatever BTC yield
 *         Yearn's curators have managed to find, through share appreciation. Harvest
 *         is a no-op.
 *
 *   ⚠ LOOP RULE : never point this at a Yearn vault that deposits back into an Artha
 *     vault, directly or transitively. Keep the dependency graph acyclic.
 */
contract YearnV3WbtcStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _wbtc, address _oracle, address _swapper, address _yearnVault)
        ERC4626WrapperStrategy(_vault, _wbtc, _oracle, _swapper, _yearnVault)
    {}
}
