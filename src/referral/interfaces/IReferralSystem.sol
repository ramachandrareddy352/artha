// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  IReferralSystem
 * @notice Registry surface (layer 2 of 3): who owns each code, which TIER it sits
 *         in, which code each TRADER bound, and each code's user DISCOUNT.
 */
interface IReferralSystem {
    // ─────────────────────────────── events ─────────────────────────────────────

    event CodeCreated(uint64 indexed code, address  owner, uint8 tier);
    event CodeTransferred(uint64 indexed code, address  oldOwner, address  newOwner);
    event TransferApproved(uint64 indexed code, address currentOwner, address proposedOwner);
    event TransferApprovalRevoked(uint64 indexed code, address currentOwner);
    event CodeDeactivated(uint64 indexed code, address  owner);
    event CodeTierSet(uint64 indexed code, uint8 oldTier, uint8 newTier);
    event CodeDiscountSet(uint64 indexed code, uint32 oldDiscountBps, uint32 newDiscountBps);
    event TraderCodeSet(uint64 indexed code, address trader);

    // ─────────────────────────────── views ──────────────────────────────────────

    /// @notice code => current owner. address(0) => nonexistent or deactivated.
    function codeOwner(uint64 code) external view returns (address);

    /// @notice owner => the single code they hold (0 if none).
    function ownerToCode(address owner) external view returns (uint64);

    /// @notice code => tier id (1..MAX_TIERS). 0 => nonexistent/deactivated.
    function codeTier(uint64 code) external view returns (uint8);

    /// @notice code => share of the OWNER's commission handed back to the trader.
    ///         1_000 = 1%, 100_000 = 100%. Set by the code owner.
    function codeDiscount(uint64 code) external view returns (uint32);

    /// @notice code => owner-approved incoming owner (0 if no pending transfer).
    function pendingCodeOwner(uint64 code) external view returns (address);

    /// @notice trader => the code they bound. Set ONCE; re-settable only after the
    ///         bound code is deactivated.
    function traderCode(address trader) external view returns (uint64);

    /// @notice True when the code exists and is active.
    function isCodeActive(uint64 code) external view returns (bool);

    /// @notice The code a trader will actually be credited under (0 if none/dead).
    function activeTraderCode(address trader) external view returns (uint64);

    // ────────────────────────── trader / owner actions ──────────────────────────

    /// @notice Bind a referral code to msg.sender. Once only, unless the previously
    ///         bound code has since been deactivated.
    function setTraderCode(uint64 code) external;

    /// @notice The code owner sets the % of THEIR commission rebated to traders.
    function setCodeDiscount(uint64 code, uint32 discountBps) external;

    /// @notice Step 1 — the code owner nominates who may receive it.
    function approveTransfer(uint64 code, address proposedOwner) external;

    /// @notice The owner cancels a pending nomination.
    function revokeTransferApproval(uint64 code) external;

    // ─────────────────────────────── admin ──────────────────────────────────────

    /// @notice Create a code at tier 1. ADMIN ONLY.
    function createCode(uint64 code, address owner) external;

    /// @notice Step 2 — the admin executes an owner-approved transfer. ADMIN ONLY.
    function executeTransfer(uint64 code) external;
}
