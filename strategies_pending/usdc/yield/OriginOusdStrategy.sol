// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CrossAssetERC4626Strategy} from "../../common/CrossAssetERC4626Strategy.sol";

/**
 * @title  OriginOusdStrategy  —  hold wOUSD from a USDC vault
 * @notice USDC -> OUSD -> wOUSD (Origin Dollar's wrapped, non-rebasing form). wOUSD is
 *         an ERC-4626 whose asset is OUSD, so this is the cross-asset wrapper with a
 *         USDC<->OUSD leg. We use the WRAPPED token deliberately: OUSD itself rebases
 *         (balance grows), which the 4626 accounting does not expect; wOUSD converts
 *         that to clean share-price appreciation.
 *
 *   yield : OUSD auto-allocates across Aave/Compound/Curve/Convex under the hood, so
 *           this is effectively a diversified stablecoin aggregator wrapped in one
 *           token, folded into wOUSD's share price.
 *   risk  : OUSD peg + the swap round-trip + the underlying strategy mix. Medium.
 */
contract OriginOusdStrategy is CrossAssetERC4626Strategy {
    constructor(
        address _vault,
        address _usdc,
        address _oracle,
        address _swapper,
        address _wOusd,
        address _ousd
    ) CrossAssetERC4626Strategy(_vault, _usdc, _oracle, _swapper, _wOusd, _ousd) {}
}
