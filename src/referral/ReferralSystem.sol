// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
                               ReferralSystem
//////////////////////////////////////////////////////////////////////////*/
/**
 * @title  ReferralSystem
 * @notice Standalone referral REGISTRY. It owns all its storage here (not a
 *         Diamond facet) and holds no money. It only answers "who owns this code".
 *
 *  KEY DECISION — CODES ARE CREATED BY ADMIN ONLY.
 *  If anyone could mint a code, an investor could create a code, then deposit
 *  from a second wallet using it, and farm referral rewards on their own money.
 *  By making `createCode` admin-only, that attack is impossible: an investor
 *  cannot obtain a code to refer themselves. (The ReferralVault also blocks the
 *  degenerate self-referral where owner == depositor, as defense-in-depth.)
 *
 *  The ReferralVault reads this registry through IReferralSystem to (a) validate
 *  a code on deposit and (b) check the current owner on claim.
 */
contract ReferralSystem {
    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Administrator. The ONLY address that can mint codes and promote.
    address public admin;

    /// @notice code => current owner (address(0) means "no code / deactivated").
    mapping(bytes32 => address) public codeOwner;

    /// @notice owner => the one code they hold (reverse lookup).
    mapping(address => bytes32) public ownerToCode;

    /// @notice Addresses allowed to deactivate codes (e.g. the ReferralVault).
    mapping(address => bool) public isHandler;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AdminTransferred(address oldAdmin, address newAdmin);
    event HandlerUpdated(address handler, bool status);
    event CodeCreated(bytes32 indexed code, address indexed owner);
    event CodeTransferred(bytes32 indexed code, address indexed oldOwner, address indexed newOwner);
    event CodeDeactivated(bytes32 indexed code, address indexed owner);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        require(msg.sender == admin, "NOT_ADMIN");
        _;
    }

    modifier onlyHandler() {
        require(isHandler[msg.sender], "NOT_HANDLER");
        _;
    }

    constructor(address _admin) {
        require(_admin != address(0), "INVALID_ADMIN");
        admin = _admin;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function transferAdmin(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "INVALID_ADMIN");
        admin = _newAdmin;
        emit AdminTransferred(msg.sender, _newAdmin);
    }

    /// @notice Allow/deny an address (the ReferralVault) to deactivate codes.
    function updateHandler(address _handler, bool _status) external onlyAdmin {
        require(_handler != address(0), "INVALID_HANDLER");
        isHandler[_handler] = _status;
        emit HandlerUpdated(_handler, _status);
    }

    /**
     * @notice Create a code and assign it to an owner. ADMIN ONLY.
     * @param  _code  The code (bytes32).
     * @param  _owner The referrer who will earn from it.
     */
    function createCode(bytes32 _code, address _owner) external onlyAdmin {
        require(_code != bytes32(0), "INVALID_CODE");
        require(_owner != address(0), "INVALID_OWNER");
        require(codeOwner[_code] == address(0), "CODE_EXISTS");
        require(ownerToCode[_owner] == bytes32(0), "OWNER_HAS_CODE");

        codeOwner[_code] = _owner;
        ownerToCode[_owner] = _code;
        emit CodeCreated(_code, _owner);
    }

    /*//////////////////////////////////////////////////////////////
                          OWNER / HANDLER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner hands their code to a new owner (who must hold no code).
    function transferCodeOwnership(bytes32 _code, address _newOwner) external {
        require(_newOwner != address(0), "INVALID_ADDRESS");
        require(codeOwner[_code] == msg.sender, "NOT_CODE_OWNER");
        require(ownerToCode[_newOwner] == bytes32(0), "NEW_OWNER_HAS_CODE");

        codeOwner[_code] = _newOwner;
        ownerToCode[msg.sender] = bytes32(0);
        ownerToCode[_newOwner] = _code;
        emit CodeTransferred(_code, msg.sender, _newOwner);
    }

    /// @notice Deactivate a code (only a handler, e.g. the ReferralVault).
    function deactivateCode(bytes32 _code) external onlyHandler {
        address owner = codeOwner[_code];
        require(owner != address(0), "ALREADY_DEACTIVATED");

        codeOwner[_code] = address(0);
        ownerToCode[owner] = bytes32(0);
        emit CodeDeactivated(_code, owner);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function getCodeOwner(bytes32 _code) external view returns (address) {
        return codeOwner[_code];
    }

    function isValidCode(bytes32 _code) external view returns (bool) {
        return codeOwner[_code] != address(0);
    }
}
