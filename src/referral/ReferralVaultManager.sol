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
 *  Artha is a set of single-asset VAULTS (a USDC vault, a DAI vault, a WETH vault,
 *  ...), exactly like Yearn. Each vault is its own ERC-4626.
 *  Each vault deploys its one base token into STRATEGIES.
 *
 *  The referral programme pays out of the vault's PERFORMANCE FEE, in the vault's
 *  OWN BASE TOKEN, at withdrawal time. Rates are keyed by the VAULT CONTRACT
 *  ADDRESS, never by the token type -- because one base token (say USDC) can back
 *  two different vaults running different strategies at two different rates, and
 *  because a high-liquidity vault may justify a larger profit share than a thin one.
 *
 *  ROLES
 *   - referralVaultManager : the admin. In production this MUST be the Governance
 *                            Timelock. It creates and transfers CODES, registers
 *                            vaults, sets per-(vault,tier) reward ratios and
 *                            per-vault ARTHA ratios, promotes codes between tiers,
 *                            rescues funds, and pauses.
 *   - approvedCallers      : contracts allowed to settle performance fees through
 *                            settlePerformanceFee(). This is the Artha vault layer
 *                            (each vault Diamond). They are trusted to pass the
 *                            correct `vault` address, `trader`, and fee amount.
 */
contract ReferralVaultManager is Pausable {
    /// @notice The admin address (single source of truth for the whole stack[Governance Timelock]).
    address public referralVaultManager;

    /// @notice Contracts allowed to settle performance fees (the vault layer).
    mapping(address => bool) public approvedCallers;

    event ReferralVaultManagerUpdated(address oldManager, address newManager);
    event CallerUpdated(address caller, bool status);

    modifier onlyReferralVaultManager() {
        require(msg.sender == referralVaultManager, "NOT_REFERRAL_VAULT_MANAGER");
        _;
    }

    /**
     * @notice Only an approved reporter (only a vault) may drive settlement, and
     *         ONLY under its OWN address.
     * @param _vault The vault the caller claims to be reporting for.
     */
    modifier onlyCaller(address _vault) {
        require(approvedCallers[msg.sender], "NOT_APPROVED_CALLER");
        require(msg.sender == _vault, "CALLER_NOT_VAULT");
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

    /// @notice Approve/revoke a contract (a vault / the Diamond) for settlement.
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
