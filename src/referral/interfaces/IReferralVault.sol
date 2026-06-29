// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReferralVault
 * @notice Interface the Diamond's logic facets use to drive the ReferralVault
 *         (normal external CALL). The vault is the approved "pool" caller's target.
 *
 *  Call sites (in your deposit/withdraw flow):
 *    - On a referred deposit settling   -> openPosition(...)   (returns an id to store)
 *    - On the investor adding funds      -> increasePosition(id, addedPrincipal)
 *    - On a partial withdrawal           -> decreasePosition(id, removedPrincipal)
 *    - On a full withdrawal              -> closePosition(id)
 *
 *  IMPORTANT: openPosition starts the reward clock but credits nothing. Rewards
 *  are only settled (credited) by increase/decrease/close (or settlePosition),
 *  i.e. NOT on the first investment — matching the intended design.
 */
interface IReferralVault {
    /// @return id The new position id (0 if no valid referral, e.g. self-referral).
    function openPosition(
        address investor,
        uint256 poolId,
        uint256 principal,
        uint256 termDuration, // 0 = normal/flexible; >0 = fixed-term (accrual capped at term)
        bytes32 code
    ) external returns (uint256 id);

    function increasePosition(uint256 id, uint256 addPrincipal) external;

    function decreasePosition(uint256 id, uint256 removePrincipal) external;

    function closePosition(uint256 id) external;

    /// @notice Permissionless: push a position's accrued reward into balances.
    function settlePosition(uint256 id) external;

    // ---- claims (called directly by investors / code owners) ----

    function claimInvestorRewards(address to) external returns (uint256 amount);

    function claimOwnerRewards(bytes32 code, address to, uint256 amount) external;

    // ---- views ----

    function pendingInvestor(address investor) external view returns (uint256);

    function pendingOwner(bytes32 code) external view returns (uint256);

    function previewPosition(uint256 id) external view returns (uint256 investorPart, uint256 ownerPart);
}
