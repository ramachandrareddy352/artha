// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LpBoosterStrategy} from "../../common/LpBoosterStrategy.sol";

/**
 * @title  ConvexLpStrategy — stake a Curve LP (the vault's base token) in Convex
 * @notice For an LP-BASE vault: users deposit a Curve LP token, this stakes it in
 *         Convex for boosted CRV + CVX and compounds both back into more LP. Pure
 *         deployment of `LpBoosterStrategy` — pass Convex's booster, the pool's
 *         crvRewards contract, its pid, CRV as the primary (view-readable) emission,
 *         and the full reward set.
 *
 *   Requires a FAIR-LP price for the base token in the oracle before harvest can sell
 *   anything — see the base contract's oracle requirement.
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
        address _crv,
        address[] memory _rewardTokens // [CRV, CVX, ...extras]
    ) LpBoosterStrategy(_vault, _curveLp, _oracle, _swapper, _booster, _crvRewards, _pid, _crv, _rewardTokens) {}
}
