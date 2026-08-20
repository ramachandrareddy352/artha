// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3LendStrategy} from "../../common/AaveV3LendStrategy.sol";

/**
 * @title  AaveV3WbtcStrategy — supply WBTC to Aave V3
 * @notice The WBTC vault's only clean, liquid, low-risk lending leg.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY BTC LENDING PAYS ALMOST NOTHING
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  On-chain BTC yield is genuinely thin, and it is worth understanding why rather than
 *  hunting for a better rate: WBTC is used almost entirely as COLLATERAL to borrow
 *  against, not as an asset people want to borrow. Supply is deep, borrow demand is
 *  scarce, so utilization — and the supply APR with it — sits near zero (~0.02-1%).
 *  Compound III has no WBTC base market at all, for the same reason.
 *
 *  That is precisely why a WBTC vault's interesting yield does NOT come from lending
 *  it. It comes from `WbtcRotationStrategy` — trading the BTC/stable pair to accumulate
 *  more BTC — with this leg as the safe, liquid remainder that the withdrawal queue can
 *  always drain first.
 *
 *  Higher-yield BTC venues (Lombard LBTC, Solv, Babylon restaking) are newer, are not
 *  simple synchronous adapters, and carry bridge or restaking risk on top. Treat them
 *  as bespoke later additions, not as thin wrappers.
 */
contract AaveV3WbtcStrategy is AaveV3LendStrategy {
    constructor(
        address _vault,
        address _wbtc,
        address _oracle,
        address _swapper,
        address _pool,
        address _aWbtc,
        address _rewardsController,
        address[] memory _rewardTokens
    ) AaveV3LendStrategy(_vault, _wbtc, _oracle, _swapper, _pool, _aWbtc, _rewardsController, _rewardTokens) {}
}
