// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStorage, BPS_DENOMINATOR} from "./VaultStorage.sol";
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
    event VaultAutoPaused(address indexed strategy);

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
    ///         RE-ANCHORS the circuit breaker and crystallizes the performance fee.
    function refreshNav() internal returns (uint256 totalAssets) {
        return _refreshNav(true);
    }

    /// @notice Recompute `navCheckpoint` from live reads WITHOUT re-anchoring the
    ///         circuit breaker and WITHOUT crystallizing the performance fee.
    ///
    ///         This is the form a PERMISSIONLESS caller gets (`settle`). Letting an
    ///         arbitrary caller re-anchor `strategyLastValue` would hand them the
    ///         breaker's budget: they could walk a strategy's reported value up in
    ///         sub-threshold steps, re-anchoring after each one, and never trip it.
    ///         Here a suspicious reading is simply IGNORED (the anchored value is
    ///         used instead) rather than trusted or used to trip the breaker — so a
    ///         permissionless call can neither write a manipulated NAV nor grief the
    ///         vault into a circuit break at a moment of its choosing.
    function refreshNavUnanchored() internal returns (uint256 totalAssets) {
        return _refreshNav(false);
    }

    /// @param anchor When true, accepted readings advance `strategyLastValue` /
    ///        `strategyLastRefresh`, a suspicious reading trips the breaker, and the
    ///        performance fee is crystallized. When false, none of that state moves.
    function _refreshNav(bool anchor) private returns (uint256 totalAssets) {
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
                    if (anchor) _breakCircuit(s, strat, lastValue, newValue);
                    totalAssets += lastValue;
                    continue;
                }

                if (anchor) {
                    s.strategyLastValue[strat] = newValue;
                    emit StrategyValueRefreshed(strat, newValue);
                }
                totalAssets += newValue;
            } catch {
                emit StrategyReadReverted(strat);
                // A read that reverts is a DEGRADED strategy, not a healthy one. Flag
                // it so every downstream consumer treats it deterministically — most
                // importantly `WithdrawFacet._drain`, which skips broken strategies
                // and would otherwise walk into the same reverting venue and take the
                // whole withdrawal down with it.
                if (anchor) _breakCircuit(s, strat, s.strategyLastValue[strat], 0);
                totalAssets += s.strategyLastValue[strat];
            }
        }

        s.navCheckpoint = totalAssets;
        emit NavRefreshed(totalAssets);

        // Runs on EVERY anchored refresh — see LibVaultFee for why price-per-share
        // growth from pure interest accrual (no harvest event) must still be caught.
        if (anchor) LibVaultFee.chargePerformanceFee();
    }

    /// @dev Trip the breaker AND pause the vault.
    ///
    ///      The pause is the point. A degraded strategy keeps its last known-good
    ///      value in NAV (so one bad venue can't freeze everything) but is skipped by
    ///      `_drain` — which means, left running, redeemers would burn shares priced
    ///      at a stale-high NAV and be paid out of the HEALTHY strategies. First
    ///      movers would exit whole and the entire shortfall would land on whoever
    ///      redeemed last. Pausing stops deposits and normal withdrawals for everyone
    ///      at once, so the loss cannot be raced: the only remaining exit is
    ///      `emergencyWithdraw`, which prices against a POST-unwind NAV and does
    ///      attempt to unwind the suspect strategy.
    function _breakCircuit(VaultStorage.Layout storage s, address strat, uint256 lastValue, uint256 attemptedValue)
        private
    {
        s.strategyBroken[strat] = true;
        emit StrategyCircuitBroken(strat, lastValue, attemptedValue);
        // Nothing is at stake in a strategy tracked at zero (freshly added, or already
        // fully exited), so there is no mispriced value to race over. Flag it, but do
        // not freeze the vault over a position that holds nothing.
        if (lastValue != 0 && !s.paused) {
            s.paused = true;
            emit VaultAutoPaused(strat);
        }
    }

    /// @dev First-ever read of a strategy (lastValue == 0) is never flagged.
    ///      Fail-SAFE on maxDeltaBps == 0: treat as "trip on any change" rather
    ///      than a silent "breaker disabled" (governance input validation rejects
    ///      0 anyway, so this should never be seen in practice).
    ///
    ///  ═══════════════════════════════════════════════════════════════════════════
    ///   KNOWN LIMIT: THIS BOUNDS MOVEMENT PER REFRESH, NOT PER UNIT TIME
    ///  ═══════════════════════════════════════════════════════════════════════════
    ///      An accepted reading RATCHETS `strategyLastValue`, so in principle a value
    ///      can be walked past the threshold in sub-threshold steps by re-anchoring
    ///      between each one. The free re-anchor is now closed — `settle`/`sync` use
    ///      `refreshNavUnanchored` — so an attacker must pay for each step with a real
    ///      deposit or withdrawal, or hold the keeper role.
    ///
    ///      Fully closing it needs an anchor that does not move with the attacker
    ///      (time-rate budget, or drift measured against a keeper-confirmed value).
    ///      A naive per-second budget is NOT safe here: harvest legitimately moves
    ///      value out of a position, so a tight time-rate bound trips the breaker on a
    ///      routine keeper harvest and — with the auto-pause below — would freeze the
    ///      vault. Distinguishing yield from manipulation needs a harvest-aware model;
    ///      that is a design decision, not a patch.
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
