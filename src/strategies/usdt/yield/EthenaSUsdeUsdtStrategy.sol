// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CrossAssetERC4626Strategy} from "../../common/CrossAssetERC4626Strategy.sol";

/**
 * @title  EthenaSUsdeUsdtStrategy — hold sUSDe from a USDT vault
 * @notice USDT -> USDe -> sUSDe. sUSDe is an ERC-4626 whose asset is USDe, so this is
 *         the cross-asset wrapper with a USDT<->USDe swap leg on entry and exit.
 *
 *   yield : Ethena's delta-neutral perp-funding plus staking yield, captured simply by
 *           HOLDING sUSDe — we never build or manage the hedge ourselves. Historically
 *           high, but funding-dependent: it compresses in flat markets and can briefly
 *           go negative.
 *   risk  : USDe's peg, Ethena's custody and exchange counterparties, plus the swap
 *           round-trip on both legs. A higher-risk tier than lending — size it there.
 */
contract EthenaSUsdeUsdtStrategy is CrossAssetERC4626Strategy {
    constructor(address _vault, address _usdt, address _oracle, address _swapper, address _sUsde, address _usde)
        CrossAssetERC4626Strategy(_vault, _usdt, _oracle, _swapper, _sUsde, _usde)
    {}
}
