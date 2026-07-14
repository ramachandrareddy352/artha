// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IReferralSystem.sol";

/**
 * @title  IReferralVault
 * @notice Full external surface of the deployed ReferralVault (extends registry +
 *         manager surfaces). This is the interface the Artha vault layer imports to
 *         drive referred deposits/withdrawals, and that code owners use to claim.
 *
 *  KEYED BY VAULT ADDRESS (not pool, not token). One base token can back several
 *  vaults, each with its own rewardRatio. Reward for a (vault, tier) position
 *  is:  (amountNorm * tierRatio[tier] * rewardRatio[vault]) / 1e36 per YEAR,
 *  with YEAR = 360 days and both ratios capped at 1e18.
 *
 *  Caller sites (msg.sender must be an approved caller = the vault / Diamond):
 *     - referred deposit -> notifyDeposit(vault, investor, rawPrincipal)
 *     - referred exit     -> notifyWithdraw(vault, investor, rawPrincipal)
 *  (The code is resolved from the investor's one-time traderToCode.)
 *
 *  Anyone may sync()/syncAll() to bank a code's pending into claimable `earned`
 *  without claiming. Ratio changes are non-retroactive and never overpay, so
 *  correctness does not depend on who (if anyone) calls sync.
 *
 *  Events are emitted by the implementation and omitted here (see manager note).
 */
interface IReferralVault is IReferralSystem {
    // ─────────────────────────── constants (getters) ────────────────────────────
    function ACC() external view returns (uint256);
    function YEAR() external view returns (uint256);
    function RATIO_ONE() external view returns (uint256);
    function RATIO_SQ() external view returns (uint256);
    function MAX_TIERS() external view returns (uint8);
    function artha() external view returns (address);

    // ─────────────────────────── vault config / books ───────────────────────────
    /// @return registered        whether the vault is active
    /// @return decimals          base-token decimals
    /// @return rewardRatio       per-vault rate (0..1e18)
    /// @return scale             10^(18 - decimals)
    /// @return totalPrincipalRaw live referred principal, raw base-token units
    /// @return totalReferredNorm live referred principal, normalised 18dp
    /// @return totalArthaEarned  cumulative ARTHA credited for this vault
    /// @return totalArthaClaimed cumulative ARTHA claimed from this vault
    function vaultMeta(address vault)
        external
        view
        returns (
            bool registered,
            uint8 decimals,
            uint256 rewardRatio,
            uint256 scale,
            uint256 totalPrincipalRaw,
            uint256 totalReferredNorm,
            uint256 totalArthaEarned,
            uint256 totalArthaClaimed
        );

    function vaultCount() external view returns (uint64);

    /// @notice Convenience read of a vault's books.
    function vaultBooks(address vault)
        external
        view
        returns (
            uint256 rewardRatio_,
            uint256 principalRaw,
            uint256 principalNorm,
            uint256 arthaEarned,
            uint256 arthaClaimed,
            uint256 arthaOutstanding
        );

    // ─────────────────────────── tier ratio-seconds state ───────────────────────
    function tierRatio(uint8 tier) external view returns (uint256);
    function accTierSeconds(uint8 tier) external view returns (uint256);
    function tierLastUpdate(uint8 tier) external view returns (uint256);
    function registeredTiers(uint256 index) external view returns (uint8);
    function tiersCount() external view returns (uint256);

    // ─────────────────────────── lanes & accounts ───────────────────────────────
    /// @return init            whether this (vault,tier) lane has been touched
    /// @return acc             ARTHA-per-normalised-token accumulator (scaled by ACC)
    /// @return tierSecondsMark accTierSeconds[tier] snapshot at last advance
    function lane(address vault, uint8 tier)
        external
        view
        returns (bool init, uint256 acc, uint256 tierSecondsMark);

    /// @return balanceNorm live referred principal for this (vault,code), 18dp
    /// @return rewardDebt  checkpoint = balanceNorm * lane.acc / ACC at last settle
    /// @return earned      settled, claimable ARTHA
    /// @return claimed     lifetime claimed ARTHA
    function codeAccount(address vault, uint64 code)
        external
        view
        returns (uint256 balanceNorm, uint256 rewardDebt, uint256 earned, uint256 claimed);

    // ─────────────────────────── per-code footprint ─────────────────────────────
    function codeVaults(uint64 code, uint256 index) external view returns (address);
    function codeHasVault(uint64 code, address vault) external view returns (bool);
    function codeVaultsCount(uint64 code) external view returns (uint256);

    // ─────────────────────────── vault-wide totals ──────────────────────────────
    function totalEarnedArtha() external view returns (uint256);
    function totalClaimedArtha() external view returns (uint256);

    // ─────────────────────────── configuration (governance) ─────────────────────
    function registerVault(address vault, uint8 decimals, uint256 rewardRatio_) external;
    function setRewardRatio(address vault, uint256 newRatio) external;
    function setTierRatio(uint8 tier, uint256 newRatio) external;
    function setCodeTier(uint64 code, uint8 newTier) external;

    // ─────────────────────────── hooks (approved caller) ────────────────────────
    function notifyDeposit(address vault, address investor, uint256 rawPrincipal) external;
    function notifyWithdraw(address vault, address investor, uint256 rawPrincipal) external;

    // ─────────────────────────── permissionless sync ────────────────────────────
    function sync(address vault, uint64 code) external;
    function syncAll(uint64 code) external;

    // ─────────────────────────── owner claims ───────────────────────────────────
    function claim(address vault, uint64 code, address to, uint256 amount) external;
    function claimAll(uint64 code, address to) external;

    // ─────────────────────────── admin ──────────────────────────────────────────
    function deactivateCode(uint64 code) external;
    function rescue(address token, address to, uint256 amount) external;

    // ─────────────────────────── views ──────────────────────────────────────────
    function pendingReward(address vault, uint64 code) external view returns (uint256);
    function pendingRewardAll(uint64 code) external view returns (uint256);
}
