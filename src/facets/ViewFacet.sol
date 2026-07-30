// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStorage, VaultModifiers} from "../libraries/VaultStorage.sol";
import {LibVaultMath} from "../libraries/LibVaultMath.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title  ViewFacet
 * @notice Every read a frontend or integrator needs. All value reads price against
 *         the last CHECKPOINTED NAV — call `settle()` (StrategyFacet) first for a
 *         just-refreshed number.
 */
contract ViewFacet is VaultModifiers {
    struct VaultConfigView {
        address baseAsset;
        uint8 baseDecimals;
        address shareToken;
        uint256 idleBalance;
        uint16 idleTargetBps;
        uint256 minDeposit;
        uint256 tvlCap;
        uint256 depositCapPerBlock;
        uint256 withdrawCapPerBlock;
        uint16 performanceFeeBps;
        uint256 highWaterMarkPps;
        uint256 totalAssets;
        uint256 totalShares;
        uint256 pricePerShare;
        bool paused;
    }

    // ═══════════════════════════════ core pricing ═════════════════════════════════

    function totalAssets() external view returns (uint256) {
        return LibVaultNav.cachedTotalAssets();
    }

    function pricePerShare() external view returns (uint256) {
        return LibVaultMath.pricePerShare();
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return LibVaultMath.convertToSharesDown(assets);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return LibVaultMath.convertToAssetsUp(shares);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return LibVaultMath.convertToSharesUp(assets);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return LibVaultMath.convertToAssetsDown(shares);
    }

    // ═══════════════════════════════ liquidity-bounded maxima ═════════════════════

    function maxWithdraw(address owner) external view returns (uint256) {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        uint256 ownerAssets = LibVaultMath.convertToAssetsDown(IERC20(s.shareToken).balanceOf(owner));
        uint256 liquidity = _availableLiquidity(s);
        return ownerAssets < liquidity ? ownerAssets : liquidity;
    }

    function maxRedeem(address owner) external view returns (uint256) {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        uint256 ownerShares = IERC20(s.shareToken).balanceOf(owner);
        uint256 liquidityShares = LibVaultMath.convertToSharesDown(_availableLiquidity(s));
        return ownerShares < liquidityShares ? ownerShares : liquidityShares;
    }

    function availableLiquidity() external view returns (uint256) {
        return _availableLiquidity(VaultStorage.vaultLayout());
    }

    function _availableLiquidity(VaultStorage.Layout storage s) private view returns (uint256 total) {
        total = s.idleBalance;
        address[] storage strats = s.strategies;
        uint256 n = strats.length;
        for (uint256 i; i < n; i++) {
            address strat = strats[i];
            if (s.strategyBroken[strat]) continue;
            total += IStrategy(strat).maxWithdraw();
        }
    }

    // ═══════════════════════════════ config / registry ════════════════════════════

    function vaultConfig() external view returns (VaultConfigView memory v) {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        v.baseAsset = s.baseAsset;
        v.baseDecimals = s.baseDecimals;
        v.shareToken = s.shareToken;
        v.idleBalance = s.idleBalance;
        v.idleTargetBps = s.idleTargetBps;
        v.minDeposit = s.minDeposit;
        v.tvlCap = s.tvlCap;
        v.depositCapPerBlock = s.depositCapPerBlock;
        v.withdrawCapPerBlock = s.withdrawCapPerBlock;
        v.performanceFeeBps = s.performanceFeeBps;
        v.highWaterMarkPps = s.highWaterMarkPps;
        v.totalAssets = s.navCheckpoint;
        v.totalShares = IERC20(s.shareToken).totalSupply();
        v.pricePerShare = LibVaultMath.pricePerShare();
        v.paused = s.paused;
    }

    function strategyList() external view returns (address[] memory) {
        return VaultStorage.vaultLayout().strategies;
    }

    function strategyWeightBps(address strategy) external view returns (uint16) {
        return VaultStorage.vaultLayout().strategyWeightBps[strategy];
    }

    function strategyStatus(address strategy) external view returns (bool disabled, bool broken, uint256 lastValue) {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        disabled = s.strategyDisabled[strategy];
        broken = s.strategyBroken[strategy];
        lastValue = s.strategyLastValue[strategy];
    }

    function isKeeper(address who) external view returns (bool) {
        return VaultStorage.vaultLayout().isKeeper[who];
    }

    function isGuardian(address who) external view returns (bool) {
        return VaultStorage.vaultLayout().isGuardian[who];
    }

    function isCapExempt(address who) external view returns (bool) {
        return VaultStorage.vaultLayout().isCapExempt[who];
    }

    function governance() external view returns (address) {
        return VaultStorage.vaultLayout().governance;
    }

    function treasury() external view returns (address) {
        return VaultStorage.vaultLayout().treasury;
    }

    /// @notice The flat native-ETH toll charged per deposit/mint (0 = disabled).
    function entryFeeWei() external view returns (uint256) {
        return VaultStorage.vaultLayout().entryFeeWei;
    }

    /// @notice Protocol-owned ETH collected from tolls, withdrawable by governance.
    function collectedEthFees() external view returns (uint256) {
        return VaultStorage.vaultLayout().collectedEthFees;
    }
}
