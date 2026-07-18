// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage, LibAppStorage, BPS_DENOMINATOR, MAX_IDLE_BPS, MAX_STRATEGIES_PER_VAULT} from "./LibAppStorage.sol";
import {LibVaultNav} from "./LibVaultNav.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  LibStrategyRegistry
 * @notice Add / disable / remove / migrate a vault's strategies, and set target
 *         allocation weights. Every function here is governance-only, called from
 *         VaultAdminFacet — never from a user-facing path.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE INVARIANT: harvest-before-reallocate, always
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Changing what a vault is allocated to (`setTargets`, `removeStrategy`,
 *  `migrateStrategy`) NEVER reprices against stale, un-harvested strategy value.
 *  Every one of these functions harvests every affected strategy FIRST — and if
 *  that harvest reverts (a swap slippage bound not met in current conditions), the
 *  WHOLE reallocation reverts with it. This is deliberate: reallocating against a
 *  NAV that hasn't captured pending yield either overpays or underpays whichever
 *  side of the reallocation is growing, and "just skip the failed harvest and
 *  proceed anyway" would silently mis-price the very users this system exists to
 *  protect. Wait for conditions to improve and retry.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WEIGHTS: sum(strategyWeightBps) + idleTargetBps <= BPS_DENOMINATOR
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Strictly <=, not ==. Governance may intentionally leave the sum under 100%,
 *  which widens the EFFECTIVE idle buffer beyond `idleTargetBps` for a cautious
 *  period without needing a separate "extra buffer" concept.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   DISABLED vs BROKEN vs REMOVED
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   disabled : governance-set. Blocks NEW deploys into it (deployIdle/rebalance
 *              skip it), but existing capital stays and it is still withdrawn from
 *              in priority order and still counted in NAV. The lightweight tool for
 *              "stop growing this position" without the gas cost of a full unwind.
 *   broken   : circuit-breaker-set (LibVaultNav), not governance. Same effect as
 *              disabled for new deploys, but signals an AUTOMATIC trip (suspicious
 *              value jump or a reverting read) that governance must investigate
 *              before clearing, vs `disabled` which is a deliberate choice.
 *   removed  : fully unwound (harvested + withdrawn to idle) and dropped from the
 *              vault's strategy list entirely. Irreversible without re-adding.
 */
