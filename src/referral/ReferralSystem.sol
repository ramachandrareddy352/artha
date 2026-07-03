// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ReferralVaultManager.sol";

/**
 * @title  ReferralSystem
 * @notice The referral REGISTRY layer. It knows "who owns each code" and "which
 *         code an investor uses". It holds no money. Second layer of the chain:
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault
 *
 *  KEY DECISION — CODES ARE CREATED BY THE ADMIN ONLY.
 *  The protocol runs offline events and hands codes to active participants, which
 *  builds community trust. Users cannot self-generate codes, so an investor cannot
 *  mint a code and refer their own second wallet. (The vault layer also blocks the
 *  degenerate self-referral where owner == depositor, as defense-in-depth.)
 *
 *  INVESTOR SETS THEIR CODE ONCE.
 *  Instead of passing a referral code on every deposit, an investor calls
 *  setTraderCode(code) a single time. Every future deposit automatically uses it.
 *  It is set-once (permanent) on purpose: rewards are tracked per-code, so letting
 *  someone switch codes mid-way would misattribute their already-referred capital.
 * Note: After the protocol allocated referral rewards are completed then all codes are deactivated and the referral system is retired. The referral system is not a permanent feature of the protocol.
 * It only exists to incentivize early adoption and community building. After the referral system is retired, the referral vault will be paused and all remaining ARTHA in the vault will be sent to the protocol treasury.
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

    event CodeCreated(uint64 code, address owner);
    event CodeTransferred(uint64 code, address oldOwner, address newOwner);
    event CodeDeactivated(uint64 code, address owner);
    event TraderCodeSet(address trader, uint64 code);
    event TransferApproved(uint64 code, address currentOwner, address proposedOwner);
    event TransferApprovalRevoked(uint64 code, address currentOwner);


    constructor(address _admin) ReferralVaultManager(_admin) {}

    /// @notice Create a code and assign it to an owner. ADMIN ONLY.
    function createCode(uint64 _code, address _owner) external onlyReferralVaultManager {
        require(_code != uint64(0), "INVALID_CODE");
        require(_owner != address(0), "INVALID_OWNER");
        require(codeOwner[_code] == address(0), "CODE_EXISTS");
        require(ownerToCode[_owner] == uint64(0), "OWNER_HAS_CODE");

        codeOwner[_code] = _owner;
        ownerToCode[_owner] = _code;
        emit CodeCreated(_code, _owner);
    }


    /**
     * @notice Step 1 — the CURRENT code owner approves who may receive the code.
     *         The proposed owner must not already hold a code.
     * @param  _code        The code you own.
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
     *         No old/new args needed: they come from storage. Clears the approval.
     */
    function executeTransfer(uint64 _code) external onlyReferralVaultManager {
        address _oldOwner = codeOwner[_code];
        require(_oldOwner != address(0), "CODE_DOES_NOT_EXIST");

        address _newOwner = pendingCodeOwner[_code];
        require(_newOwner != address(0), "NO_PENDING_TRANSFER");
        require(ownerToCode[_newOwner] == uint64(0), "NEW_OWNER_HAS_CODE"); // re-check at execution

        delete pendingCodeOwner[_code];               // erase the approval

        codeOwner[_code] = _newOwner;
        ownerToCode[_oldOwner] = uint64(0);
        ownerToCode[_newOwner] = _code;
        emit CodeTransferred(_code, _oldOwner, _newOwner);
    }

    /**
     * @notice Link yourself (the investor) to a code, once. All future deposits
     *         automatically credit this code — you never resend it.
     * @param  _code An existing code (not one you own — no self-referral).
     */
    function setTraderCode(uint64 _code) external {
        require(traderToCode[msg.sender] == uint64(0), "CODE_ALREADY_SET");
        require(codeOwner[_code] != address(0), "CODE_DOES_NOT_EXIST");
        require(codeOwner[_code] != msg.sender, "SELF_REFERRAL");

        traderToCode[msg.sender] = _code;
        emit TraderCodeSet(msg.sender, _code);
    }

    /// @dev Clear a code's ownership. The vault layer calls this AFTER checking
    /// the code has no active balance and no unclaimed rewards. Otherwise rewards are permentanly lost.
    function _deactivateCode(uint64 _code) internal {
        address owner = codeOwner[_code];
        require(owner != address(0), "ALREADY_DEACTIVATED");
        require(owner == msg.sender || msg.sender == referralVaultManager, "NOT_OWNER_OR_ADMIN");
        
        codeOwner[_code] = address(0);
        ownerToCode[owner] = uint64(0);
        emit CodeDeactivated(_code, owner);
    }
}