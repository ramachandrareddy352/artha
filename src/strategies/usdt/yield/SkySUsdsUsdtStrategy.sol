// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CrossAssetERC4626Strategy} from "../../common/CrossAssetERC4626Strategy.sol";

/**
 * @title  SkySUsdsUsdtStrategy — hold sUSDS from a USDT vault
 * @notice USDT -> USDS -> sUSDS (the Sky Savings Rate). sUSDS is an ERC-4626 over USDS,
 *         so this is the cross-asset wrapper with a USDT<->USDS leg.
 *
 *   yield : the Sky Savings Rate — RWA T-bills plus protocol fees, governance-set. No
 *           borrower, no liquidation, no emission token, so it holds up when lending
 *           rates compress.
 *   risk  : USDS peg plus the swap round-trip. Low, and largely uncorrelated with the
 *           lending legs — which is the reason to hold it alongside them.
 */
contract SkySUsdsUsdtStrategy is CrossAssetERC4626Strategy {
    constructor(address _vault, address _usdt, address _oracle, address _swapper, address _sUsds, address _usds)
        CrossAssetERC4626Strategy(_vault, _usdt, _oracle, _swapper, _sUsds, _usds)
    {}
}
