// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    VaultStorage,
    PPS_SCALE,
    DECIMALS_OFFSET,
    MAX_IDLE_BPS,
    MAX_PERFORMANCE_FEE_BPS,
    MAX_ENTRY_FEE_WEI,
    BPS_DENOMINATOR
} from "./libraries/VaultStorage.sol";
import {VaultShareToken} from "./VaultShareToken.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {DepositFacet} from "./facets/DepositFacet.sol";
import {WithdrawFacet} from "./facets/WithdrawFacet.sol";
import {StrategyFacet} from "./facets/StrategyFacet.sol";
import {AdminFacet} from "./facets/AdminFacet.sol";
import {EmergencyFacet} from "./facets/EmergencyFacet.sol";
import {ViewFacet} from "./facets/ViewFacet.sol";

/**
 * @title  Vault  —  per-vault router AND custodian
 * @notice One `Vault` is deployed per base asset. It is BOTH:
 *
 *   1. The ROUTER — it registers each facet's selectors in its own namespaced
 *      storage and `fallback()`-delegatecalls into them.
 *      Every vault has its OWN `VaultStorage.Layout` at a fixed keccak slot, so
 *      two vaults never share state and custody is never commingled.
 *
 *   2. The CUSTODIAN — it holds the base asset (idle) AND every DeFi receipt
 *      (aTokens, ERC-4626 shares, LP/gauge positions, venue-internal balances
 *      credited to it). Strategies are stateless executors that only ever move
 *      value between the venue and THIS vault.
 *
 *  Facet logic contracts are deployed ONCE and shared by every vault instance
 *  (they run in the caller's storage via delegatecall), so N vaults reuse the
 *  same facet addresses.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE HIGH-WATER MARK IS SEEDED AT THE GENESIS PRICE-PER-SHARE
 *  ═══════════════════════════════════════════════════════════════════════════
 *  The natural post-first-deposit price-per-share is `PPS_SCALE/10^DECIMALS_OFFSET`
 *  (not `PPS_SCALE`), so the mark is seeded there — otherwise the performance fee
 *  could never crystallize.
 */
