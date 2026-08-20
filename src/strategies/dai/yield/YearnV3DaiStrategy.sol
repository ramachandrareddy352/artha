// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  YearnV3DaiStrategy — nest into a Yearn V3 DAI vault
 * @notice ERC-4626 over DAI; our vault holds Yearn's and inherits its blended strategy
 *         set through share appreciation. Harvest is a no-op (Yearn compounds).
 *
 *   ⚠ LOOP RULE : never point this at a Yearn vault that deposits back into an Artha
 *     vault, directly or transitively. Keep the dependency graph acyclic.
 */
contract YearnV3DaiStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _dai, address _oracle, address _swapper, address _yearnVault)
        ERC4626WrapperStrategy(_vault, _dai, _oracle, _swapper, _yearnVault)
    {}
}
