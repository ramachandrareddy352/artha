// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage, Modifiers, BPS_DENOMINATOR} from "../libraries/LibAppStorage.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  VaultHarvestFacet
 * @notice Everything the keeper (and, for `settle`, anyone) does to keep a vault's
 *         NAV fresh and its capital where it's supposed to be: harvesting
 *         individual strategies, deploying fresh idle capital, and rebalancing
 *         toward target weights.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   harvest() vs harvestAll() — hard-fail vs best-effort
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `harvest(vault, strategy)` targets ONE strategy explicitly and lets a failure
 *  propagate — the keeper asked for this specific strategy to be harvested, so if
 *  it can't be, the keeper's automation should see the revert and react (retry,
 *  alert, investigate), not silently no-op.
 *
 *  `harvestAll(vault)` is the routine sweep across every active strategy and is
 *  best-effort per strategy (a caught failure just skips that one) — one
 *  strategy's temporary swap-slippage issue must never block harvesting every
 *  OTHER healthy strategy in the same batch.
 *
 *  Every strategy's `harvest()` (see BaseStrategy) claims its own reward tokens
 *  and swaps them to base in one atomic call today — there is no on-chain split
 *  between "claim" and "sell" inside a single strategy in this version. What IS
 *  implemented here is orchestration-level resilience: a stuck strategy can never
 *  strand harvesting on any OTHER strategy in the same vault, whether via
 *  `harvestAll`'s per-strategy try/catch or the withdrawal path's best-effort
 *  harvest. A true intra-strategy claim/sell split (claim always succeeds even if
 *  the sell leg fails) would require splitting BaseStrategy's `_harvestRewards`
 *  hook into separate claim/sell hooks across every concrete strategy — a
 *  deliberately scoped-out, documented follow-up (see docs/formulas.md), not
 *  silently treated as done here.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   settle() — PERMISSIONLESS, no claim, no swap
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Anyone may call `settle` to force a fresh NAV checkpoint (and, if price-per-
 *  share has reached a new peak, crystallize the performance fee — see
 *  LibVaultFee) without waiting for the keeper's next harvest cycle. It touches
 *  no reward tokens and performs no swaps — it only re-reads what each strategy
 *  already reports.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   deployIdle() vs rebalance()
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `deployIdle` is the routine, frequent operation: push idle capital ABOVE the
 *  target buffer into whichever strategies are below their target weight. It
 *  never pulls capital OUT of a strategy, so it does not need the mandatory
 *  pre-move harvest — there is no stale value being reallocated away from.
 *
 *  `rebalance` is the heavier operation that also SHRINKS over-allocated
 *  strategies to fund under-allocated ones. Because it moves capital OUT of
 *  strategies based on their reported value, it harvests every active strategy
 *  FIRST and HARD-REVERTS the whole call if any harvest fails — reallocating
 *  against stale, un-harvested value would mis-price exactly the capital this
 *  function is moving (see LibStrategyRegistry's header for the same invariant
 *  applied to target-weight changes).
 */