contract Vault {
    struct InitConfig {
        address baseAsset;
        address governance;
        address treasury; // performance fee recipient
        address keeper; // initial keeper, address(0) to skip
        address guardian; // initial guardian, address(0) to skip
        uint16 idleTargetBps;
        uint16 performanceFeeBps;
        uint16 strategyMaxDeltaBps;
        uint16 harvestMaxImpactBps;
        uint96 entryFeeWei; // flat native-ETH toll per deposit/mint; 0 = disabled
        uint256 minDeposit; // in terms of base asset, not shares
        uint256 tvlCap;
        uint256 depositCapPerBlock;
        uint256 withdrawCapPerBlock;
        string name;
        string symbol;
    }

    struct Facets {
        address deposit;
        address withdraw;
        address strategy;
        address admin;
        address emergency;
        address view_;
    }

    event VaultInitialized(address indexed shareToken, address indexed baseAsset, address governance);
    event FacetSet(bytes4 selector, address facet);

    modifier onlyGovernance() {
        require(msg.sender == VaultStorage.vaultLayout().governance, "NOT_GOVERNANCE");
        _;
    }

    constructor(InitConfig memory c, Facets memory f) {
        require(c.baseAsset != address(0), "ZERO_ADDRESS");
        require(c.governance != address(0), "ZERO_GOV");
        require(c.idleTargetBps <= MAX_IDLE_BPS, "IDLE_TOO_HIGH");
        require(c.performanceFeeBps <= MAX_PERFORMANCE_FEE_BPS, "FEE_TOO_HIGH");
        require(c.strategyMaxDeltaBps != 0 && c.strategyMaxDeltaBps <= BPS_DENOMINATOR, "INVALID_MAX_DELTA");
        require(c.harvestMaxImpactBps <= BPS_DENOMINATOR, "INVALID_BPS");
        // Flow caps are tracked in a uint192-packed slot; bound the setters so the
        // cumulative downcast can never truncate (trivially true for any real cap).
        require(c.depositCapPerBlock <= type(uint192).max && c.withdrawCapPerBlock <= type(uint192).max, "CAP_TOO_HIGH");
        require(c.entryFeeWei <= MAX_ENTRY_FEE_WEI, "ENTRY_FEE_TOO_HIGH");

        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(!s.initialized, "ALREADY_INIT");
        s.initialized = true;
        s.reentrancyStatus = 1; // OZ-style: seed to "not entered" so the lock stays nonzero

        VaultShareToken token = new VaultShareToken(address(this), c.name, c.symbol);
        s.shareToken = address(token);

        s.baseAsset = c.baseAsset;
        s.baseDecimals = IERC20Metadata(c.baseAsset).decimals();
        s.governance = c.governance;
        s.treasury = c.treasury;
        s.idleTargetBps = c.idleTargetBps;
        s.minDeposit = c.minDeposit;
        s.tvlCap = c.tvlCap;
        s.depositCapPerBlock = c.depositCapPerBlock;
        s.withdrawCapPerBlock = c.withdrawCapPerBlock;
        s.performanceFeeBps = c.performanceFeeBps;
        s.strategyMaxDeltaBps = c.strategyMaxDeltaBps;
        s.harvestMaxImpactBps = c.harvestMaxImpactBps;
        s.entryFeeWei = c.entryFeeWei;

        // Seed the mark at the genesis price-per-share (see contract header).
        s.highWaterMarkPps = PPS_SCALE / (10 ** DECIMALS_OFFSET);

        if (c.keeper != address(0)) s.isKeeper[c.keeper] = true;
        if (c.guardian != address(0)) s.isGuardian[c.guardian] = true;

        _registerFacets(s, f);

        emit VaultInitialized(address(token), c.baseAsset, c.governance);
    }

    // ═══════════════════════════ selector registration ════════════════════════════

    function _registerFacets(VaultStorage.Layout storage s, Facets memory f) private {
        // DepositFacet
        s.selectorToFacet[DepositFacet.deposit.selector] = f.deposit;
        s.selectorToFacet[DepositFacet.mint.selector] = f.deposit;

        // WithdrawFacet
        s.selectorToFacet[WithdrawFacet.withdraw.selector] = f.withdraw;
        s.selectorToFacet[WithdrawFacet.redeem.selector] = f.withdraw;

        // StrategyFacet
        s.selectorToFacet[StrategyFacet.harvest.selector] = f.strategy;
        s.selectorToFacet[StrategyFacet.harvestAll.selector] = f.strategy;
        s.selectorToFacet[StrategyFacet.settle.selector] = f.strategy;
        s.selectorToFacet[StrategyFacet.deployIdle.selector] = f.strategy;
        s.selectorToFacet[StrategyFacet.rebalance.selector] = f.strategy;

        // AdminFacet
        s.selectorToFacet[AdminFacet.addStrategy.selector] = f.admin;
        s.selectorToFacet[AdminFacet.setTargets.selector] = f.admin;
        s.selectorToFacet[AdminFacet.setStrategyDisabled.selector] = f.admin;
        s.selectorToFacet[AdminFacet.clearStrategyCircuitBreak.selector] = f.admin;
        s.selectorToFacet[AdminFacet.removeStrategy.selector] = f.admin;
        s.selectorToFacet[AdminFacet.migrateStrategy.selector] = f.admin;
        s.selectorToFacet[AdminFacet.setCaps.selector] = f.admin;
        s.selectorToFacet[AdminFacet.setCapExempt.selector] = f.admin;
        s.selectorToFacet[AdminFacet.setIdleTargetBps.selector] = f.admin;
        s.selectorToFacet[AdminFacet.setPerformanceFee.selector] = f.admin;
        s.selectorToFacet[AdminFacet.setStrategyMaxDeltaBps.selector] = f.admin;
        s.selectorToFacet[AdminFacet.setHarvestMaxImpactBps.selector] = f.admin;
        s.selectorToFacet[AdminFacet.setKeeper.selector] = f.admin;
        s.selectorToFacet[AdminFacet.setGuardian.selector] = f.admin;
        s.selectorToFacet[AdminFacet.setTreasury.selector] = f.admin;
        s.selectorToFacet[AdminFacet.transferGovernance.selector] = f.admin;
        s.selectorToFacet[AdminFacet.setEntryFee.selector] = f.admin;
        s.selectorToFacet[AdminFacet.withdrawEthFees.selector] = f.admin;

        // EmergencyFacet
        s.selectorToFacet[EmergencyFacet.pauseVault.selector] = f.emergency;
        s.selectorToFacet[EmergencyFacet.unpauseVault.selector] = f.emergency;
        s.selectorToFacet[EmergencyFacet.sync.selector] = f.emergency;
        s.selectorToFacet[EmergencyFacet.emergencyWithdraw.selector] = f.emergency;

        // ViewFacet
        s.selectorToFacet[ViewFacet.totalAssets.selector] = f.view_;
        s.selectorToFacet[ViewFacet.pricePerShare.selector] = f.view_;
        s.selectorToFacet[ViewFacet.previewDeposit.selector] = f.view_;
        s.selectorToFacet[ViewFacet.previewMint.selector] = f.view_;
        s.selectorToFacet[ViewFacet.previewWithdraw.selector] = f.view_;
        s.selectorToFacet[ViewFacet.previewRedeem.selector] = f.view_;
        s.selectorToFacet[ViewFacet.maxWithdraw.selector] = f.view_;
        s.selectorToFacet[ViewFacet.maxRedeem.selector] = f.view_;
        s.selectorToFacet[ViewFacet.availableLiquidity.selector] = f.view_;
        s.selectorToFacet[ViewFacet.vaultConfig.selector] = f.view_;
        s.selectorToFacet[ViewFacet.strategyList.selector] = f.view_;
        s.selectorToFacet[ViewFacet.strategyWeightBps.selector] = f.view_;
        s.selectorToFacet[ViewFacet.strategyStatus.selector] = f.view_;
        s.selectorToFacet[ViewFacet.isKeeper.selector] = f.view_;
        s.selectorToFacet[ViewFacet.isGuardian.selector] = f.view_;
        s.selectorToFacet[ViewFacet.isCapExempt.selector] = f.view_;
        s.selectorToFacet[ViewFacet.governance.selector] = f.view_;
        s.selectorToFacet[ViewFacet.treasury.selector] = f.view_;
        s.selectorToFacet[ViewFacet.entryFeeWei.selector] = f.view_;
        s.selectorToFacet[ViewFacet.collectedEthFees.selector] = f.view_;
    }

    // ═══════════════════════════ upgrades ═════════════════════════════════════════

    /// @notice Re-point a selector to a new facet (add/replace/remove). Governance
    ///         only — the single way this vault's logic ever changes.
    function setFacet(bytes4 selector, address facet) external onlyGovernance {
        VaultStorage.vaultLayout().selectorToFacet[selector] = facet;
        emit FacetSet(selector, facet);
    }

    function facetOf(bytes4 selector) external view returns (address) {
        return VaultStorage.vaultLayout().selectorToFacet[selector];
    }

    function shareToken() external view returns (address) {
        return VaultStorage.vaultLayout().shareToken;
    }

    // ═══════════════════════════ router ═══════════════════════════════════════════

    fallback() external payable {
        address facet = VaultStorage.vaultLayout().selectorToFacet[msg.sig];
        require(facet != address(0), "FUNCTION_NOT_FOUND");

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}
