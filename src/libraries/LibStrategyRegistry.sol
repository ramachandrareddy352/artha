// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStorage, BPS_DENOMINATOR, MAX_IDLE_BPS, MAX_STRATEGIES_PER_VAULT} from "./VaultStorage.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  LibStrategyRegistry
 * @notice Add / disable / remove / migrate this vault's strategies, set target
 *         weights, and perform the low-level invest/divest that moves capital
 *         between the vault and its (stateless, zero-custody) strategies.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   RECEIPTS LIVE IN THE VAULT
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   invest : the vault approves `amount` of base to the strategy; the strategy
 *            pulls it and deposits into the venue with the receipt credited to
 *            the vault. `idleBalance` falls, the strategy's tracked value rises.
 *   divest : the vault grants the strategy transient access to the receipt token;
 *            the strategy redeems and returns base to the vault. `idleBalance`
 *            rises, the strategy's tracked value falls.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE INVARIANT: harvest-before-reallocate, always
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `removeStrategy` / `migrateStrategy` harvest the affected strategy FIRST and
 *  hard-revert if that harvest reverts — never reprice against stale value.
 *
 *  WEIGHTS: sum(strategyWeightBps) + idleTargetBps <= BPS_DENOMINATOR (strictly
 *  <=, so governance may intentionally widen the effective idle buffer).
 */
