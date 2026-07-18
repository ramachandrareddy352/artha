// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CrossAssetERC4626Strategy} from "../../common/CrossAssetERC4626Strategy.sol";

/**
 * @title  EthenaSUsdeStrategy  —  hold sUSDe from a USDC vault
 * @notice USDC -> USDe -> sUSDe (Ethena's staked synthetic dollar). sUSDe is an
 *         ERC-4626 whose asset is USDe, so this is the cross-asset wrapper with a
 *         USDC<->USDe swap leg.
 *
 *   yield : Ethena's delta-neutral perp-funding + staking yield, captured by HOLDING
 *           sUSDe — the README's "wrap it, never build the hedge". Historically high
 *           but funding-rate dependent (can compress or briefly go negative).
 *   risk  : USDe peg + the USDC<->USDe swap round-trip (see the CrossAsset base). Best
 *           in a higher-risk tier than plain lending; size accordingly.
 */
contract EthenaSUsdeStrategy is CrossAssetERC4626Strategy {
    constructor(
        address _vault,
        address _usdc,
        address _oracle,
        address _swapper,
        address _sUsde,
        address _usde
    ) CrossAssetERC4626Strategy(_vault, _usdc, _oracle, _swapper, _sUsde, _usde) {}
}
