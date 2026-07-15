// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  IReferralVaultManager
 * @notice Access-control surface. FIRST layer of the chain:
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault
 *
 *  `referralVaultManager` is the admin (the Governance Timelock in production).
 *  `approvedCallers` are the Artha vault Diamonds allowed to drive the notify*
 *  hooks. A caller may ONLY report under its OWN address -- the implementation's
 *  `onlyCaller(address vault)` modifier enforces `msg.sender == vault`.
 */
interface IReferralVaultManager {
    function referralVaultManager() external view returns (address);
    function approvedCallers(address caller) external view returns (bool);
    function paused() external view returns (bool);

    function setReferralVaultManager(address newManager) external;
    function setCaller(address caller, bool status) external;
    function pause() external;
    function unpause() external;
}
