// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  MorphoWbtcStrategy — supply WBTC into a curated MetaMorpho vault
 * @notice ERC-4626 over WBTC. Isolated Morpho Blue markets can pay a WBTC supplier
 *         meaningfully more than Aave's shared pool, because a curator can target the
 *         specific markets where BTC IS being borrowed instead of averaging across a
 *         reserve where it mostly is not.
 *
 *   risk : the curator's collateral and LLTV choices. Bad debt is isolated to the
 *          market it happens in and never socialized — vet the vault as governance.
 */
contract MorphoWbtcStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _wbtc, address _oracle, address _swapper, address _metaMorpho)
        ERC4626WrapperStrategy(_vault, _wbtc, _oracle, _swapper, _metaMorpho)
    {}
}
