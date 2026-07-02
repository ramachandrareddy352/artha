// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReferralVaultManager
 * @notice Admin / access-control surface of the referral stack.
 */
interface IReferralVaultManager {
    function referralVaultManager() external view returns (address);
    function approvedPools(address caller) external view returns (bool);

    function setReferralVaultManager(address newManager) external;
    function setPool(address pool, bool status) external;
    function pause() external;
    function unpause() external;
}