library LibStrategyRegistry {
    using SafeERC20 for IERC20;

    event StrategyAdded(address indexed strategy, uint16 weightBps);
    event StrategyDisabledSet(address indexed strategy, bool disabled);
    event StrategyRemoved(address indexed strategy, uint256 dustWrittenOff);
    event StrategyMigrated(address indexed from, address indexed to, uint256 movedAssets);
    event TargetsSet(address[] strategies, uint16[] weightsBps, uint16 idleTargetBps);
    event StrategyCircuitCleared(address indexed strategy);

    // ─────────────────────────── capital movement ───────────────────────────────

    /// @notice Approve `amount` of base to `strategy` and invest it, crediting the
    ///         venue receipt to this vault. Updates idle + tracked value.
    function investInto(address strategy, uint256 amount) internal {
        if (amount == 0) return;
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();

        IERC20(s.baseAsset).forceApprove(strategy, amount);
        IStrategy(strategy).invest(amount);
        IERC20(s.baseAsset).forceApprove(strategy, 0);

        s.idleBalance -= amount;
        s.strategyLastValue[strategy] += amount;
    }

    /// @notice Grant `strategy` transient receipt access, divest up to `amount`
    ///         base back into the vault, and return what was actually freed.
    ///         Keeps the circuit-breaker cache honest by decrementing tracked value.
    function divestFrom(address strategy, uint256 amount) internal returns (uint256 freed) {
        if (amount == 0) return 0;
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();

        address receipt = IStrategy(strategy).receiptToken();
        if (receipt != address(0)) IERC20(receipt).forceApprove(strategy, type(uint256).max);
        freed = IStrategy(strategy).divest(amount);
        if (receipt != address(0)) IERC20(receipt).forceApprove(strategy, 0);

        if (freed != 0) {
            s.idleBalance += freed;
            uint256 last = s.strategyLastValue[strategy];
            s.strategyLastValue[strategy] = freed >= last ? 0 : last - freed;
        }
    }

    /// @notice Fully unwind a strategy's position to base (emergency path — no
    ///         harvest, no slippage bound), crediting the proceeds to idle.
    function fullExit(address strategy) internal returns (uint256 freed) {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();

        address receipt = IStrategy(strategy).receiptToken();
        if (receipt != address(0)) IERC20(receipt).forceApprove(strategy, type(uint256).max);
        freed = IStrategy(strategy).emergencyWithdraw();
        if (receipt != address(0)) IERC20(receipt).forceApprove(strategy, 0);

        if (freed != 0) s.idleBalance += freed;
        s.strategyLastValue[strategy] = 0;
    }

    // ─────────────────────────── registry ───────────────────────────────────────

    function addStrategy(
        address strategy,
        address[] memory allStrategies,
        uint16[] memory allWeightsBps,
        uint16 idleTargetBps
    ) internal {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(strategy != address(0), "ZERO_ADDRESS");
        require(IStrategy(strategy).vault() == address(this), "STRATEGY_VAULT_MISMATCH");
        require(address(IStrategy(strategy).asset()) == s.baseAsset, "STRATEGY_ASSET_MISMATCH");

        address[] storage list = s.strategies;
        for (uint256 i; i < list.length; i++) {
            require(list[i] != strategy, "ALREADY_ADDED");
        }
        require(list.length < MAX_STRATEGIES_PER_VAULT, "MAX_STRATEGIES");

        list.push(strategy);
        emit StrategyAdded(strategy, 0);

        setTargets(allStrategies, allWeightsBps, idleTargetBps);
    }

    function setTargets(address[] memory strategies_, uint16[] memory weightsBps, uint16 idleTargetBps) internal {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(strategies_.length == weightsBps.length, "LENGTH_MISMATCH");
        require(idleTargetBps <= MAX_IDLE_BPS, "IDLE_TOO_HIGH");

        address[] storage registered = s.strategies;
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
            s.strategyWeightBps[strategies_[i]] = weightsBps[i];
        }
        require(sum <= BPS_DENOMINATOR, "WEIGHTS_EXCEED_100");

        s.idleTargetBps = idleTargetBps;
        emit TargetsSet(strategies_, weightsBps, idleTargetBps);
    }

    function setDisabled(address strategy, bool disabled) internal {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(_isKnown(s, strategy), "UNKNOWN_STRATEGY");
        s.strategyDisabled[strategy] = disabled;
        emit StrategyDisabledSet(strategy, disabled);
    }

    function clearCircuitBreak(address strategy) internal {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(_isKnown(s, strategy), "UNKNOWN_STRATEGY");
        s.strategyBroken[strategy] = false;
        emit StrategyCircuitCleared(strategy);
    }

    /// @notice Fully unwind and drop a strategy. Harvests (hard revert on failure
    ///         unless already broken), unwinds everything to idle, and requires the
    ///         residual to be <= dustFloor.
    function removeStrategy(address strategy, uint256 dustFloor) internal {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(_isKnown(s, strategy), "UNKNOWN_STRATEGY");

        if (!s.strategyBroken[strategy]) {
            try IStrategy(strategy).harvest() {} catch {
                revert("HARVEST_FAILED");
            }
        }

        fullExit(strategy);

        uint256 remaining = s.strategyBroken[strategy] ? 0 : IStrategy(strategy).positionValue();
        uint256 dust = remaining <= dustFloor ? remaining : 0;
        require(remaining == 0 || remaining <= dustFloor, "UNRECOVERABLE_BALANCE");

        _removeFromList(s, strategy);
        delete s.strategyWeightBps[strategy];
        delete s.strategyDisabled[strategy];
        delete s.strategyBroken[strategy];
        delete s.strategyLastValue[strategy];

        emit StrategyRemoved(strategy, dust);
    }

    /// @notice Atomically replace `from` with `to`, carrying the target weight over.
    function migrateStrategy(address from, address to) internal {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(_isKnown(s, from), "UNKNOWN_STRATEGY");
        require(to != address(0), "ZERO_ADDRESS");
        require(IStrategy(to).vault() == address(this), "STRATEGY_VAULT_MISMATCH");
        require(address(IStrategy(to).asset()) == s.baseAsset, "STRATEGY_ASSET_MISMATCH");

        address[] storage list = s.strategies;
        for (uint256 i; i < list.length; i++) {
            require(list[i] != to, "ALREADY_ADDED");
        }

        if (!s.strategyBroken[from]) {
            try IStrategy(from).harvest() {} catch {
                revert("HARVEST_FAILED");
            }
        }
        uint256 freed = fullExit(from);

        uint16 weight = s.strategyWeightBps[from];

        _removeFromList(s, from);
        delete s.strategyWeightBps[from];
        delete s.strategyDisabled[from];
        delete s.strategyBroken[from];
        delete s.strategyLastValue[from];

        list.push(to);
        s.strategyWeightBps[to] = weight;

        if (freed != 0) investInto(to, freed);

        emit StrategyMigrated(from, to, freed);
    }

    function _isKnown(VaultStorage.Layout storage s, address strategy) private view returns (bool) {
        address[] storage list = s.strategies;
        for (uint256 i; i < list.length; i++) {
            if (list[i] == strategy) return true;
        }
        return false;
    }

    function _removeFromList(VaultStorage.Layout storage s, address strategy) private {
        address[] storage list = s.strategies;
        uint256 n = list.length;
        for (uint256 i; i < n; i++) {
            if (list[i] == strategy) {
                // Preserve priority ORDER for the remaining strategies (a plain
                // swap-with-last would silently reorder the withdrawal queue).
                for (uint256 j = i; j < n - 1; j++) {
                    list[j] = list[j + 1];
                }
                list.pop();
                return;
            }
        }
    }
}
