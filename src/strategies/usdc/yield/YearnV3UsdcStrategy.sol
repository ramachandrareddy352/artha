// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  YearnV3UsdcStrategy  —  nest into a Yearn V3 USDC vault
 * @notice Yearn V3 vaults ARE ERC-4626 (asset() == USDC), so the universal wrapper
 *         covers them. This is the "yield on yield" / vault-of-vaults leg: our vault
 *         holds Yearn's vault, inheriting Yearn's whole blended strategy set via share
 *         appreciation.
 *
 *   harvest : NO-OP — Yearn compounds internally; value is Yearn's share price rising.
 *   ⚠ LOOP RULE : never point this at a Yearn vault that (directly or transitively)
 *     deposits back into an Artha vault. Circular dependency inflates TVL fictitiously
 *     and can death-spiral. Keep the dependency graph acyclic.
 *
 *   Deploy the same wrapper per token (WETH/DAI/...) pointed at the matching Yearn V3
 *   vault — no separate code needed, just a different constructor argument.
 */
contract YearnV3UsdcStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _usdc, address _oracle, address _swapper, address _yearnVault)
        ERC4626WrapperStrategy(_vault, _usdc, _oracle, _swapper, _yearnVault)
    {}
}
