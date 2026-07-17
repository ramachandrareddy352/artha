// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUserRewardManager
 * @notice Access-control surface for the user-staking-reward stack.
 * @dev    userRewardManager is the sole admin (in production, the Governance
 *         Timelock). There are no approved-caller/vault-hook roles -- users move
 *         their own share tokens in and out directly, so nothing else ever needs to
 *         be trusted to report on their behalf.
 */
interface IUserRewardManager {
    event UserRewardManagerUpdated(address oldManager, address newManager);

    function userRewardManager() external view returns (address);
    function paused() external view returns (bool);

    function setUserRewardManager(address _new) external;
    function pause() external;
    function unpause() external;
}
