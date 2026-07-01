// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title  ReferralVaultManager
 * @notice Access-control base for the ReferralVault & ReferralSystem.
 *
 *  ROLES:
 *   - referralVaultManager : configures the vault (reward rate, rescue, pause). Should be a
 *                  multisig / timelock in production.
 *   - approvedPools : addresses allowed to push deposit/withdraw notifications.
 *                     In Artha this is the DIAMOND. Facets run inside the Diamond
 *                     via delegatecall, so when a facet calls the vault the
 *                     msg.sender is the Diamond's address — approve that one
 *                     address with setPool(diamond, true).
 */
contract ReferralVaultManager is Pausable {
    /// @notice Administrator of the referral vault.
    address public referralVaultManager;

    /// @notice Addresses allowed to call the notify* hooks (the Diamond).
    mapping(address => bool) public approvedPools;

    event ReferralVaultManagerUpdated(address oldReferralVaultManager, address newReferralVaultManager);
    event PoolUpdated(address pool, bool status);

    modifier onlyReferralVaultManager() {
        require(msg.sender == referralVaultManager, "NOT_REFERRAL_VAULT_MANAGER");
        _;
    }

    /// @notice Only an approved caller (the Diamond) may drive position updates.
    modifier onlyPool() {
        require(approvedPools[msg.sender], "NOT_ALLOWED_POOL");
        _;
    }

    constructor(address _referralVaultManager) {
        require(_referralVaultManager != address(0), "INVALID_REFERRAL_VAULT_MANAGER");
        referralVaultManager = _referralVaultManager;
    }

    function setReferralVaultManager(address _newReferralVaultManager) external onlyReferralVaultManager {
        require(_newReferralVaultManager != address(0), "INVALID_REFERRAL_VAULT_MANAGER");
        referralVaultManager = _newReferralVaultManager;
        emit ReferralVaultManagerUpdated(msg.sender, _newReferralVaultManager);
    }

    /// @notice Approve/revoke a caller (the Diamond) for the notify* hooks.
    function setPool(address _pool, bool _status) external onlyReferralVaultManager {
        require(_pool != address(0), "INVALID_POOL");
        approvedPools[_pool] = _status;
        emit PoolUpdated(_pool, _status);
    }

    function pause() external onlyReferralVaultManager {
        _pause();
    }

    function unpause() external onlyReferralVaultManager {
        _unpause();
    }
}
