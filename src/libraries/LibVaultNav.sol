// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStorage, BPS_DENOMINATOR, DELTA_ALLOWANCE_WINDOW} from "./VaultStorage.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";
import {LibVaultFee} from "./LibVaultFee.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title  LibVaultNav
 * @notice Computes and checkpoints THIS vault's total value from what the vault
 *         actually holds:
 *
 *      navCheckpoint = idleBalance
 *                    + Σ strategy.positionValue()   (each strategy reads the
 *                                                     VAULT's own venue holdings)
 *                    over every NOT-broken strategy, with broken strategies
 *                    frozen at their last known-good value.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   TOTAL LIQUIDITY = WHAT THE VAULT CONTAINS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Because every DeFi receipt lives in the vault (not in a strategy), a
 *  strategy's `positionValue()` is a read of the vault's OWN holdings at the
 *  venue. NAV is therefore grounded in real custody, not a hand-maintained
 *  ledger that can silently drift from it.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   SYNC — DIRECT TRANSFERS ("EXTRA") ARE FOLDED IN
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Base token sent straight to the vault (bypassing deposit) is not tracked as
 *  idle until `sync()` reconciles the ledger against the real balance and credits
 *  the surplus. Receipt tokens donated to the vault are already reflected the next
 *  time NAV is refreshed, since `positionValue()` reads the vault's live holdings.
 *  Either way a donation only ever lifts existing holders' share value.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE CIRCUIT BREAKER
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `strategyMaxDeltaBps` bounds how much a strategy's reported value may move
 *  between two consecutive refreshes before it is treated as suspicious rather
 *  than trusted. A jump past the threshold trips `strategyBroken` and falls back
 *  to the last known-good value instead of trusting a manipulated read.
 */
library LibVaultNav {
    event StrategyValueRefreshed(address indexed strategy, uint256 value);
    event StrategyCircuitBroken(address indexed strategy, uint256 lastValue, uint256 attemptedValue);
    event StrategyReadReverted(address indexed strategy);
    event NavRefreshed(uint256 totalAssets);
    event Synced(uint256 creditedExtra, uint256 idleAfter);

    /// @notice Reconcile the idle ledger against the vault's real base balance,
    ///         crediting any un-tracked surplus (a direct donation) into idle.
    ///         Permissionless-safe: it can only ever increase idle by real,
    ///         already-received tokens, never move value out.
    function sync() internal returns (uint256 creditedExtra) {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        uint256 actualBase = IERC20(s.baseAsset).balanceOf(address(this));
        if (actualBase > s.idleBalance) {
            creditedExtra = actualBase - s.idleBalance;
            s.idleBalance = actualBase;
        }
        emit Synced(creditedExtra, s.idleBalance);
    }

    /// @notice Recompute and store `navCheckpoint`. Call this FIRST in every
    ///         state-changing vault entry point, before any share-math conversion.
    function refreshNav() internal returns (uint256 totalAssets) {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();

        totalAssets = s.idleBalance;

        address[] storage strats = s.strategies;
        uint256 n = strats.length;
        for (uint256 i; i < n; i++) {
            address strat = strats[i];
            if (s.strategyBroken[strat]) {
                totalAssets += s.strategyLastValue[strat];
                continue;
            }

            try IStrategy(strat).positionValue() returns (uint256 newValue) {
                uint256 lastValue = s.strategyLastValue[strat];

                if (_isSuspiciousJump(lastValue, newValue, s.strategyMaxDeltaBps)) {
                    s.strategyBroken[strat] = true;
                    emit StrategyCircuitBroken(strat, lastValue, newValue);
                    totalAssets += lastValue;
                    continue;
                }

                s.strategyLastValue[strat] = newValue;
                emit StrategyValueRefreshed(strat, newValue);
                totalAssets += newValue;
            } catch {
                emit StrategyReadReverted(strat);
                totalAssets += s.strategyLastValue[strat];
            }
        }

        s.navCheckpoint = totalAssets;
        emit NavRefreshed(totalAssets);

        // Runs on EVERY refresh — see LibVaultFee for why price-per-share growth
        // from pure interest accrual (no harvest event) must still be caught here.
        LibVaultFee.chargePerformanceFee();
    }

    /// @dev First-ever read of a strategy (lastValue == 0) is never flagged.
    ///      Fail-SAFE on maxDeltaBps == 0: treat as "trip on any change" rather
    ///      than a silent "breaker disabled" (governance input validation rejects
    ///      0 anyway, so this should never be seen in practice).
    function _isSuspiciousJump(uint256 lastValue, uint256 newValue, uint16 maxDeltaBps) private pure returns (bool) {
        if (lastValue == 0) return false;
        uint256 diff = newValue > lastValue ? newValue - lastValue : lastValue - newValue;
        uint256 limit = (lastValue * maxDeltaBps) / BPS_DENOMINATOR;
        return diff > limit;
    }

    /// @notice Read-only view of the last checkpoint, no refresh.
    function cachedTotalAssets() internal view returns (uint256) {
        return VaultStorage.vaultLayout().navCheckpoint;
    }
}
