// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    AppStorage,
    Modifiers,
    BPS_DENOMINATOR,
    MAX_IDLE_BPS,
    MAX_PERFORMANCE_FEE_BPS,
    PPS_SCALE
} from "../libraries/LibAppStorage.sol";
import {LibStrategyRegistry} from "../libraries/LibStrategyRegistry.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";
import {VaultShareToken} from "../VaultShareToken.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title  VaultAdminFacet
 * @notice Every governance action that shapes a vault: creation, strategy
 *         lifecycle (add / reweight / disable / remove / migrate), risk limits,
 *         and fee configuration. Every function here is `onlyGovernance` — the
 *         ArthaTimelock — meaning every call already sat through a public voting
 *         period and the timelock's delay window before it can execute (see
 *         ArthaTimelock.sol's header). Guardian/pause actions live in
 *         VaultEmergencyFacet, deliberately separated from this facet so an
 *         emergency response never needs a multi-day governance proposal.
 */
contract VaultAdminFacet is Modifiers {
    event VaultCreated(
        address indexed vault, address indexed baseAsset, string name, string symbol, uint16 idleTargetBps
    );
    event CapsUpdated(address indexed vault, uint256 tvlCap, uint256 depositCapPerBlock, uint256 withdrawCapPerBlock, uint256 minDeposit);
    event CapExemptSet(address indexed vault, address indexed who, bool exempt);
    event PerformanceFeeSet(address indexed vault, uint16 oldBps, uint16 newBps);
    event StrategyMaxDeltaSet(address indexed vault, uint16 bps);
    event HarvestMaxImpactSet(address indexed vault, uint16 bps);
    event KeeperSet(address indexed who, bool isKeeper);
    event GuardianSet(address indexed who, bool isGuardian);
    event TreasurySet(address oldTreasury, address newTreasury);

    // ═══════════════════════════ vault creation ══════════════════════════════════

    /**
     * @notice Deploy a new vault: its own VaultShareToken, and its full risk
     *         configuration in one call. The vault starts with zero strategies —
     *         `addStrategy` is called separately, up to MAX_STRATEGIES_PER_VAULT
     *         times, once the vault's target portfolio is decided.
     * @dev    `highWaterMarkPps` starts at PPS_SCALE (1.0) — the performance fee
     *         only ever charges on growth ABOVE the starting price, never on the
     *         initial 1:1 price itself.
     */
    function createVault(
        address baseAsset,
        string calldata name,
        string calldata symbol,
        uint16 idleTargetBps,
        uint256 minDeposit,
        uint256 tvlCap,
        uint256 depositCapPerBlock,
        uint256 withdrawCapPerBlock,
        uint16 performanceFeeBps,
        uint16 strategyMaxDeltaBps,
        uint16 harvestMaxImpactBps
    ) external onlyGovernance returns (address vault) {
        require(baseAsset != address(0), "ZERO_ADDRESS");
        require(idleTargetBps <= MAX_IDLE_BPS, "IDLE_TOO_HIGH");
        require(performanceFeeBps <= MAX_PERFORMANCE_FEE_BPS, "FEE_TOO_HIGH");
        // strategyMaxDeltaBps == 0 means the NAV circuit breaker (LibVaultNav) is
        // OFF for this vault. That must never be an accident of a governance call
        // that simply forgot the parameter — require a deliberate, explicit
        // choice. To genuinely run without a breaker, set BPS_DENOMINATOR (any
        // reading passes), not 0.
        require(strategyMaxDeltaBps != 0 && strategyMaxDeltaBps <= BPS_DENOMINATOR, "INVALID_MAX_DELTA");

        VaultShareToken token = new VaultShareToken(address(this), name, symbol);
        vault = address(token);

        s.isVault[vault] = true;
        s.allVaults.push(vault);

        s.baseAsset[vault] = baseAsset;
        s.baseDecimals[vault] = IERC20Metadata(baseAsset).decimals();
        s.idleTargetBps[vault] = idleTargetBps;
        s.minDeposit[vault] = minDeposit;
        s.tvlCap[vault] = tvlCap;
        s.depositCapPerBlock[vault] = depositCapPerBlock;
        s.withdrawCapPerBlock[vault] = withdrawCapPerBlock;
        s.performanceFeeBps[vault] = performanceFeeBps;
        s.strategyMaxDeltaBps[vault] = strategyMaxDeltaBps;
        s.harvestMaxImpactBps[vault] = harvestMaxImpactBps;
        s.highWaterMarkPps[vault] = PPS_SCALE;

        emit VaultCreated(vault, baseAsset, name, symbol, idleTargetBps);
    }

    // ═══════════════════════════ strategy lifecycle ══════════════════════════════

    function addStrategy(
        address vault,
        address strategy,
        address[] calldata allStrategies,
        uint16[] calldata allWeightsBps,
        uint16 idleTargetBps
    ) external onlyGovernance onlyRegisteredVault(vault) nonReentrant {
        LibStrategyRegistry.addStrategy(vault, strategy, allStrategies, allWeightsBps, idleTargetBps);
    }

    /// @notice Update target weights only — does NOT move capital. See
    ///         LibStrategyRegistry's header for why this is decoupled from
    ///         execution, and VaultHarvestFacet.rebalance() for the mandatory
    ///         harvest-before-move step that runs when capital actually shifts.
    function setTargets(
        address vault,
        address[] calldata strategies_,
        uint16[] calldata weightsBps,
        uint16 idleTargetBps
    ) external onlyGovernance onlyRegisteredVault(vault) nonReentrant {
        LibStrategyRegistry.setTargets(vault, strategies_, weightsBps, idleTargetBps);
    }

    function setStrategyDisabled(address vault, address strategy, bool disabled)
        external
        onlyGovernance
        onlyRegisteredVault(vault)
    {
        LibStrategyRegistry.setDisabled(vault, strategy, disabled);
    }

    /// @notice Clear an automatic circuit-break after confirming off-chain that
    ///         the strategy (or its oracle dependency) is actually healthy again.
    function clearStrategyCircuitBreak(address vault, address strategy)
        external
        onlyGovernance
        onlyRegisteredVault(vault)
    {
        LibStrategyRegistry.clearCircuitBreak(vault, strategy);
    }

    function removeStrategy(address vault, address strategy, uint256 dustFloor)
        external
        onlyGovernance
        onlyRegisteredVault(vault)
        nonReentrant
    {
        LibStrategyRegistry.removeStrategy(vault, strategy, dustFloor);
        LibVaultNav.refreshNav(vault);
    }

    function migrateStrategy(address vault, address from, address to)
        external
        onlyGovernance
        onlyRegisteredVault(vault)
        nonReentrant
    {
        LibStrategyRegistry.migrateStrategy(vault, from, to);
        LibVaultNav.refreshNav(vault);
    }

    // ═══════════════════════════ risk limits ══════════════════════════════════════

    function setCaps(
        address vault,
        uint256 tvlCap,
        uint256 depositCapPerBlock,
        uint256 withdrawCapPerBlock,
        uint256 minDeposit
    ) external onlyGovernance onlyRegisteredVault(vault) {
        s.tvlCap[vault] = tvlCap;
        s.depositCapPerBlock[vault] = depositCapPerBlock;
        s.withdrawCapPerBlock[vault] = withdrawCapPerBlock;
        s.minDeposit[vault] = minDeposit;
        emit CapsUpdated(vault, tvlCap, depositCapPerBlock, withdrawCapPerBlock, minDeposit);
    }

    function setCapExempt(address vault, address who, bool exempt) external onlyGovernance onlyRegisteredVault(vault) {
        s.isCapExempt[vault][who] = exempt;
        emit CapExemptSet(vault, who, exempt);
    }

    function setPerformanceFee(address vault, uint16 bps) external onlyGovernance onlyRegisteredVault(vault) {
        require(bps <= MAX_PERFORMANCE_FEE_BPS, "FEE_TOO_HIGH");
        uint16 old = s.performanceFeeBps[vault];
        s.performanceFeeBps[vault] = bps;
        emit PerformanceFeeSet(vault, old, bps);
    }

    /// @dev 0 is rejected — see `createVault`'s header note. Use BPS_DENOMINATOR
    ///      to run without an effective breaker, never 0.
    function setStrategyMaxDeltaBps(address vault, uint16 bps) external onlyGovernance onlyRegisteredVault(vault) {
        require(bps != 0 && bps <= BPS_DENOMINATOR, "INVALID_MAX_DELTA");
        s.strategyMaxDeltaBps[vault] = bps;
        emit StrategyMaxDeltaSet(vault, bps);
    }

    function setHarvestMaxImpactBps(address vault, uint16 bps) external onlyGovernance onlyRegisteredVault(vault) {
        require(bps <= BPS_DENOMINATOR, "INVALID_BPS");
        s.harvestMaxImpactBps[vault] = bps;
        emit HarvestMaxImpactSet(vault, bps);
    }

    // ═══════════════════════════ protocol roles ═══════════════════════════════════

    function setKeeper(address who, bool isKeeper_) external onlyGovernance {
        s.isKeeper[who] = isKeeper_;
        emit KeeperSet(who, isKeeper_);
    }

    /// @dev Guardians are granted here (governance-gated) but can only ever PAUSE —
    ///      see VaultEmergencyFacet for why unpause is deliberately NOT symmetric.
    function setGuardian(address who, bool isGuardian_) external onlyGovernance {
        s.isGuardian[who] = isGuardian_;
        emit GuardianSet(who, isGuardian_);
    }

    function setTreasury(address treasury) external onlyGovernance {
        require(treasury != address(0), "ZERO_ADDRESS");
        emit TreasurySet(s.treasury, treasury);
        s.treasury = treasury;
    }
}
