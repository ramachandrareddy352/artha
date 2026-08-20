// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  MorphoUsdtStrategy — supply USDT into a curated MetaMorpho vault
 * @notice A MetaMorpho vault IS an ERC-4626 over USDT, so the universal wrapper covers
 *         it; the curator spreads the deposit across isolated Morpho Blue markets.
 *
 *   risk : lives in the CURATOR's market choices (which collateral, what LLTV), not in
 *          Morpho Blue. Bad debt is isolated per market and never socialized — so vet
 *          the specific vault, and treat picking it as a governance decision.
 *   note : MORPHO incentives are distributed off-chain through a merkle URD and are
 *          NOT claimable from here. Out of scope, as on the USDC deployment.
 */
contract MorphoUsdtStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _usdt, address _oracle, address _swapper, address _metaMorpho)
        ERC4626WrapperStrategy(_vault, _usdt, _oracle, _swapper, _metaMorpho)
    {}
}
