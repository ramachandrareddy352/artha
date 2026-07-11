// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title  ReferralVaultManager
 * @notice Access-control base for the whole referral stack. FIRST layer of the chain:
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault
 *
 *  --------------------------------
 *  Artha is now a set of single-asset VAULTS (a USDC vault, a DAI vault, a WETH vault, ...), 
 *  exactly like Yearn. Each vault deploys its one base token into STRATEGIES (lend, or
 *  swap into other tokens). Reward rates are therefore keyed by the STRATEGY /
 *  VAULT CONTRACT ADDRESS, never by the token type — because one base token
 *  (say USDC) can back two different strategies with two different rates.
 *
 *  ROLES
 *   - referralVaultManager : the admin. In production this MUST be the
 *                            Governance Timelock. It registers strategies, sets
 *                            per-strategy reward ratios, sets per-tier ratios,
 *                            promotes codes between tiers, rescues funds, pauses.
 *   - approvedCallers      : contracts allowed to report referred-balance changes
 *                            through the notify* hooks. This is the Artha vault
 *                            layer (the Diamond, or each standalone vault). They
 *                            are trusted to pass the correct `strategy` address
 *                            and the correct raw principal.
 */
contract ReferralVaultManager is Pausable {
    /// @notice The admin address (single source of truth for the whole stack).
    address public referralVaultManager;

    /// @notice Contracts allowed to call the notify* hooks (the vault layer).
    mapping(address => bool) public approvedCallers;

    event ReferralVaultManagerUpdated(address oldManager, address newManager);
    event CallerUpdated(address caller, bool status);

    modifier onlyReferralVaultManager() {
        require(msg.sender == referralVaultManager, "NOT_REFERRAL_VAULT_MANAGER");
        _;
    }

    /// @notice Only an approved reporter (a vault / the Diamond) may drive updates.
    modifier onlyCaller() {
        require(approvedCallers[msg.sender], "NOT_APPROVED_CALLER");
        _;
    }

    constructor(address _referralVaultManager) {
        require(_referralVaultManager != address(0), "INVALID_REFERRAL_VAULT_MANAGER");
        referralVaultManager = _referralVaultManager;
    }

    function setReferralVaultManager(address _new) external onlyReferralVaultManager {
        require(_new != address(0), "INVALID_REFERRAL_VAULT_MANAGER");
        emit ReferralVaultManagerUpdated(referralVaultManager, _new);
        referralVaultManager = _new;
    }

    /// @notice Approve/revoke a contract (a vault / the Diamond) for the notify* hooks.
    function setCaller(address _caller, bool _status) external onlyReferralVaultManager {
        require(_caller != address(0), "INVALID_CALLER");
        approvedCallers[_caller] = _status;
        emit CallerUpdated(_caller, _status);
    }

    function pause() external onlyReferralVaultManager {
        _pause();
    }

    function unpause() external onlyReferralVaultManager {
        _unpause();
    }
}
