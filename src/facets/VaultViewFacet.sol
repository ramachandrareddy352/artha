// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage, Modifiers} from "../libraries/LibAppStorage.sol";
import {LibVaultMath} from "../libraries/LibVaultMath.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title  VaultViewFacet
 * @notice Every read a frontend, an integrator, or another protocol needs. All
 *         value reads price against the last CHECKPOINTED NAV (see LibVaultNav's
 *         header for why) — call `settle(vault)` on VaultHarvestFacet first if a
 *         caller specifically needs a just-refreshed number.
 */
contract VaultViewFacet is Modifiers {
    struct VaultConfigView {
        address baseAsset;
        uint8 baseDecimals;
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

    function totalAssets(address vault) external view returns (uint256) {
        return LibVaultNav.cachedTotalAssets(vault);
    }

    function pricePerShare(address vault) external view returns (uint256) {
        return LibVaultMath.pricePerShare(vault);
    }

    function previewDeposit(address vault, uint256 assets) external view returns (uint256) {
        return LibVaultMath.convertToSharesDown(vault, assets);
    }

    function previewMint(address vault, uint256 shares) external view returns (uint256) {
        return LibVaultMath.convertToAssetsUp(vault, shares);
    }

    function previewWithdraw(address vault, uint256 assets) external view returns (uint256) {
        return LibVaultMath.convertToSharesUp(vault, assets);
    }

    function previewRedeem(address vault, uint256 shares) external view returns (uint256) {
        return LibVaultMath.convertToAssetsDown(vault, shares);
    }

    // ═══════════════════════════════ liquidity-bounded maxima ═════════════════════

    /// @notice The most `owner` could withdraw right now: bounded by BOTH their
    ///         own share balance AND the vault's actual available liquidity
    ///         (idle + what every healthy strategy reports it could give up).
    function maxWithdraw(address vault, address owner) external view returns (uint256) {
        uint256 ownerAssets = LibVaultMath.convertToAssetsDown(vault, IERC20(vault).balanceOf(owner));
        uint256 liquidity = _availableLiquidity(vault);
        return ownerAssets < liquidity ? ownerAssets : liquidity;
    }

    function maxRedeem(address vault, address owner) external view returns (uint256) {
        uint256 ownerShares = IERC20(vault).balanceOf(owner);
        uint256 liquidity = _availableLiquidity(vault);
        uint256 liquidityShares = LibVaultMath.convertToSharesDown(vault, liquidity);
        return ownerShares < liquidityShares ? ownerShares : liquidityShares;
    }

    function availableLiquidity(address vault) external view returns (uint256) {
        return _availableLiquidity(vault);
    }

    function _availableLiquidity(address vault) private view returns (uint256 total) {
        total = s.idleBalance[vault];
        address[] storage strats = s.strategies[vault];
        uint256 n = strats.length;
        for (uint256 i; i < n; i++) {
            address strat = strats[i];
            if (s.strategyBroken[vault][strat]) continue;
            total += IStrategy(strat).maxWithdraw();
        }
    }

    // ═══════════════════════════════ config / registry ═══════════════════════════

    function vaultConfig(address vault) external view returns (VaultConfigView memory v) {
        v.baseAsset = s.baseAsset[vault];
        v.baseDecimals = s.baseDecimals[vault];
        v.idleBalance = s.idleBalance[vault];
        v.idleTargetBps = s.idleTargetBps[vault];
        v.minDeposit = s.minDeposit[vault];
        v.tvlCap = s.tvlCap[vault];
        v.depositCapPerBlock = s.depositCapPerBlock[vault];
        v.withdrawCapPerBlock = s.withdrawCapPerBlock[vault];
        v.performanceFeeBps = s.performanceFeeBps[vault];
        v.highWaterMarkPps = s.highWaterMarkPps[vault];
        v.totalAssets = s.navCheckpoint[vault];
        v.totalShares = IERC20(vault).totalSupply();
        v.pricePerShare = LibVaultMath.pricePerShare(vault);
        v.paused = s.vaultPaused[vault] || s.globalPaused;
    }

    function strategyList(address vault) external view returns (address[] memory) {
        return s.strategies[vault];
    }

    function strategyWeightBps(address vault, address strategy) external view returns (uint16) {
        return s.strategyWeightBps[vault][strategy];
    }

    function strategyStatus(address vault, address strategy)
        external
        view
        returns (bool disabled, bool broken, uint256 lastValue)
    {
        disabled = s.strategyDisabled[vault][strategy];
        broken = s.strategyBroken[vault][strategy];
        lastValue = s.strategyLastValue[vault][strategy];
    }

    function allVaults() external view returns (address[] memory) {
        return s.allVaults;
    }

    function isCapExempt(address vault, address who) external view returns (bool) {
        return s.isCapExempt[vault][who];
    }
}
