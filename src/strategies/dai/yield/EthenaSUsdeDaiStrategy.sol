// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CrossAssetERC4626Strategy} from "../../common/CrossAssetERC4626Strategy.sol";

/**
 * @title  EthenaSUsdeDaiStrategy — hold sUSDe from a DAI vault
 * @notice DAI -> USDe -> sUSDe, through the cross-asset wrapper's swap leg.
 *
 *   yield : Ethena's delta-neutral perp-funding plus staking yield, captured by holding
 *           sUSDe. Funding-dependent — high in bull markets, compressing to little in
 *           flat ones, briefly negative on occasion.
 *   risk  : USDe's peg and Ethena's exchange/custody counterparties, plus the swap
 *           round trip. Note this is the DAI vault's HIGH-risk leg and `SkySDaiStrategy`
 *           is its low-risk one — do not let their weights drift toward each other.
 */
contract EthenaSUsdeDaiStrategy is CrossAssetERC4626Strategy {
    constructor(address _vault, address _dai, address _oracle, address _swapper, address _sUsde, address _usde)
        CrossAssetERC4626Strategy(_vault, _dai, _oracle, _swapper, _sUsde, _usde)
    {}
}
