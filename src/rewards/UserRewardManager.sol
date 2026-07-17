// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title  UserRewardManager
 * @notice Access-control base for the whole user-staking-reward stack. FIRST layer:
 *
 *             UserRewardManager  <-  UserRewardSystem  <-  UserRewardVault
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHAT THIS STACK IS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Artha is a set of single-asset VAULTS (a USDC vault, a DAI vault, a WETH vault,
 *  ...), exactly like Yearn. Each vault is its own ERC-4626 and deploys its one base
 *  token into STRATEGIES. Holding shares earns yield; that is the vault's job and
 *  this stack does not touch it.
 *
 *  This stack is the SECOND, separate incentive: STAKE your vault shares here and
 *  earn ARTHA on top, priced on the USD value of what you staked, accruing per
 *  second. Shares that merely sit in a wallet earn nothing -- the user must stake.
 *
 *  This is the sibling of the REFERRAL stack, and the two are deliberately opposite
 *  in one respect. Referral commission is priced PER FEE, at call time, and banked
 *  instantly -- nothing accrues, so a tier change needs no settlement dance. User
 *  staking rewards ACCRUE OVER TIME, so every rate change and every share movement
 *  must settle first. That single difference drives most of the design in layer 2.
 *
 *  ROLES
 *   - userRewardManager : the admin. In production this MUST be the Governance
 *                         Timelock. It registers vaults, sets per-vault reward rates
 *                         and ARTHA ratios, sets the oracle, rescues funds, pauses.
 *   - approvedCallers   : contracts allowed to report share movements through
 *                         notifyShareChange(). This is the Artha vault layer (each
 *                         vault Diamond). They are trusted to pass the correct
 *                         `vault` address, `user`, and share amounts.
 */
contract UserRewardManager is Pausable {
    /// @notice The admin address (single source of truth for the whole stack[Governance Timelock]).
    address public userRewardManager;

    /// @notice Contracts allowed to report share movements (the vault layer).
    mapping(address => bool) public approvedCallers;

    event UserRewardManagerUpdated(address oldManager, address newManager);
    event CallerUpdated(address caller, bool status);

    modifier onlyUserRewardManager() {
        require(msg.sender == userRewardManager, "NOT_USER_REWARD_MANAGER");
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

    constructor(address _userRewardManager) {
        require(_userRewardManager != address(0), "INVALID_USER_REWARD_MANAGER");
        userRewardManager = _userRewardManager;
    }

    function setUserRewardManager(address _new) external onlyUserRewardManager {
        require(_new != address(0), "INVALID_USER_REWARD_MANAGER");
        emit UserRewardManagerUpdated(userRewardManager, _new);
        userRewardManager = _new;
    }

    /// @notice Approve/revoke a contract (a vault / the Diamond) for share reporting.
    function setCaller(address _caller, bool _status) external onlyUserRewardManager {
        require(_caller != address(0), "INVALID_CALLER");
        approvedCallers[_caller] = _status;
        emit CallerUpdated(_caller, _status);
    }

    function pause() external onlyUserRewardManager {
        _pause();
    }

    function unpause() external onlyUserRewardManager {
        _unpause();
    }
}
