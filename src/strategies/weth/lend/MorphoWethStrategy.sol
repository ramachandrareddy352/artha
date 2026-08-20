// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  MorphoWethStrategy — supply WETH into a curated MetaMorpho vault
 * @notice ERC-4626 over WETH; the curator allocates across isolated Morpho Blue
 *         markets, most of them LST-collateralized ETH lending. Risk is the curator's
 *         choice of collateral and LLTV — bad debt stays inside the market it happened
 *         in. Vet the specific vault as a governance decision.
 */
contract MorphoWethStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _weth, address _oracle, address _swapper, address _metaMorpho)
        ERC4626WrapperStrategy(_vault, _weth, _oracle, _swapper, _metaMorpho)
    {}
}
