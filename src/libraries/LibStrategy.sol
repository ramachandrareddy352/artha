// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage} from "./LibAppStorage.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  LibStrategy
 * @notice Helpers for per-pool idle-holding accounting and pro-rata strategy exit.
 *         "idle" = tokens sitting in the Diamond, tracked as idleUsdc (for USDC) or
 *         poolTokenBalance (for basket tokens) so the six pools stay separate.
 */
library LibStrategy {
    using SafeERC20 for IERC20;

    /// @dev Remove `amount` of `token` from a pool's idle accounting.
    function debit(AppStorage storage s, uint8 poolId, address token, uint256 amount) internal {
        if (token == s.usdc) {
            require(s.idleUsdc[poolId] >= amount, "INSUFFICIENT_IDLE_USDC");
            s.idleUsdc[poolId] -= amount;
        } else {
            require(s.poolTokenBalance[poolId][token] >= amount, "INSUFFICIENT_IDLE_TOKEN");
            s.poolTokenBalance[poolId][token] -= amount;
        }
    }

    /// @dev Add `amount` of `token` to a pool's idle accounting.
    function credit(AppStorage storage s, uint8 poolId, address token, uint256 amount) internal {
        if (token == s.usdc) {
            s.idleUsdc[poolId] += amount;
        } else {
            s.poolTokenBalance[poolId][token] += amount;
        }
    }

    /// @dev Register a strategy adapter as active for a pool (dedup).
    function addStrategy(AppStorage storage s, uint8 poolId, address strat) internal {
        address[] storage arr = s.poolStrategies[poolId];
        for (uint256 i; i < arr.length; i++) {
            if (arr[i] == strat) return;
        }
        arr.push(strat);
    }

    /**
     * @dev Redeem `num/den` of each of a pool's strategy positions and send the
     *      underlying straight to `user` (used by in-kind withdrawal). No swaps.
     */
    function redeemProRataToUser(AppStorage storage s, uint8 poolId, address user, uint256 num, uint256 den)
        internal
    {
        address[] storage strats = s.poolStrategies[poolId];
        for (uint256 i; i < strats.length; i++) {
            IStrategy strat = IStrategy(strats[i]);
            uint256 ps = strat.poolShares(poolId);
            if (ps == 0) continue;
            uint256 shareAmt = (ps * num) / den;
            if (shareAmt == 0) continue;
            uint256 got = strat.withdrawShares(poolId, shareAmt);
            if (got != 0) IERC20(strat.underlying()).safeTransfer(user, got);
        }
    }
}
