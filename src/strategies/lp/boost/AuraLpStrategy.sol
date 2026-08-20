// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LpBoosterStrategy} from "../../common/LpBoosterStrategy.sol";

/**
 * @title  AuraLpStrategy — stake a Balancer BPT (the vault's base token) in Aura
 * @notice The same boost-and-compound pattern as `ConvexLpStrategy`, on Balancer: Aura
 *         is a Convex fork with an identical booster/rewards surface, so it reuses
 *         `LpBoosterStrategy` unchanged. Pass Aura's booster, the pool's rewards
 *         contract, its pid, BAL as the primary emission, and [BAL, AURA].
 */
contract AuraLpStrategy is LpBoosterStrategy {
    constructor(
        address _vault,
        address _bpt,
        address _oracle,
        address _swapper,
        address _auraBooster,
        address _auraRewards,
        uint256 _pid,
        address _bal,
        address[] memory _rewardTokens // [BAL, AURA]
    ) LpBoosterStrategy(_vault, _bpt, _oracle, _swapper, _auraBooster, _auraRewards, _pid, _bal, _rewardTokens) {}
}
