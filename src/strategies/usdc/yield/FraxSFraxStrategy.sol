// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CrossAssetERC4626Strategy} from "../../common/CrossAssetERC4626Strategy.sol";

/**
 * @title  FraxSFraxStrategy  —  hold sFRAX from a USDC vault
 * @notice USDC -> FRAX -> sFRAX (Frax's savings vault). sFRAX is an ERC-4626 whose
 *         asset is FRAX, so this is the cross-asset wrapper with a USDC<->FRAX leg.
 *
 *   yield : the Frax savings rate (protocol revenue / RWA-linked), folded into sFRAX's
 *           share price. No borrower, no emission token.
 *   risk  : FRAX peg + the swap round-trip. Low-to-medium.
 */
contract FraxSFraxStrategy is CrossAssetERC4626Strategy {
    constructor(
        address _vault,
        address _usdc,
        address _oracle,
        address _swapper,
        address _sFrax,
        address _frax
    ) CrossAssetERC4626Strategy(_vault, _usdc, _oracle, _swapper, _sFrax, _frax) {}
}
