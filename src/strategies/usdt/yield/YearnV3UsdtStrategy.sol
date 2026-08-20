// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  YearnV3UsdtStrategy — nest into a Yearn V3 USDT vault
 * @notice Yearn V3 vaults are ERC-4626 over USDT, so this is the universal wrapper:
 *         our vault holds Yearn's, inheriting its whole blended strategy set through
 *         share appreciation. Harvest is a no-op — Yearn compounds internally.
 *
 *   ⚠ LOOP RULE : never point this at a Yearn vault that, directly or transitively,
 *     deposits back into an Artha vault. A cycle inflates both TVLs fictitiously and
 *     can death-spiral on the way out. Keep the dependency graph acyclic.
 */
contract YearnV3UsdtStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _usdt, address _oracle, address _swapper, address _yearnVault)
        ERC4626WrapperStrategy(_vault, _usdt, _oracle, _swapper, _yearnVault)
    {}
}
