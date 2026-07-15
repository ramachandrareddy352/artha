// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title  UserRewardManager
 * @notice Access-control base for the whole USER reward stack. FIRST layer of the chain:
 *
 *             UserRewardManager  <-  UserRewardSystem  <-  UserRewardVaul
 *
 *  --------------------------------
 *  WHY A SEPARATE STACK FROM REFERRAL?
 *
 *  They pay DIFFERENT people for DIFFERENT things out of DIFFERENT pools:
 *
 *    - REFERRAL rewards pay the CODE OWNER for bringing capital in.
 *      Keyed by (vault, code). Has tiers. Temporary programme.
 *
 *    - USER rewards pay the POSITION for having capital at risk.
 *      Keyed by (vault, tokenId). No tiers. Permanent programme.
 *
 *  Separate stacks mean separate ARTHA pools and separate caps. Draining one
 *  can never touch the other. That isolation is the entire point.
 *
 *  --------------------------------
 *  KEYED BY (VAULT ADDRESS, POSITION ID) -- NOT BY USER ADDRESS.
 *
 *  Artha is a set of single-asset VAULTS (a USDC vault, a WETH vault, ...).
 *  Each vault is its own ERC-721 and mints POSITIONS (tokenIds). Reward rates are
 *  keyed by the VAULT CONTRACT ADDRESS, never by token type -- one base token
 *  (say USDC) can back two vaults running different strategies at different rates.
 *
 *  Reward PRINCIPAL is keyed by (vault, tokenId), because ANYONE may deposit into
 *  someone else's position but only the OWNER may withdraw. 
 *
 *  ROLES
 *   - rewardManager   : the admin. In production this MUST be the Governance
 *                       Timelock. It registers vaults, sets per-vault reward
 *                       ratios, sets the cap, rescues funds, pauses.
 *   - approvedCallers : contracts allowed to report principal changes through the
 *                       notify* hooks. This is the Artha vault layer (each vault
 *                       Diamond). They are trusted to pass the correct `vault`
 *                       address, the correct tokenId, and the correct principal.
 */
contract UserRewardManager is Pausable {
    // ─────────────────────────── roles ─────────────────────────────────────────
    /// @notice The admin address (single source of truth for the whole stack).
    address public rewardManager;

    /// @notice Contracts allowed to call the notify* hooks (the artha vaults).
    mapping(address => bool) public approvedCallers;

    // ─────────────────────────── events ─────────────────────────────────────────
    event RewardManagerUpdated(address oldManager, address newManager);
    event CallerUpdated(address caller, bool status);

    // ─────────────────────────── modifiers ──────────────────────────────────────
    modifier onlyRewardManager() {
        require(msg.sender == rewardManager, "NOT_REWARD_MANAGER");
        _;
    }

    /**
     * @notice Only an approved reporter (only a artha vault) may drive updates, and ONLY
     *         under its OWN address.
     *
     *  ┌──────────────────────────────────────────────────────────────────────┐
     *  │  THE `msg.sender == vault` CHECK IS NOT OPTIONAL.                    │
     *  │                                                                      │
     *  │  Without it, ANY approved vault can credit rewards under ANY OTHER   │
     *  │  vault's key. Concretely:                                            │
     *  │                                                                      │
     *  │   1. WETH-Vault is an approved caller (legitimately).                │
     *  │   2. WETH-Vault rewardRatio = 1e17  (10%/yr -- low).                 │
     *  │   3. USDC-Vault rewardRatio = 1e18  (100%/yr -- launch boost).       │
     *  │   4. A bug or malicious upgrade in WETH-Vault lets it call:          │
     *  │        system.notifyDeposit(USDC_VAULT, someId, 1e30)                │
     *  │                             ^^^^^^^^^^ not its own address!          │
     *  │   5. Phantom principal now accrues at 100%/yr in a vault that never  │
     *  │      received a cent. The entire ARTHA pool drains.                  │
     *  │                                                                      │
     *  │  WITH the check: a compromised vault can only corrupt its OWN book.  │
     *  │  Blast radius = one vault. That is the difference between a bug and  │
     *  │  a catastrophe.                                                      │
     *  └──────────────────────────────────────────────────────────────────────┘
     *
     *  NOTE: `ReferralVaultManager.onlyCaller` in the referral stack currently
     *  takes NO argument and therefore CANNOT make this check. It is vulnerable
     *  to exactly the attack above. It should be changed to match this signature.
     *
     * @param _vault The vault the caller claims to be reporting for.
     */
    modifier onlyCaller(address _vault) {
        require(approvedCallers[msg.sender], "NOT_APPROVED_CALLER");
        require(msg.sender == _vault, "CALLER_NOT_VAULT");
        _;
    }

    // ─────────────────────────── constructor ────────────────────────────────────
    constructor(address _rewardManager) {
        require(_rewardManager != address(0), "INVALID_REWARD_MANAGER");
        rewardManager = _rewardManager;
    }

    // ─────────────────────────── admin ──────────────────────────────────────────
    function setRewardManager(address _new) external onlyRewardManager {
        require(_new != address(0), "INVALID_REWARD_MANAGER");
        emit RewardManagerUpdated(rewardManager, _new);
        rewardManager = _new;
    }

    /// @notice Approve/revoke a contract (a vault Diamond) for the notify* hooks.
    function setCaller(address _caller, bool _status) external onlyRewardManager {
        require(_caller != address(0), "INVALID_CALLER");
        approvedCallers[_caller] = _status;
        emit CallerUpdated(_caller, _status);
    }

    function pause() external onlyRewardManager {
        _pause();
    }

    function unpause() external onlyRewardManager {
        _unpause();
    }
}
