// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  MorphoDaiStrategy — supply DAI into a curated MetaMorpho vault
 * @notice ERC-4626 over DAI; the curator allocates across isolated Morpho Blue markets.
 *         Risk is the curator's market selection, not Morpho Blue itself — bad debt is
 *         isolated per market and never socialized. Vet the vault as a governance act.
 */
contract MorphoDaiStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _dai, address _oracle, address _swapper, address _metaMorpho)
        ERC4626WrapperStrategy(_vault, _dai, _oracle, _swapper, _metaMorpho)
    {}
}
