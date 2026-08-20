// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStorage, VaultModifiers, BPS_DENOMINATOR} from "../libraries/VaultStorage.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";
import {LibStrategyRegistry} from "../libraries/LibStrategyRegistry.sol";

/**
 * @title  StrategyFacet
 * @notice Keeper operations that keep NAV fresh and capital where it should be:
 *         harvesting, deploying idle, and rebalancing. `settle` is permissionless.
 *
 *         In the executor model every strategy `harvest()` sends realized base
 *         straight back to the VAULT (as idle) rather than reinvesting — the next
 *         `deployIdle` redeploys it. `deployIdle`/`rebalance` move base between the
 *         vault and strategies via `LibStrategyRegistry.investInto`/`divestFrom`,
 *         with all venue receipts held by the vault throughout.
 */
contract StrategyFacet is VaultModifiers {
    event StrategyHarvested(address indexed strategy, uint256 realized);
    event StrategyTended(address indexed strategy);
    event IdleDeployed(address indexed strategy, uint256 amount);
    event Rebalanced(uint256 totalAssets, uint256 idleAfter);
    event Settled(uint256 totalAssets);

    // ═══════════════════════════════ harvest ══════════════════════════════════════

    /// @dev `strategy` MUST be registered. Without that check `strategyBroken` on an
    ///      unknown address reads false, so any address passes — and since the credit
    ///      below is measured rather than returned, a keeper could otherwise point this
    ///      at a contract that transfers nothing, inflate `idleBalance` by an arbitrary
    ///      amount, and redeem against real assets at the inflated price. The keeper is
    ///      an operational hot key and must not be able to reach user principal.
    function harvest(address strategy) external onlyKeeper nonReentrant returns (uint256 realized) {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(LibStrategyRegistry.isKnown(strategy), "UNKNOWN_STRATEGY");
        require(!s.strategyBroken[strategy], "STRATEGY_BROKEN");

        bool ok;
        (ok, realized) = LibStrategyRegistry.harvestInto(strategy);
        require(ok, "HARVEST_FAILED");

        LibVaultNav.refreshNav();
        emit StrategyHarvested(strategy, realized);
    }

    function harvestAll() external onlyKeeper nonReentrant {
        _harvestAll(VaultStorage.vaultLayout(), false);
        LibVaultNav.refreshNav();
    }

    // ════════════════════════════════ tend ════════════════════════════════════════

    /// @notice Ask a strategy to maintain its position — the keeper call that lets a
    ///         `RotationStrategy` act on its bands, and that any strategy can use to
    ///         re-park capital. Moves no base in or out of the vault.
    ///
    /// @dev    `onlyKeeper` for the same reason `harvest` is: tending costs gas and can
    ///         cross a swap, so letting anyone trigger it would let anyone grief a
    ///         position with repeated slippage. It is bounded further by each strategy's
    ///         own cooldown and by its oracle-derived swap floor, but the keeper gate is
    ///         what makes the TIMING ours.
    ///
    ///         Registered-only, like harvest: without it any address could be passed
    ///         here and made to run arbitrary code in the vault's name.
    function tend(address strategy) external onlyKeeper nonReentrant {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(LibStrategyRegistry.isKnown(strategy), "UNKNOWN_STRATEGY");
        require(!s.strategyBroken[strategy], "STRATEGY_BROKEN");

        require(LibStrategyRegistry.tendInto(strategy), "TEND_FAILED");

        // A rotation changes what the position is made of, so the checkpoint it was
        // priced against is stale the moment it returns.
        LibVaultNav.refreshNav();
        emit StrategyTended(strategy);
    }

    /// @notice Tend every healthy strategy. Failures are skipped, not fatal — see
    ///         `LibStrategyRegistry.tendInto`.
    function tendAll() external onlyKeeper nonReentrant {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        address[] storage strats = s.strategies;
        uint256 n = strats.length;
        for (uint256 i; i < n; i++) {
            address strat = strats[i];
            if (s.strategyBroken[strat]) continue;
            if (LibStrategyRegistry.tendInto(strat)) emit StrategyTended(strat);
        }
        LibVaultNav.refreshNav();
    }

    /// @notice Permissionless NAV checkpoint refresh. No claim, no swap.
    /// @dev    Deliberately UNANCHORED: a permissionless caller may refresh the
    ///         checkpoint so views are current, but may not re-anchor the circuit
    ///         breaker, trip it, or crystallize the performance fee. See
    ///         `LibVaultNav.refreshNavUnanchored`.
    function settle() external nonReentrant {
        uint256 totalAssets = LibVaultNav.refreshNavUnanchored();
        emit Settled(totalAssets);
    }

    // ═══════════════════════════ capital deployment ═══════════════════════════════

    function deployIdle() external onlyKeeper whenNotPaused nonReentrant {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        uint256 totalAssets = LibVaultNav.refreshNav();
        // refreshNav can trip a breaker and auto-pause mid-call; don't deploy capital
        // into a vault that just declared an emergency.
        require(!s.paused, "PAUSED");
        uint256 targetIdle = (totalAssets * s.idleTargetBps) / BPS_DENOMINATOR;
        uint256 idle = s.idleBalance;
        if (idle <= targetIdle) return;

        uint256 available = idle - targetIdle;
        address[] storage strats = s.strategies;
        uint256 n = strats.length;

        for (uint256 i; i < n && available != 0; i++) {
            address strat = strats[i];
            if (s.strategyDisabled[strat] || s.strategyBroken[strat]) continue;

            uint256 target = (totalAssets * s.strategyWeightBps[strat]) / BPS_DENOMINATOR;
            uint256 current = s.strategyLastValue[strat];
            if (current >= target) continue;

            uint256 gap = target - current;
            uint256 toDeploy = gap < available ? gap : available;
            if (toDeploy == 0) continue;

            LibStrategyRegistry.investInto(strat, toDeploy);
            available -= toDeploy;
            emit IdleDeployed(strat, toDeploy);
        }
    }

    function rebalance() external onlyKeeper whenNotPaused nonReentrant {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();

        // Step 1: harvest everything first (hard revert on failure).
        _harvestAll(s, true);

        uint256 totalAssets = LibVaultNav.refreshNav();
        require(!s.paused, "PAUSED"); // see deployIdle(): refreshNav may auto-pause mid-call
        address[] storage strats = s.strategies;
        uint256 n = strats.length;

        // pass 1: pull excess out of over-allocated strategies into idle
        for (uint256 i; i < n; i++) {
            address strat = strats[i];
            if (s.strategyBroken[strat]) continue;

            uint256 target = (totalAssets * s.strategyWeightBps[strat]) / BPS_DENOMINATOR;
            uint256 current = s.strategyLastValue[strat];
            if (current <= target) continue;

            LibStrategyRegistry.divestFrom(strat, current - target);
        }

        // pass 2: deploy surplus into under-allocated strategies
        uint256 targetIdle = (totalAssets * s.idleTargetBps) / BPS_DENOMINATOR;
        uint256 idle = s.idleBalance;
        uint256 available = idle > targetIdle ? idle - targetIdle : 0;

        for (uint256 i; i < n && available != 0; i++) {
            address strat = strats[i];
            if (s.strategyDisabled[strat] || s.strategyBroken[strat]) continue;

            uint256 target = (totalAssets * s.strategyWeightBps[strat]) / BPS_DENOMINATOR;
            uint256 current = s.strategyLastValue[strat];
            if (current >= target) continue;

            uint256 gap = target - current;
            uint256 toDeploy = gap < available ? gap : available;
            if (toDeploy == 0) continue;

            LibStrategyRegistry.investInto(strat, toDeploy);
            available -= toDeploy;
        }

        LibVaultNav.refreshNav();
        emit Rebalanced(totalAssets, s.idleBalance);
    }

    // ─────────────────────────────── internal ───────────────────────────────────

    /// @dev Harvest every active strategy, crediting realized base into idle. When
    ///      `hardRevert` is true (rebalance), a harvest failure reverts the whole
    ///      call; otherwise (harvestAll) a failure just skips that strategy.
    function _harvestAll(VaultStorage.Layout storage s, bool hardRevert) private {
        address[] storage strats = s.strategies;
        uint256 n = strats.length;
        for (uint256 i; i < n; i++) {
            address strat = strats[i];
            if (s.strategyBroken[strat]) continue;
            (bool ok, uint256 realized) = LibStrategyRegistry.harvestInto(strat);
            if (ok) {
                emit StrategyHarvested(strat, realized);
            } else if (hardRevert) {
                revert("HARVEST_FAILED");
            }
        }
    }
}
