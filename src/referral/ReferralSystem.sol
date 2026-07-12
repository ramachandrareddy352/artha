// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ReferralVaultManager.sol";

/**
 * @title  ReferralSystem
 * @notice The referral REGISTRY layer. It knows "who owns each code", "which code
 *         an investor uses", and now "which TIER each code sits in". It holds no
 *         money. Second layer of the chain:
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault
 *
 *  CODES ARE CREATED BY THE ADMIN ONLY.
 *  The protocol hands codes to active participants at offline events. Users cannot
 *  self-generate codes, so nobody can mint a code and refer their own second
 *  wallet. (The vault layer also blocks owner == depositor as defense-in-depth.)
 *
 *  INVESTOR SETS THEIR CODE ONCE.
 *  An investor calls setTraderCode(code) a single time; every future deposit uses
 *  it. Set-once on purpose — rewards are tracked per code, so switching mid-way
 *  would misattribute already-referred capital.
 *
 *  TIERS (new).
 *  Every code carries a tier (1, 2, 3, ...). The tier does NOT change the reward
 *  math here; it only records the code's rank. The TOP layer (ReferralVault) maps
 *  each tier to a ratio (e.g. tier 1 => 1e17, tier 2 => 3e17, tier 3 => 1e18) and
 *  uses it in the reward formula. New codes start at tier 1. Governance promotes a
 *  code with ReferralVault.setCodeTier(), which safely banks accrued reward at the
 *  OLD tier before switching — see that contract.
 *
 *  RETIREMENT.
 *  The referral program is temporary. Once the referral ARTHA budget is exhausted,
 *  all codes are deactivated, the vault is paused, and any leftover ARTHA is swept
 *  to the treasury. It is planned for intial development of protocol to raise liquidity.
 */
contract ReferralSystem is ReferralVaultManager {
    /// @notice code => current owner (address(0) means "no code / deactivated").
    mapping(uint64 => address) public codeOwner;

    /// @notice owner => the one code they hold (reverse lookup).
    mapping(address => uint64) public ownerToCode;

    /// @notice investor => the code they use for all deposits (set once, permanent).
    mapping(address => uint64) public traderToCode;

    /// @notice code => owner-approved incoming owner (pending transfer target).
    mapping(uint64 => address) public pendingCodeOwner;

    /// @notice code => tier (1, 2, 3, ...). New codes default to tier 1.
    mapping(uint64 => uint8) public codeTier;

    event CodeCreated(uint64 code, address owner, uint8 tier);
    event CodeTransferred(uint64 code, address oldOwner, address newOwner);
    event CodeDeactivated(uint64 code, address owner);
    event TraderCodeSet(address trader, uint64 code);
    event TransferApproved(uint64 code, address currentOwner, address proposedOwner);
    event TransferApprovalRevoked(uint64 code, address currentOwner);
    event CodeTierSet(uint64 code, uint8 oldTier, uint8 newTier);

    constructor(address _admin) ReferralVaultManager(_admin) {}

    /// @notice Create a code and assign it to an owner at tier 1. ADMIN ONLY.
    function createCode(uint64 _code, address _owner) external onlyReferralVaultManager {
        require(_code != uint64(0), "INVALID_CODE");
        require(_owner != address(0), "INVALID_OWNER");
        require(codeOwner[_code] == address(0), "CODE_EXISTS");
        require(ownerToCode[_owner] == uint64(0), "OWNER_HAS_CODE");

        codeOwner[_code] = _owner;
        ownerToCode[_owner] = _code;
        codeTier[_code] = 1; // everyone starts at tier 1
        emit CodeCreated(_code, _owner, 1);
    }

    /**
     * @notice Step 1 — the CURRENT code owner approves who may receive the code.
     * @param  _code          The code you own.
     * @param  _proposedOwner The address you approve to take it over.
     */
    function approveTransfer(uint64 _code, address _proposedOwner) external {
        require(codeOwner[_code] == msg.sender, "NOT_CODE_OWNER");
        require(_proposedOwner != address(0), "INVALID_ADDRESS");
        require(_proposedOwner != msg.sender, "ALREADY_OWNER");
        require(ownerToCode[_proposedOwner] == uint64(0), "NEW_OWNER_HAS_CODE");

        pendingCodeOwner[_code] = _proposedOwner;
        emit TransferApproved(_code, msg.sender, _proposedOwner);
    }

    /// @notice Owner cancels a pending approval before it is executed.
    function revokeTransferApproval(uint64 _code) external {
        require(codeOwner[_code] == msg.sender, "NOT_CODE_OWNER");
        require(pendingCodeOwner[_code] != address(0), "NO_PENDING_TRANSFER");

        delete pendingCodeOwner[_code];
        emit TransferApprovalRevoked(_code, msg.sender);
    }

    /**
     * @notice Step 2 — the MANAGER executes a transfer the owner already approved.
     *         The code's tier travels with it (it is a property of the code).
     */
    function executeTransfer(uint64 _code) external onlyReferralVaultManager {
        address _oldOwner = codeOwner[_code];
        require(_oldOwner != address(0), "CODE_DOES_NOT_EXIST");

        address _newOwner = pendingCodeOwner[_code];
        require(_newOwner != address(0), "NO_PENDING_TRANSFER");
        require(ownerToCode[_newOwner] == uint64(0), "NEW_OWNER_HAS_CODE"); // re-check at execution

        delete pendingCodeOwner[_code];

        codeOwner[_code] = _newOwner;
        ownerToCode[_oldOwner] = uint64(0);
        ownerToCode[_newOwner] = _code;
        emit CodeTransferred(_code, _oldOwner, _newOwner);
    }

    /**
     * @notice Link yourself (the investor) to a code, once. All future deposits
     *         automatically credit this code — olny set once
     * @param  _code An existing code , self referral is allowed.
     */
    function setTraderCode(uint64 _code) external {
        require(_code != uint64(0), "INVALID_CODE");
        require(codeOwner[_code] != address(0), "CODE_DOES_NOT_EXIST");
        require(traderToCode[msg.sender] == uint64(0), "CODE_ALREADY_SET");

        traderToCode[msg.sender] = _code;
        emit TraderCodeSet(msg.sender, _code);
    }

    /// @dev Internal tier writer. The public, settle-safe entry point lives in
    ///      ReferralVault.setCodeTier(), which banks reward at the OLD tier first.
    function _setCodeTier(uint64 _code, uint8 _newTier) internal {
        require(codeOwner[_code] != address(0), "CODE_DOES_NOT_EXIST");
        require(_newTier != 0, "INVALID_TIER");
        
        uint8 old = codeTier[_code];
        codeTier[_code] = _newTier;
        emit CodeTierSet(_code, old, _newTier);
    }

    /// @dev Clear a code's ownership. The vault layer calls this AFTER checking the
    ///      code has no active balance and no unclaimed rewards; else rewards are lost.
    function _deactivateCode(uint64 _code) internal {
        address owner = codeOwner[_code];
        require(owner != address(0), "ALREADY_DEACTIVATED");
        require(owner == msg.sender || msg.sender == referralVaultManager, "NOT_OWNER_OR_ADMIN");

        codeOwner[_code] = address(0);
        ownerToCode[owner] = uint64(0);
        codeTier[_code] = 0;
        delete pendingCodeOwner[_code];
        
        emit CodeDeactivated(_code, owner);
    }
}
