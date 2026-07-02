// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title  ReferralVaultManager
 * @notice Access-control base for the whole referral stack. This is the FIRST
 *         layer of the inheritance chain:
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault
 *
 *  ROLES:
 *   - referralVaultManager : the admin. Creates codes, sets per-pool rates,
 *                            rescues funds, pauses. Use a multisig / timelock.
 *   - approvedPools        : addresses allowed to push deposit/withdraw hooks.
 *                            In Artha this is the DIAMOND (facets run inside it
 *                            via delegatecall, so msg.sender is the Diamond).
 *                            Approve it with setPool(diamond, true).
 */
contract ReferralVaultManager is Pausable {
    /// @notice The admin address (single source of truth for the whole stack).
    address public referralVaultManager;

    /// @notice Addresses allowed to call the notify* hooks (the Diamond).
    mapping(address => bool) public approvedPools;

    event ReferralVaultManagerUpdated(address oldManager, address newManager);
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

    function setReferralVaultManager(address _new) external onlyReferralVaultManager {
        require(_new != address(0), "INVALID_REFERRAL_VAULT_MANAGER");
        referralVaultManager = _new;
        emit ReferralVaultManagerUpdated(msg.sender, _new);
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
