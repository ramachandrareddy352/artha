// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IReferralVaultManager.sol";

/**
 * @title IReferralSystem
 * @notice Registry surface (extends the manager surface, mirroring the
 *         contract inheritance ReferralVaultManager <- ReferralSystem).
 */
interface IReferralSystem is IReferralVaultManager {
    // registry state
    function codeOwner(bytes32 code) external view returns (address);
    function ownerToCode(address owner) external view returns (bytes32);
    function traderToCode(address trader) external view returns (bytes32);

    // admin / investor actions
    function createCode(bytes32 code, address owner) external;
    function transferCodeOwnership(bytes32 code, address oldOwner, address newOwner) external;
    function setTraderCode(bytes32 code) external;
}
