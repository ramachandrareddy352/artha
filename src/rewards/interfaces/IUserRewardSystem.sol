// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  IUserRewardSystem
 * @notice The registry/access surface of the user reward stack. Mirrors
 *         IReferralSystem in the referral stack.
 */
interface IUserRewardSystem {
    // ─────────────────────────── access control ─────────────────────────────────
    function rewardManager() external view returns (address);
    function approvedCallers(address caller) external view returns (bool);
    function paused() external view returns (bool);

    function setRewardManager(address newManager) external;
    function setCaller(address caller, bool status) external;
    function pause() external;
    function unpause() external;
}