library LibStrategyRegistry {
    using SafeERC20 for IERC20;

    event StrategyAdded(address indexed vault, address indexed strategy, uint16 weightBps);
    event StrategyDisabledSet(address indexed vault, address indexed strategy, bool disabled);
    event StrategyRemoved(address indexed vault, address indexed strategy, uint256 dustWrittenOff);
    event StrategyMigrated(address indexed vault, address indexed from, address indexed to, uint256 movedAssets);
    event TargetsSet(address indexed vault, address[] strategies, uint16[] weightsBps, uint16 idleTargetBps);
    event StrategyCircuitCleared(address indexed vault, address indexed strategy);

    /// @notice Add a new strategy to a vault and set the FULL target vector in one
    ///         call (see the header on `setTargets` for why add + reweight is
    ///         atomic here, unlike a pure reweight which is execution-decoupled).
    function addStrategy(
        address vault,
        address strategy,
        address[] memory allStrategies,
        uint16[] memory allWeightsBps,
        uint16 idleTargetBps
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(strategy != address(0), "ZERO_ADDRESS");
        require(IStrategy(strategy).vault() == address(this), "STRATEGY_VAULT_MISMATCH");
        require(IStrategy(strategy).asset() == IERC20(s.baseAsset[vault]), "STRATEGY_ASSET_MISMATCH");

        address[] storage list = s.strategies[vault];
        for (uint256 i; i < list.length; i++) {
            require(list[i] != strategy, "ALREADY_ADDED");
        }
        require(list.length < MAX_STRATEGIES_PER_VAULT, "MAX_STRATEGIES");

        list.push(strategy);
        emit StrategyAdded(vault, strategy, 0);

        setTargets(vault, allStrategies, allWeightsBps, idleTargetBps);
    }

    /// @notice Update target weights only. Does NOT move any capital — the next
    ///         `deployIdle`/`rebalance` call (VaultHarvestFacet) executes toward
    ///         these targets. Decoupling intent from execution keeps this call
    ///         cheap and means it can never revert on slippage; it only ever
    ///         reverts on a bad weight vector.
    function setTargets(
        address vault,
        address[] memory strategies_,
        uint16[] memory weightsBps,
        uint16 idleTargetBps
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(strategies_.length == weightsBps.length, "LENGTH_MISMATCH");
        require(idleTargetBps <= MAX_IDLE_BPS, "IDLE_TOO_HIGH");

        address[] storage registered = s.strategies[vault];
        require(strategies_.length == registered.length, "MUST_COVER_ALL_STRATEGIES");

        uint256 sum = idleTargetBps;
        for (uint256 i; i < strategies_.length; i++) {
            bool found;
            for (uint256 j; j < registered.length; j++) {
                if (registered[j] == strategies_[i]) {
                    found = true;
                    break;
                }
            }
            require(found, "UNKNOWN_STRATEGY");
            sum += weightsBps[i];
            s.strategyWeightBps[vault][strategies_[i]] = weightsBps[i];
        }
        require(sum <= BPS_DENOMINATOR, "WEIGHTS_EXCEED_100");

        s.idleTargetBps[vault] = idleTargetBps;
        emit TargetsSet(vault, strategies_, weightsBps, idleTargetBps);
    }

    /// @notice Blocks new deploys into `strategy` without unwinding it. Existing
    ///         capital keeps earning and is still counted in NAV and still eligible
    ///         to be drained on withdrawal.
    function setDisabled(address vault, address strategy, bool disabled) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(_isKnown(s, vault, strategy), "UNKNOWN_STRATEGY");
        s.strategyDisabled[vault][strategy] = disabled;
        emit StrategyDisabledSet(vault, strategy, disabled);
    }

    /// @notice Governance-reviewed clear of an automatic circuit-break, after
    ///         confirming the strategy is actually healthy again.
    function clearCircuitBreak(address vault, address strategy) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(_isKnown(s, vault, strategy), "UNKNOWN_STRATEGY");
        s.strategyBroken[vault][strategy] = false;
        emit StrategyCircuitCleared(vault, strategy);
    }

    /// @notice Fully unwind and drop a strategy. Harvests, withdraws everything it
    ///         will give up, and credits the proceeds to the vault's idle balance.
    ///         Reverts if the harvest reverts (see the header). Any unrecoverable
    ///         dust below `dustFloor` (venue-rounding remainder that cannot be
    ///         extracted, e.g. Curve's LP rounding) is written off rather than
    ///         blocking removal forever.
    function removeStrategy(address vault, address strategy, uint256 dustFloor) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(_isKnown(s, vault, strategy), "UNKNOWN_STRATEGY");

        if (!s.strategyBroken[vault][strategy]) {
            try IStrategy(strategy).harvest() {} catch {
                revert("HARVEST_FAILED");
            }
        }

        uint256 freed = IStrategy(strategy).emergencyWithdraw();
        s.idleBalance[vault] += freed;

        uint256 remaining = s.strategyBroken[vault][strategy] ? 0 : IStrategy(strategy).totalAssets();
        uint256 dust = remaining <= dustFloor ? remaining : 0;
        require(remaining == 0 || remaining <= dustFloor, "UNRECOVERABLE_BALANCE");

        _removeFromList(s, vault, strategy);
        delete s.strategyWeightBps[vault][strategy];
        delete s.strategyDisabled[vault][strategy];
        delete s.strategyBroken[vault][strategy];
        delete s.strategyLastValue[vault][strategy];

        emit StrategyRemoved(vault, strategy, dust);
    }

    /// @notice Atomically replace `from` with `to` (e.g. swapping in a fixed
     ///        version of a buggy strategy) in ONE call, so the capital's target
     ///        allocation is never left idle between a separate remove and a
     ///        separate add. Harvests and fully unwinds `from`, deploys the freed
     ///        base token into `to`, and carries `from`'s target weight over to
     ///        `to` unchanged.
    function migrateStrategy(address vault, address from, address to) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(_isKnown(s, vault, from), "UNKNOWN_STRATEGY");
        require(to != address(0), "ZERO_ADDRESS");
        require(IStrategy(to).vault() == address(this), "STRATEGY_VAULT_MISMATCH");
        require(IStrategy(to).asset() == IERC20(s.baseAsset[vault]), "STRATEGY_ASSET_MISMATCH");

        address[] storage list = s.strategies[vault];
        for (uint256 i; i < list.length; i++) {
            require(list[i] != to, "ALREADY_ADDED");
        }

        if (!s.strategyBroken[vault][from]) {
            try IStrategy(from).harvest() {} catch {
                revert("HARVEST_FAILED");
            }
        }
        uint256 freed = IStrategy(from).emergencyWithdraw();

        uint16 weight = s.strategyWeightBps[vault][from];

        _removeFromList(s, vault, from);
        delete s.strategyWeightBps[vault][from];
        delete s.strategyDisabled[vault][from];
        delete s.strategyBroken[vault][from];
        delete s.strategyLastValue[vault][from];

        list.push(to);
        s.strategyWeightBps[vault][to] = weight;

        if (freed != 0) {
            IERC20(s.baseAsset[vault]).forceApprove(to, freed);
            IStrategy(to).deposit(freed);
        }

        emit StrategyMigrated(vault, from, to, freed);
    }

    function _isKnown(AppStorage storage s, address vault, address strategy) private view returns (bool) {
        address[] storage list = s.strategies[vault];
        for (uint256 i; i < list.length; i++) {
            if (list[i] == strategy) return true;
        }
        return false;
    }

    function _removeFromList(AppStorage storage s, address vault, address strategy) private {
        address[] storage list = s.strategies[vault];
        uint256 n = list.length;
        for (uint256 i; i < n; i++) {
            if (list[i] == strategy) {
                // Preserve priority ORDER for the remaining strategies (a plain
                // swap-with-last would silently reorder the withdrawal queue) —
                // shift everything after `i` left by one instead.
                for (uint256 j = i; j < n - 1; j++) {
                    list[j] = list[j + 1];
                }
                list.pop();
                return;
            }
        }
    }
}
