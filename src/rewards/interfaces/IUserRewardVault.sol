// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IUserRewardSystem.sol";

/**
 * @title  IUserRewardVault
 * @notice Full external surface of the deployed UserRewardVault (extends the
 *         registry surface). This is the interface the Artha vault layer imports
 *         to drive deposits/withdrawals/transfers, and that users call to claim.
 *
 *  KEYED BY (VAULT ADDRESS, POSITION ID). One base token can back several vaults,
 *  each with its own rewardRatio. Reward for a (vault, position) is:
 *      (principalNorm * rewardRatio[vault]) / 1e18 per YEAR,
 *  with YEAR = 360 days and rewardRatio capped at 1e18.
 *
 *  Principal is keyed by POSITION, not by user address, because anyone may
 *  deposit into a position but only the owner may withdraw -- address-keying
 *  would let a withdrawal underflow one balance while leaving phantom principal
 *  on another. ARTHA is credited to the position's OWNER at settle time and
 *  banked into a per-USER balance, so claiming is one transaction.
 *
 *  Caller sites (msg.sender must be an approved caller AND equal `vault`):
 *     - deposit  -> notifyDeposit(vault, tokenId, owner, rawPrincipal)
 *     - withdraw -> notifyWithdraw(vault, tokenId, owner, basisUsed)
 *     - transfer -> notifyTransfer(vault, tokenId, from, to)
 *
 *  Anyone may sync() to bank a position's pending into claimable `earned`
 *  without claiming. Ratio changes are non-retroactive and never overpay, so
 *  correctness does not depend on who (if anyone) calls sync.
 */
interface IUserRewardVault is IUserRewardSystem {
    // ─────────────────────────── constants (getters) ────────────────────────────
    function ACC() external view returns (uint256);
    function YEAR() external view returns (uint256);
    function RATIO_ONE() external view returns (uint256);
    function artha() external view returns (address);

    // ─────────────────────────── vault config / books ───────────────────────────
    /// @return registered         whether the vault is active
    /// @return decimals           base-token decimals
    /// @return rewardRatio        per-vault rate (0..1e18). ZERO => no rewards.
    /// @return scale              10^(18 - decimals)
    /// @return accArthaPerPrincipal MasterChef accumulator, scaled by ACC
    /// @return lastUpdate         timestamp the accumulator last advanced
    /// @return totalPrincipalNorm live principal across all positions, 18dp
    /// @return totalArthaEarned   cumulative ARTHA credited for this vault
    /// @return totalArthaClaimed  cumulative ARTHA claimed from this vault
    function vaultMeta(address vault)
        external
        view
        returns (
            bool registered,
            uint8 decimals,
            uint256 rewardRatio,
            uint256 scale,
            uint256 accArthaPerPrincipal,
            uint256 lastUpdate,
            uint256 totalPrincipalNorm,
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
            uint256 principalNorm,
            uint256 arthaEarned,
            uint256 arthaClaimed,
            uint256 arthaOutstanding
        );

    // ─────────────────────────── position accounts ──────────────────────────────
    /// @return balanceNorm live principal for this (vault, tokenId), 18dp
    /// @return rewardDebt  checkpoint = balanceNorm * acc / ACC at last settle
    function positionAccount(address vault, uint256 tokenId)
        external
        view
        returns (uint256 balanceNorm, uint256 rewardDebt);

    function positionPrincipalRaw(address vault, uint256 tokenId) external view returns (uint256);

    // ─────────────────────────── footprints ─────────────────────────────────────
    function vaultPositions(address vault, uint256 index) external view returns (uint256);
    function vaultHasPosition(address vault, uint256 tokenId) external view returns (bool);
    function vaultPositionsCount(address vault) external view returns (uint256);

    function userPositions(address user, uint256 index) external view returns (address vault, uint256 tokenId);
    function userHasPosition(address user, address vault, uint256 tokenId) external view returns (bool);
    function userPositionsCount(address user) external view returns (uint256);
    function userPositionAt(address user, uint256 index) external view returns (address vault, uint256 tokenId);

    // ─────────────────────────── user ledgers ───────────────────────────────────
    function totalEarned(address user) external view returns (uint256);
    function claimed(address user) external view returns (uint256);
    function earnedByVault(address vault, address user) external view returns (uint256);
    function earnedByPosition(address vault, uint256 tokenId) external view returns (uint256);

    // ─────────────────────────── pool-wide totals ───────────────────────────────
    function maxDistributable() external view returns (uint256);
    function totalDistributed() external view returns (uint256);
    function totalClaimed() external view returns (uint256);
    function remainingPool() external view returns (uint256);
    function outstandingLiability() external view returns (uint256);
    function isSolvent() external view returns (bool);

    // ─────────────────────────── configuration (governance) ─────────────────────
    function registerVault(address vault, uint8 decimals, uint256 rewardRatio_) external;
    function setRewardRatio(address vault, uint256 newRatio) external;
    function stopAll(address[] calldata vaults) external;
    function setCap(uint256 cap) external;

    // ─────────────────────────── hooks (approved caller) ────────────────────────
    function notifyDeposit(address vault, uint256 tokenId, address owner, uint256 rawPrincipal) external;
    function notifyWithdraw(address vault, uint256 tokenId, address owner, uint256 rawPrincipal) external;
    function notifyTransfer(address vault, uint256 tokenId, address from, address to) external;

    // ─────────────────────────── permissionless sync ────────────────────────────
    function sync(address vault, uint256 tokenId, address owner) external;
    function syncAllPositions(address vault, address[] calldata owners) external;

    // ─────────────────────────── claims ─────────────────────────────────────────
    function claim(address to, uint256 amount) external;
    function claimAll(address to) external returns (uint256 amount);
    function claimable(address user) external view returns (uint256);
    function claimableBanked(address user) external view returns (uint256);

    // ─────────────────────────── admin ──────────────────────────────────────────
    function rescue(address token, address to, uint256 amount) external;

    // ─────────────────────────── views ──────────────────────────────────────────
    function pendingReward(address vault, uint256 tokenId) external view returns (uint256);
    function pendingRewardAll(address user) external view returns (uint256);
}
