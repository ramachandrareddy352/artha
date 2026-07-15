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
 *  Artha is now a set of single-asset VAULTS (a USDC vault, a DAI vault, a WETH
 *  vault, ...), exactly like Yearn. Each vault is its own ERC-721 and mints
 *  POSITIONS. Each vault deploys its one base token into STRATEGIES (lend, or swap
 *  into other tokens). Reward rates are therefore keyed by the VAULT CONTRACT
 *  ADDRESS, never by the token type -- because one base token (say USDC) can back
 *  two different vaults running different strategies at two different rates.
 *
 *  ROLES
 *   - referralVaultManager : the admin. In production this MUST be the
 *                            Governance Timelock. It registers vaults, sets
 *                            per-vault reward ratios, sets per-tier ratios,
 *                            promotes codes between tiers, rescues funds, pauses.
 *   - approvedCallers      : contracts allowed to report referred-balance changes
 *                            through the notify* hooks. This is the Artha vault
 *                            layer (each vault Diamond). They are trusted to pass
 *                            the correct `vault` address, tokenId, and principal.
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

    /**
     * @notice Only an approved reporter (only a vault) may drive updates, and ONLY
     *         under its OWN address.
     *
     *  ┌──────────────────────────────────────────────────────────────────────┐
     *  │  SECURITY FIX -- `msg.sender == _vault` IS NOT OPTIONAL.             │
     *  │                                                                      │
     *  │  The PREVIOUS version of this modifier took NO argument:             │
     *  │                                                                      │
     *  │      modifier onlyCaller() {                                         │
     *  │          require(approvedCallers[msg.sender], "NOT_APPROVED_CALLER");│
     *  │          _;                                                          │
     *  │      }                                                               │
     *  │                                                                      │
     *  │  It verified the CALLER was approved, but never that the `vault`     │
     *  │  ARGUMENT matched the caller. So ANY approved vault could credit     │
     *  │  referrals under ANY OTHER vault's key:                              │
     *  │                                                                      │
     *  │   1. WETH-Vault is an approved caller (legitimately).                │
     *  │   2. WETH-Vault rewardRatio = 1e17  (10%/yr -- low).                 │
     *  │   3. USDC-Vault rewardRatio = 1e18  (100%/yr -- launch boost).       │
     *  │   4. A bug or malicious upgrade in WETH-Vault lets it call:          │
     *  │        referralVault.notifyDeposit(USDC_VAULT, id, code, 1e30)       │
     *  │                                    ^^^^^^^^^^ not its own address!   │
     *  │   5. Phantom referred principal now accrues at 100%/yr in a vault    │
     *  │      that never received a cent. The referral pool drains.           │
     *  │                                                                      │
     *  │  WITH the check: a compromised vault can only corrupt its OWN book.  │
     *  │  Blast radius = one vault.                                           │
     *  └──────────────────────────────────────────────────────────────────────┘
     *
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
