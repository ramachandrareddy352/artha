// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3UsdcStrategy} from "../../usdc/lend/AaveV3UsdcStrategy.sol";

/**
 * @title  AaveV3WbtcStrategy  —  WBTC deployment of the Aave V3 lending adapter
 * @notice Supplies WBTC to Aave V3 for borrower interest via rebasing aWBTC. Same
 *         token-agnostic logic as AaveV3UsdcStrategy, on the WBTC market.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY WBTC HAS ESSENTIALLY ONE STRATEGY
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  On-chain BTC yield is genuinely thin. WBTC is used almost entirely as COLLATERAL
 *  (to borrow against), not as a base lending asset, so borrow demand for WBTC is low
 *  and supply APR is small (~0.02-1%). Compound V3 has no WBTC base market. Curve/
 *  Convex BTC pools (e.g. tBTC/WBTC) exist but carry cross-BTC-asset peg risk.
 *
 *  So for WBTC, Aave supply is the clean, liquid, low-risk option and realistically
 *  the only "do first". Higher WBTC yield (Lombard LBTC, Solv, Babylon restaking) is
 *  newer, more complex, and NOT a simple synchronous strategy — treat those as
 *  bespoke, later, higher-tier additions rather than naive adapters.
 */
contract AaveV3WbtcStrategy is AaveV3UsdcStrategy {
    constructor(
        address _vault,
        address _wbtc,
        address _oracle,
        address _swapper,
        address _pool,
        address _aWbtc
    ) AaveV3UsdcStrategy(_vault, _wbtc, _oracle, _swapper, _pool, _aWbtc) {}
}
