// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LpBoosterStrategy} from "../../common/LpBoosterStrategy.sol";

/**
 * @title  AuraLpStrategy  —  stake a Balancer BPT (base token) in Aura
 * @notice For an LP-BASE vault: users deposit a Balancer pool token (BPT); this stakes
 *         it in Aura for boosted BAL + AURA, and compounds those back into more BPT.
 *         Aura is a Convex fork, so it reuses LpBoosterStrategy unchanged — pass Aura's
 *         booster, the pool's rewards contract, its pid, and rewardTokens = [BAL, AURA].
 *
 *   This is exactly "like Convex+Curve, but on Balancer" — the same boost-and-compound
 *   pattern, a different underlying AMM.
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
        address[] memory _rewardTokens // [BAL, AURA]
    ) LpBoosterStrategy(_vault, _bpt, _oracle, _swapper, _auraBooster, _auraRewards, _pid, _rewardTokens) {}
}
