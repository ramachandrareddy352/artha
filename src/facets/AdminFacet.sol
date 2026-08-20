// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    VaultStorage,
    VaultModifiers,
    BPS_DENOMINATOR,
    MAX_IDLE_BPS,
    MAX_PERFORMANCE_FEE_BPS,
    MAX_ENTRY_FEE_WEI
} from "../libraries/VaultStorage.sol";
import {LibStrategyRegistry} from "../libraries/LibStrategyRegistry.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";

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
    event GovernanceTransferred(address oldGovernance, address newGovernance);
    event IdleTargetSet(uint16 bps);
    event StrategyConfigured(address indexed strategy, bytes4 selector);
    event EntryFeeSet(uint96 oldWei, uint96 newWei);
    event EthFeesWithdrawn(address indexed to, uint256 amount);

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

    /// @notice Clear a strategy's circuit break, re-anchoring its tracked value to
    ///         `confirmedValue`. The anchor is mandatory — clearing the flag alone
    ///         leaves the very condition that tripped the breaker in place, so the
    ///         next NAV refresh (any user's deposit will do) re-trips it immediately.
    ///         `confirmedValue` is bounded against the strategy's live reading.
    ///
    ///         Does NOT unpause. If the break auto-paused the vault, governance
    ///         unpauses separately via `EmergencyFacet.unpauseVault` once satisfied.
    function clearStrategyCircuitBreak(address strategy, uint256 confirmedValue) external onlyGovernance nonReentrant {
        LibStrategyRegistry.clearCircuitBreak(strategy, confirmedValue);
        LibVaultNav.refreshNav();
    }

    function removeStrategy(address strategy, uint256 dustFloor) external onlyGovernance nonReentrant {
        LibStrategyRegistry.removeStrategy(strategy, dustFloor);
        LibVaultNav.refreshNav();
    }

    function migrateStrategy(address from, address to) external onlyGovernance nonReentrant {
        LibStrategyRegistry.migrateStrategy(from, to);
        LibVaultNav.refreshNav();
    }

    /// @notice Call a CONFIGURATION function on one of this vault's strategies.
    ///
    ///         Every strategy setter — swap routes, reward registrations, rotation
    ///         bands, slippage tolerance, stray-token rescue — is `onlyVault`, because
    ///         the vault is the only party a strategy trusts. Without this forwarder
    ///         there is no way to reach any of them, and a strategy needing a route
    ///         (every rotation and cross-asset strategy does) would be permanently
    ///         unconfigurable.
    ///
    /// @dev    Two bounds make this narrow rather than an arbitrary-call surface:
    ///
    ///         1. `strategy` MUST be registered with this vault, so the call can only
    ///            ever land on code governance already adopted.
    ///         2. The `IStrategy` money-movers are BLOCKED by selector. Those are the
    ///            vault's own accounting operations: calling `divest` from here would
    ///            move base without `LibStrategyRegistry` crediting `idleBalance` or
    ///            decrementing the tracked value, leaving NAV wrong until the next
    ///            `sync`. Capital moves through `deployIdle`/`rebalance`/the withdrawal
    ///            queue, never through here.
    function execOnStrategy(address strategy, bytes calldata data)
        external
        onlyGovernance
        nonReentrant
        returns (bytes memory result)
    {
        require(LibStrategyRegistry.isKnown(strategy), "UNKNOWN_STRATEGY");
        require(data.length >= 4, "BAD_CALLDATA");

        bytes4 selector = bytes4(data[:4]);
        require(
            selector != IStrategy.invest.selector && selector != IStrategy.divest.selector
                && selector != IStrategy.harvest.selector && selector != IStrategy.tend.selector
                && selector != IStrategy.emergencyWithdraw.selector,
            "USE_VAULT_FLOW"
        );

        bool ok;
        (ok, result) = strategy.call(data);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        emit StrategyConfigured(strategy, selector);
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

    /// @notice Change the performance fee. Crystallizes ALL profit accrued so far at
    ///         the OLD rate FIRST (via refreshNav -> chargePerformanceFee, which mints
    ///         the treasury's shares and ratchets the HWM to the current price), then
    ///         applies the new rate — so the new rate can never reach back over old gains.
    function setPerformanceFee(uint16 bps) external onlyGovernance nonReentrant {
        require(bps <= MAX_PERFORMANCE_FEE_BPS, "FEE_TOO_HIGH");
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        LibVaultNav.refreshNav(); // settle at the OLD rate before switching
        uint16 old = s.performanceFeeBps;
        s.performanceFeeBps = bps;
        emit PerformanceFeeSet(old, bps);
    }

    // ═══════════════════════════ native-ETH entry fee ══════════════════════════════

    /// @notice Set the flat ETH toll charged on every deposit/mint. 0 disables it.
    function setEntryFee(uint96 feeWei) external onlyGovernance {
        require(feeWei <= MAX_ENTRY_FEE_WEI, "ENTRY_FEE_TOO_HIGH");
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        emit EntryFeeSet(s.entryFeeWei, feeWei);
        s.entryFeeWei = feeWei;
    }

    /// @notice Withdraw protocol-owned ETH tolls. Bounded by `collectedEthFees` so it
    ///         can NEVER touch user base-asset principal.
    function withdrawEthFees(address to, uint256 amount) external onlyGovernance nonReentrant {
        require(to != address(0), "ZERO_ADDRESS");
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(amount != 0 && amount <= s.collectedEthFees, "BAD_AMOUNT");
        s.collectedEthFees -= uint128(amount);
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH_TRANSFER_FAILED");
        emit EthFeesWithdrawn(to, amount);
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
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        emit GovernanceTransferred(s.governance, newGovernance);
        s.governance = newGovernance;
    }
}
