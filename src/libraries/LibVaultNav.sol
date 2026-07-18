// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage, LibAppStorage, BPS_DENOMINATOR} from "./LibAppStorage.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";
import {LibVaultFee} from "./LibVaultFee.sol";

/**
 * @title  LibVaultNav
 * @notice Computes and checkpoints a vault's total value: idle base token held by
 *         the Diamond, plus every active strategy's own `totalAssets()` (which
 *         already folds in that strategy's position value AND haircut-adjusted
 *         pending rewards, oracle-converted to base token where the strategy's
 *         venue isn't base-denominated — see BaseStrategy's header).
 *
 *      navCheckpoint[vault] = idleBalance[vault] + sum(strategy.totalAssets())
 *                             over every NOT-broken, NOT-disabled strategy
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY CHECKPOINTED, NOT LIVE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  A naive design re-reads every strategy's `totalAssets()` on every balance check,
 *  every preview, every transfer-adjacent read. With up to 5 strategies per vault
 *  that is 5 external view calls just to answer "what is my balance worth" — a gas
 *  and griefing problem, and it means a single broken strategy (a stale oracle, a
 *  paused external protocol) can brick reads across every OTHER healthy strategy in
 *  the same vault. Instead, `navCheckpoint` is refreshed explicitly by
 *  `refreshNav()` at the start of every state-changing action (deposit, withdraw,
 *  harvest, settle) and simply READ by everything else (previews, balance display,
 *  the high-water-mark comparison).
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   A BROKEN STRATEGY NEVER BLOCKS THE VAULT
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `refreshNav` wraps each strategy's `totalAssets()` call so a revert (broken
 *  oracle, paused venue) or a suspicious value jump trips that strategy's
 *  `strategyBroken` flag and falls back to its LAST KNOWN GOOD value instead of
 *  reverting the whole vault's NAV. A vault where one bad integration can freeze
 *  every user's deposits and withdrawals in every OTHER strategy is a worse outcome
 *  than temporarily pricing one position off slightly stale data. Once broken, a
 *  strategy is excluded from new allocation (see LibStrategyRegistry) until
 *  governance clears the flag after investigating.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE CIRCUIT BREAKER
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `strategyMaxDeltaBps[vault]` bounds how much a strategy's reported value may
 *  move between two consecutive `refreshNav` calls (up OR down) before it is
 *  treated as suspicious rather than trusted. This is the main defense against a
 *  manipulated oracle or a compromised strategy feeding the vault an inflated NAV
 *  to mint itself cheap shares, or a deflated NAV to redeem shares for more than
 *  they are worth. A LEGITIMATE strategy's value moves gradually (interest accrual,
 *  slow reward accumulation) — a jump past the threshold in one block is the
 *  signature of manipulation, not yield.
 */
library LibVaultNav {
    event StrategyValueRefreshed(address indexed vault, address indexed strategy, uint256 value);
    event StrategyCircuitBroken(address indexed vault, address indexed strategy, uint256 lastValue, uint256 attemptedValue);
    event StrategyReadReverted(address indexed vault, address indexed strategy);
    event NavRefreshed(address indexed vault, uint256 totalAssets);

    /// @notice Recompute and store `navCheckpoint[vault]`. Call this FIRST in every
    ///         state-changing vault entry point, before any share-math conversion.
    function refreshNav(address vault) internal returns (uint256 totalAssets) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        totalAssets = s.idleBalance[vault];

        address[] storage strats = s.strategies[vault];
        uint256 n = strats.length;
        for (uint256 i; i < n; i++) {
            address strat = strats[i];
            if (s.strategyBroken[vault][strat]) {
                // Excluded from new deploys, but its last known-good value still
                // counts toward NAV — funds parked there are still real value,
                // even while allocation into/out of it is frozen pending review.
                totalAssets += s.strategyLastValue[vault][strat];
                continue;
            }

            try IStrategy(strat).totalAssets() returns (uint256 newValue) {
                uint256 lastValue = s.strategyLastValue[vault][strat];

                if (_isSuspiciousJump(lastValue, newValue, s.strategyMaxDeltaBps[vault])) {
                    s.strategyBroken[vault][strat] = true;
                    emit StrategyCircuitBroken(vault, strat, lastValue, newValue);
                    totalAssets += lastValue;
                    continue;
                }

                s.strategyLastValue[vault][strat] = newValue;
                emit StrategyValueRefreshed(vault, strat, newValue);
                totalAssets += newValue;
            } catch {
                emit StrategyReadReverted(vault, strat);
                totalAssets += s.strategyLastValue[vault][strat];
            }
        }

        s.navCheckpoint[vault] = totalAssets;
        emit NavRefreshed(vault, totalAssets);

        // Runs on EVERY refresh, not only at an explicit harvest — see
        // LibVaultFee's header for why price-per-share growth from pure interest
        // accrual (no harvest event at all) must still be caught here.
        LibVaultFee.chargePerformanceFee(vault);
    }

    /// @dev First-ever read of a strategy (lastValue == 0, e.g. right after it was
    ///      added) is never flagged — there is nothing to compare against yet, and
    ///      a genuinely empty new strategy legitimately reads 0.
    ///
    ///      Deliberately fail-SAFE, not fail-open, on `maxDeltaBps`: governance
    ///      input validation (VaultAdminFacet) rejects 0 outright, so this should
    ///      never see it in practice — but if it ever did, treating 0 as "zero
    ///      tolerance, trip on any change" is the safe failure mode. A silent
    ///      "0 == breaker disabled" bypass is exactly the kind of accidental
    ///      fail-open default this breaker exists to prevent elsewhere.
    function _isSuspiciousJump(uint256 lastValue, uint256 newValue, uint16 maxDeltaBps) private pure returns (bool) {
        if (lastValue == 0) return false;
        uint256 diff = newValue > lastValue ? newValue - lastValue : lastValue - newValue;
        uint256 limit = (lastValue * maxDeltaBps) / BPS_DENOMINATOR;
        return diff > limit;
    }

    /// @notice Read-only view of the last checkpoint, no refresh. Used by previews
    ///         and balance displays that intentionally price against the last
    ///         settled state rather than paying for a live strategy sweep.
    function cachedTotalAssets(address vault) internal view returns (uint256) {
        return LibAppStorage.diamondStorage().navCheckpoint[vault];
    }
}
