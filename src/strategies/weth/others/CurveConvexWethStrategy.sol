// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CurveConvexStrategy} from "../../common/CurveConvexStrategy.sol";

/**
 * @title  CurveConvexWethStrategy — WETH into an ETH-pegged Curve pool, staked in Convex
 * @notice For the WETH-denominated pegged pools — WETH/stETH, WETH/frxETH and similar
 *         2-coin pools where every coin is worth ~1 ETH. Adds WETH single-sided, stakes
 *         the LP in Convex for boosted CRV + CVX, sells both back into WETH.
 *
 *   ⚠ USE A WETH POOL, NOT AN ETH POOL. Curve's older ETH pools hold NATIVE ether at
 *     one index and expect a payable `add_liquidity` — this strategy has no payable
 *     surface and never handles native ETH, by design. Point it only at a pool whose
 *     `coins(baseIndex)` is the WETH contract; the constructor enforces exactly that
 *     and will revert otherwise.
 *
 *   yield : trading fees + boosted CRV + CVX.
 *   risk  : an LST leg of the pool dislocating from ETH hits the single-sided exit —
 *           the same June-2022 scenario described in `LidoWstEthStrategy`, but realized
 *           through the pool's imbalance instead of the token's market price.
 */
contract CurveConvexWethStrategy is CurveConvexStrategy {
    constructor(address _vault, address _weth, address _oracle, address _swapper, Config memory c)
        CurveConvexStrategy(_vault, _weth, _oracle, _swapper, c)
    {}
}
