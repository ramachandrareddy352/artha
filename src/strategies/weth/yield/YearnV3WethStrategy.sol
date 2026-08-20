// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  YearnV3WethStrategy — nest into a Yearn V3 WETH vault
 * @notice ERC-4626 over WETH; our vault holds Yearn's and inherits its blended ETH
 *         strategy set through share appreciation. Harvest is a no-op.
 *
 *   ⚠ LOOP RULE : never point this at a Yearn vault that deposits back into an Artha
 *     vault, directly or transitively. Keep the dependency graph acyclic.
 */
contract YearnV3WethStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _weth, address _oracle, address _swapper, address _yearnVault)
        ERC4626WrapperStrategy(_vault, _weth, _oracle, _swapper, _yearnVault)
    {}
}
