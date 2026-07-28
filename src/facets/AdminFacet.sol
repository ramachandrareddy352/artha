// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    VaultStorage,
    VaultModifiers,
    BPS_DENOMINATOR,
    MAX_IDLE_BPS,
    MAX_PERFORMANCE_FEE_BPS
} from "../libraries/VaultStorage.sol";
import {LibStrategyRegistry} from "../libraries/LibStrategyRegistry.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";

/**
 * @title  AdminFacet
 * @notice Every governance action that shapes this vault: strategy lifecycle
 *         (add / reweight / disable / remove / migrate), risk limits, fees, and
 *         roles. Every function is `onlyGovernance` (the ArthaTimelock). Vault
 *         creation/initialization happens in the `Vault` constructor.
 */
contract AdminFacet is VaultModifiers {
    event CapsUpdated(uint256 tvlCap, uint256 depositCapPerBlock, uint256 withdrawCapPerBlock, uint256 minDeposit);
    event CapExemptSet(address indexed who, bool exempt);
    event PerformanceFeeSet(uint16 oldBps, uint16 newBps);
    event StrategyMaxDeltaSet(uint16 bps);
    event HarvestMaxImpactSet(uint16 bps);
    event KeeperSet(address indexed who, bool isKeeper);
    event GuardianSet(address indexed who, bool isGuardian);
    event TreasurySet(address oldTreasury, address newTreasury);
    event IdleTargetSet(uint16 bps);

    // ═══════════════════════════ strategy lifecycle ══════════════════════════════

    function addStrategy(
        address strategy,
        address[] calldata allStrategies,
        uint16[] calldata allWeightsBps,
        uint16 idleTargetBps
    ) external onlyGovernance nonReentrant {
        LibStrategyRegistry.addStrategy(strategy, allStrategies, allWeightsBps, idleTargetBps);
    }

    function setTargets(address[] calldata strategies_, uint16[] calldata weightsBps, uint16 idleTargetBps)
        external
        onlyGovernance
        nonReentrant
    {
        LibStrategyRegistry.setTargets(strategies_, weightsBps, idleTargetBps);
    }

    function setStrategyDisabled(address strategy, bool disabled) external onlyGovernance {
        LibStrategyRegistry.setDisabled(strategy, disabled);
    }

    function clearStrategyCircuitBreak(address strategy) external onlyGovernance {
        LibStrategyRegistry.clearCircuitBreak(strategy);
    }

    function removeStrategy(address strategy, uint256 dustFloor) external onlyGovernance nonReentrant {
        LibStrategyRegistry.removeStrategy(strategy, dustFloor);
        LibVaultNav.refreshNav();
    }

    function migrateStrategy(address from, address to) external onlyGovernance nonReentrant {
        LibStrategyRegistry.migrateStrategy(from, to);
        LibVaultNav.refreshNav();
    }

    // ═══════════════════════════ risk limits ══════════════════════════════════════

    function setCaps(uint256 tvlCap, uint256 depositCapPerBlock, uint256 withdrawCapPerBlock, uint256 minDeposit)
        external
        onlyGovernance
    {
        // Flow caps live in a uint192-packed slot — bound them so the cumulative
        // downcast in LibVaultCap can never truncate.
        require(depositCapPerBlock <= type(uint192).max && withdrawCapPerBlock <= type(uint192).max, "CAP_TOO_HIGH");
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        s.tvlCap = tvlCap;
        s.depositCapPerBlock = depositCapPerBlock;
        s.withdrawCapPerBlock = withdrawCapPerBlock;
        s.minDeposit = minDeposit;
        emit CapsUpdated(tvlCap, depositCapPerBlock, withdrawCapPerBlock, minDeposit);
    }

    function setCapExempt(address who, bool exempt) external onlyGovernance {
        VaultStorage.vaultLayout().isCapExempt[who] = exempt;
        emit CapExemptSet(who, exempt);
    }

    function setIdleTargetBps(uint16 bps) external onlyGovernance {
        require(bps <= MAX_IDLE_BPS, "IDLE_TOO_HIGH");
        VaultStorage.vaultLayout().idleTargetBps = bps;
        emit IdleTargetSet(bps);
    }

    function setPerformanceFee(uint16 bps) external onlyGovernance {
        require(bps <= MAX_PERFORMANCE_FEE_BPS, "FEE_TOO_HIGH");
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        uint16 old = s.performanceFeeBps;
        s.performanceFeeBps = bps;
        emit PerformanceFeeSet(old, bps);
    }

    /// @dev 0 is rejected — 0 would silently disable the breaker. Use
    ///      BPS_DENOMINATOR to run without an effective breaker, never 0.
    function setStrategyMaxDeltaBps(uint16 bps) external onlyGovernance {
        require(bps != 0 && bps <= BPS_DENOMINATOR, "INVALID_MAX_DELTA");
        VaultStorage.vaultLayout().strategyMaxDeltaBps = bps;
        emit StrategyMaxDeltaSet(bps);
    }

    function setHarvestMaxImpactBps(uint16 bps) external onlyGovernance {
        require(bps <= BPS_DENOMINATOR, "INVALID_BPS");
        VaultStorage.vaultLayout().harvestMaxImpactBps = bps;
        emit HarvestMaxImpactSet(bps);
    }

    // ═══════════════════════════ roles ════════════════════════════════════════════

    function setKeeper(address who, bool isKeeper_) external onlyGovernance {
        VaultStorage.vaultLayout().isKeeper[who] = isKeeper_;
        emit KeeperSet(who, isKeeper_);
    }

    function setGuardian(address who, bool isGuardian_) external onlyGovernance {
        VaultStorage.vaultLayout().isGuardian[who] = isGuardian_;
        emit GuardianSet(who, isGuardian_);
    }

    function setTreasury(address treasury) external onlyGovernance {
        require(treasury != address(0), "ZERO_ADDRESS");
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        emit TreasurySet(s.treasury, treasury);
        s.treasury = treasury;
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        require(newGovernance != address(0), "ZERO_ADDRESS");
        VaultStorage.vaultLayout().governance = newGovernance;
    }
}
