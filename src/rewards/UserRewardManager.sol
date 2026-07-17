// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title  UserRewardManager
 * @notice Access-control base for the whole user-staking-reward stack. FIRST layer:
 *
 *             UserRewardManager  <-  UserRewardSystem  <-  UserRewardVault
 *
 *  A simple staking programme: STAKE a vault's share token here and earn ARTHA on
 *  top, per second, flat per share. There is no vault-side integration -- users move
 *  their own share tokens in and out directly, so this stack never calls out to, and
 *  is never called by, any vault contract.
 *
 *  ROLE
 *   - userRewardManager : the admin. In production this MUST be the Governance
 *                         Timelock. It registers vaults, sets each vault's reward
 *                         rate, funds and ends campaigns, rescues stray tokens, and
 *                         pauses.
 */
contract UserRewardManager is Pausable {
    /// @notice The admin address (single source of truth for the whole stack[Governance Timelock]).
    address public userRewardManager;

    event UserRewardManagerUpdated(address oldManager, address newManager);

    modifier onlyUserRewardManager() {
        require(msg.sender == userRewardManager, "NOT_USER_REWARD_MANAGER");
        _;
    }

    constructor(address _userRewardManager) {
        require(_userRewardManager != address(0), "INVALID_USER_REWARD_MANAGER");
        userRewardManager = _userRewardManager;
    }

    function setUserRewardManager(address _new) external onlyUserRewardManager {
        require(_new != address(0), "INVALID_USER_REWARD_MANAGER");
        emit UserRewardManagerUpdated(userRewardManager, _new);
        userRewardManager = _new;
    }

    function pause() external onlyUserRewardManager {
        _pause();
    }

    function unpause() external onlyUserRewardManager {
        _unpause();
    }
}
