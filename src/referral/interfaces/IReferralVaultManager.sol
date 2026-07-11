// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  IReferralVaultManager
 * @notice Admin / access-control surface of the referral stack (first layer).
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault
 *
 *  Roles:
 *   - referralVaultManager : the admin (Governance Timelock in production).
 *   - approvedCallers      : contracts allowed to push the notify* hooks (the
 *                            Artha vault layer / the Diamond).
 *
 *  Events are emitted by the implementation; they are intentionally omitted here
 *  so a contract may `is IReferralVaultManager` without duplicate-event clashes.
 */
interface IReferralVaultManager {
    // ---- state getters ----
    function referralVaultManager() external view returns (address);
    function approvedCallers(address caller) external view returns (bool);

    // ---- admin ----
    function setReferralVaultManager(address newManager) external;
    function setCaller(address caller, bool status) external;
    function pause() external;
    function unpause() external;
}
