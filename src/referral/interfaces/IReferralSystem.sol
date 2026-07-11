// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IReferralVaultManager.sol";

/**
 * @title  IReferralSystem
 * @notice Registry surface (extends the manager surface, mirroring the contract
 *         inheritance ReferralVaultManager <- ReferralSystem).
 *
 *  Codes are uint64 keys, admin-created, and carry a tier (1..8; default 1).
 *  An investor links to a code once via setTraderCode; every future deposit uses
 *  it. Ownership transfer is two-step: the current owner approves a target, then
 *  the manager executes.
 *
 *  Note: _setCodeTier and _deactivateCode are internal in the implementation; the
 *  public, settle-safe entry points (setCodeTier, deactivateCode) live on
 *  IReferralVault because they must first bank rewards.
 */
interface IReferralSystem is IReferralVaultManager {
    // ---- registry state ----
    function codeOwner(uint64 code) external view returns (address);
    function ownerToCode(address owner) external view returns (uint64);
    function traderToCode(address trader) external view returns (uint64);
    function pendingCodeOwner(uint64 code) external view returns (address);
    function codeTier(uint64 code) external view returns (uint8);

    // ---- admin: code creation ----
    function createCode(uint64 code, address owner) external;

    // ---- ownership transfer (two-step) ----
    function approveTransfer(uint64 code, address proposedOwner) external;
    function revokeTransferApproval(uint64 code) external;
    function executeTransfer(uint64 code) external;

    // ---- investor ----
    function setTraderCode(uint64 code) external;
}
