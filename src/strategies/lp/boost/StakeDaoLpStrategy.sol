// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LpBoosterStrategy} from "../../common/LpBoosterStrategy.sol";

/**
 * @title  StakeDaoLpStrategy — stake a Curve/Balancer LP (base token) in StakeDAO
 * @notice For an LP-BASE vault: stakes the LP in StakeDAO's liquid-locker gauge for
 *         boosted emissions (CRV/BAL plus SDT) and compounds them back into more LP.
 *
 *   ⚠ INTERFACE NOTE: StakeDAO's surface is Convex-LIKE but not identical across its
 *     product versions — some deposits route through a "vault" wrapper and rewards
 *     through a gauge's `claim_rewards()` rather than `getReward()`. This subclass
 *     assumes the Convex-shaped booster/rewards surface that `LpBoosterStrategy`
 *     implements. VERIFY against the live StakeDAO deployment before use; if it
 *     differs, write a StakeDAO-specific base rather than bending this one.
 *
 *   `_primaryReward` is the emission whose accrual the gauge exposes via `earned()`
 *   (CRV or BAL); SDT and any extras are sold on harvest but under-reported until
 *   claimed, per the rule in `MultiRewardStrategy`.
 */
contract StakeDaoLpStrategy is LpBoosterStrategy {
    constructor(
        address _vault,
        address _lp,
        address _oracle,
        address _swapper,
        address _booster,
        address _gaugeRewards,
        uint256 _pid,
        address _primaryReward, // CRV or BAL
        address[] memory _rewardTokens // e.g. [CRV, SDT] or [BAL, SDT]
    ) LpBoosterStrategy(_vault, _lp, _oracle, _swapper, _booster, _gaugeRewards, _pid, _primaryReward, _rewardTokens) {}
}
