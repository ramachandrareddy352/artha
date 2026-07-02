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
    mapping(bytes32 => address) public codeOwner;

    /// @notice owner => the one code they hold (reverse lookup).
    mapping(address => bytes32) public ownerToCode;

    /// @notice investor => the code they use for all deposits (set once, permanent).
    mapping(address => bytes32) public traderToCode;

    event CodeCreated(bytes32 indexed code, address indexed owner);
    event CodeTransferred(bytes32 indexed code, address indexed oldOwner, address indexed newOwner);
    event CodeDeactivated(bytes32 indexed code, address indexed owner);
    event TraderCodeSet(address indexed trader, bytes32 indexed code);

    constructor(address _admin) ReferralVaultManager(_admin) {}

    /// @notice Create a code and assign it to an owner. ADMIN ONLY.
    function createCode(bytes32 _code, address _owner) external onlyReferralVaultManager {
        require(_code != bytes32(0), "INVALID_CODE");
        require(_owner != address(0), "INVALID_OWNER");
        require(codeOwner[_code] == address(0), "CODE_EXISTS");
        require(ownerToCode[_owner] == bytes32(0), "OWNER_HAS_CODE");

        codeOwner[_code] = _owner;
        ownerToCode[_owner] = _code;
        emit CodeCreated(_code, _owner);
    }

    /// @notice Admin re-assigns a code to a new owner (who must hold no code).
    function transferCodeOwnership(bytes32 _code, address _oldOwner, address _newOwner)
        external
        onlyReferralVaultManager
    {
        require(_newOwner != address(0), "INVALID_ADDRESS");
        require(codeOwner[_code] == _oldOwner, "NOT_CODE_OWNER");
        require(ownerToCode[_newOwner] == bytes32(0), "NEW_OWNER_HAS_CODE");

        codeOwner[_code] = _newOwner;
        ownerToCode[_oldOwner] = bytes32(0);
        ownerToCode[_newOwner] = _code;
        emit CodeTransferred(_code, _oldOwner, _newOwner);
    }

    /**
     * @notice Link yourself (the investor) to a code, once. All future deposits
     *         automatically credit this code — you never resend it.
     * @param  _code An existing code (not one you own — no self-referral).
     */
    function setTraderCode(bytes32 _code) external {
        require(traderToCode[msg.sender] == bytes32(0), "CODE_ALREADY_SET");
        require(codeOwner[_code] != address(0), "CODE_DOES_NOT_EXIST");
        require(codeOwner[_code] != msg.sender, "SELF_REFERRAL");

        traderToCode[msg.sender] = _code;
        emit TraderCodeSet(msg.sender, _code);
    }

    /// @dev Clear a code's ownership. The vault layer calls this AFTER checking
    /// the code has no active balance and no unclaimed rewards. Otherwise rewards are permentanly lost.
    function _deactivateCode(bytes32 _code) internal {
        address owner = codeOwner[_code];
        require(owner != address(0), "ALREADY_DEACTIVATED");
        require(owner == msg.sender || msg.sender == referralVaultManager, "NOT_OWNER_OR_ADMIN");
        
        codeOwner[_code] = address(0);
        ownerToCode[owner] = bytes32(0);
        emit CodeDeactivated(_code, owner);
    }
}
