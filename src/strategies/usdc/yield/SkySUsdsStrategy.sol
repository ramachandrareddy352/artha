// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CrossAssetERC4626Strategy} from "../../common/CrossAssetERC4626Strategy.sol";

/**
 * @title  SkySUsdsStrategy  —  hold sUSDS from a USDC vault
 * @notice USDC -> USDS -> sUSDS (the Sky Savings Rate on Sky's USDS stable). sUSDS is
 *         an ERC-4626 whose asset is USDS, so this is the cross-asset wrapper with a
 *         USDC<->USDS leg. (For a DAI vault, prefer SkySDaiStrategy — sDAI's asset is
 *         DAI directly, no swap leg needed.)
 *
 *   yield : the Sky Savings Rate (RWA T-bills + protocol fees), governance-set. No
 *           borrower, no liquidation, no emission token.
 *   risk  : USDS peg + the swap round-trip. Low.
 */
contract SkySUsdsStrategy is CrossAssetERC4626Strategy {
    constructor(
        address _vault,
        address _usdc,
        address _oracle,
        address _swapper,
        address _sUsds,
        address _usds
    ) CrossAssetERC4626Strategy(_vault, _usdc, _oracle, _swapper, _sUsds, _usds) {}
}
