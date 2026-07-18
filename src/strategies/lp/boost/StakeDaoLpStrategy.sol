// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LpBoosterStrategy} from "../../common/LpBoosterStrategy.sol";

/**
 * @title  StakeDaoLpStrategy  —  stake a Curve/Balancer LP (base token) in StakeDAO
 * @notice For an LP-BASE vault: users deposit the LP; this stakes it in StakeDAO's
 *         liquid-locker gauge for boosted emissions (CRV/BAL + SDT), and compounds
 *         them back into more LP.
 *
 *   ⚠ INTERFACE NOTE: StakeDAO's gauge/vault surface is Convex-like but not identical
 *     across its product versions (some deposits go via a "vault" wrapper, rewards via
 *     a "gauge" with claim_rewards()). This subclass assumes the Convex-shaped
 *     booster/rewards surface of LpBoosterStrategy; if the target StakeDAO product
 *     differs, adapt LpBoosterStrategy's ILpBooster/ILpBoosterRewards or add a
 *     StakeDAO-specific base. VERIFY against the live StakeDAO deployment before use.
 *
 *   rewardTokens = the gauge's emission set, e.g. [CRV, SDT] or [BAL, SDT].
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
        address[] memory _rewardTokens
    ) LpBoosterStrategy(_vault, _lp, _oracle, _swapper, _booster, _gaugeRewards, _pid, _rewardTokens) {}
}
