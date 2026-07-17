// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  IReferralVaultManager
 * @notice Access-control surface of the referral stack (layer 1 of 3).
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault
 */
interface IReferralVaultManager {
    // ─────────────────────────────── events ─────────────────────────────────────

    event ReferralVaultManagerUpdated(address oldManager, address newManager);
    event CallerUpdated(address caller, bool status);

    // ─────────────────────────────── views ──────────────────────────────────────

    /// @notice The admin address (governance timelock in production).
    function referralVaultManager() external view returns (address);

    /// @notice Contracts allowed to drive the referral books (the vault layer).
    function approvedCallers(address caller) external view returns (bool);

    // ─────────────────────────────── admin ──────────────────────────────────────

    function setReferralVaultManager(address newManager) external;

    function setCaller(address caller, bool status) external;

    function pause() external;

    function unpause() external;
}