contract VaultHarvestFacet is Modifiers {
    using SafeERC20 for IERC20;

    event StrategyHarvested(address indexed vault, address indexed strategy, uint256 realized);
    event IdleDeployed(address indexed vault, address indexed strategy, uint256 amount);
    event Rebalanced(address indexed vault, uint256 totalAssets, uint256 idleAfter);
    event Settled(address indexed vault, uint256 totalAssets);

    // ═══════════════════════════════ harvest ══════════════════════════════════════

    function harvest(address vault, address strategy)
        external
        onlyKeeper
        onlyRegisteredVault(vault)
        nonReentrant
        returns (uint256 realized)
    {
        require(!s.strategyBroken[vault][strategy], "STRATEGY_BROKEN");
        realized = IStrategy(strategy).harvest();
        LibVaultNav.refreshNav(vault);
        emit StrategyHarvested(vault, strategy, realized);
    }

    function harvestAll(address vault) external onlyKeeper onlyRegisteredVault(vault) nonReentrant {
        address[] storage strats = s.strategies[vault];
        uint256 n = strats.length;
        for (uint256 i; i < n; i++) {
            address strat = strats[i];
            if (s.strategyBroken[vault][strat]) continue;
            try IStrategy(strat).harvest() returns (uint256 realized) {
                emit StrategyHarvested(vault, strat, realized);
            } catch {}
        }
        LibVaultNav.refreshNav(vault);
    }

    /// @notice Permissionless NAV checkpoint refresh. No claim, no swap.
    function settle(address vault) external onlyRegisteredVault(vault) nonReentrant {
        uint256 totalAssets = LibVaultNav.refreshNav(vault);
        emit Settled(vault, totalAssets);
    }

    // ═══════════════════════════ capital deployment ═══════════════════════════════

    /// @notice Push idle capital above the target buffer into under-allocated
    ///         strategies, in priority order. Never withdraws from a strategy.
    function deployIdle(address vault)
        external
        onlyKeeper
        onlyRegisteredVault(vault)
        whenVaultNotPaused(vault)
        nonReentrant
    {
        uint256 totalAssets = LibVaultNav.refreshNav(vault);
        uint256 targetIdle = (totalAssets * s.idleTargetBps[vault]) / BPS_DENOMINATOR;
        uint256 idle = s.idleBalance[vault];
        if (idle <= targetIdle) return;

        uint256 available = idle - targetIdle;
        address token = s.baseAsset[vault];
        address[] storage strats = s.strategies[vault];
        uint256 n = strats.length;

        for (uint256 i; i < n && available != 0; i++) {
            address strat = strats[i];
            if (s.strategyDisabled[vault][strat] || s.strategyBroken[vault][strat]) continue;

            uint256 target = (totalAssets * s.strategyWeightBps[vault][strat]) / BPS_DENOMINATOR;
            uint256 current = s.strategyLastValue[vault][strat];
            if (current >= target) continue;

            uint256 gap = target - current;
            uint256 toDeploy = gap < available ? gap : available;
            if (toDeploy == 0) continue;

            IERC20(token).forceApprove(strat, toDeploy);
            IStrategy(strat).deposit(toDeploy);

            s.idleBalance[vault] -= toDeploy;
            s.strategyLastValue[vault][strat] = current + toDeploy;
            available -= toDeploy;

            emit IdleDeployed(vault, strat, toDeploy);
        }
    }

    /// @notice Bring actual allocation back in line with target weights: harvest
    ///         everything first (hard revert on failure), pull excess out of
    ///         over-allocated strategies into idle, then deploy the surplus into
    ///         under-allocated strategies.
    function rebalance(address vault)
        external
        onlyKeeper
        onlyRegisteredVault(vault)
        whenVaultNotPaused(vault)
        nonReentrant
    {
        address[] storage strats = s.strategies[vault];
        uint256 n = strats.length;

        for (uint256 i; i < n; i++) {
            address strat = strats[i];
            if (s.strategyBroken[vault][strat]) continue;
            try IStrategy(strat).harvest() {} catch {
                revert("HARVEST_FAILED");
            }
        }

        uint256 totalAssets = LibVaultNav.refreshNav(vault);
        address token = s.baseAsset[vault];

        // pass 1: pull excess out of over-allocated strategies
        for (uint256 i; i < n; i++) {
            address strat = strats[i];
            if (s.strategyBroken[vault][strat]) continue;

            uint256 target = (totalAssets * s.strategyWeightBps[vault][strat]) / BPS_DENOMINATOR;
            uint256 current = s.strategyLastValue[vault][strat];
            if (current <= target) continue;

            uint256 excess = current - target;
            uint256 freed = IStrategy(strat).withdraw(excess);
            s.idleBalance[vault] += freed;
            s.strategyLastValue[vault][strat] = current - freed;
        }

        // pass 2: deploy surplus into under-allocated strategies
        uint256 targetIdle = (totalAssets * s.idleTargetBps[vault]) / BPS_DENOMINATOR;
        uint256 idle = s.idleBalance[vault];
        uint256 available = idle > targetIdle ? idle - targetIdle : 0;

        for (uint256 i; i < n && available != 0; i++) {
            address strat = strats[i];
            if (s.strategyDisabled[vault][strat] || s.strategyBroken[vault][strat]) continue;

            uint256 target = (totalAssets * s.strategyWeightBps[vault][strat]) / BPS_DENOMINATOR;
            uint256 current = s.strategyLastValue[vault][strat];
            if (current >= target) continue;

            uint256 gap = target - current;
            uint256 toDeploy = gap < available ? gap : available;
            if (toDeploy == 0) continue;

            IERC20(token).forceApprove(strat, toDeploy);
            IStrategy(strat).deposit(toDeploy);

            s.idleBalance[vault] -= toDeploy;
            s.strategyLastValue[vault][strat] = current + toDeploy;
            available -= toDeploy;
        }

        LibVaultNav.refreshNav(vault);
        emit Rebalanced(vault, totalAssets, s.idleBalance[vault]);
    }
}
