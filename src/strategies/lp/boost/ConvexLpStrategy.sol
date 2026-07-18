// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LpBoosterStrategy} from "../../common/LpBoosterStrategy.sol";

/**
 * @title  ConvexLpStrategy  —  stake a Curve LP (base token) in Convex
 * @notice For an LP-BASE vault: users deposit a Curve LP token; this stakes it in
 *         Convex for boosted CRV + CVX, and compounds those back into more LP. Pure
 *         deployment of LpBoosterStrategy — pass Convex's booster, the pool's crvRewards
 *         contract, its pid, and rewardTokens = [CRV, CVX].
 */
contract ConvexLpStrategy is LpBoosterStrategy {
    constructor(
        address _vault,
        address _curveLp,
        address _oracle,
        address _swapper,
        address _booster,
        address _crvRewards,
        uint256 _pid,
        address[] memory _rewardTokens // [CRV, CVX]
    ) LpBoosterStrategy(_vault, _curveLp, _oracle, _swapper, _booster, _crvRewards, _pid, _rewardTokens) {}
}
