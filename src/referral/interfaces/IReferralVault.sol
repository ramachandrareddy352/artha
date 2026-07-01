// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReferralVault
 * @notice Interface the Diamond's logic facets use to drive the ReferralVault
 *         (a normal external CALL). The facets pass the investor's deposited
 *         amount and code; the vault keeps the ARTHA and tracks the reward.
 *
 *  Call sites in your deposit/withdraw flow (msg.sender must be the Diamond,
 *  approved via ReferralVault.setPool(diamond, true)):
 *
 *    - When a referred deposit settles        -> notifyDeposit(code, investor, principal)
 *    - When a referred position shrinks/exits  -> notifyWithdraw(code, principal)
 *
 *  Rewards accrue on wall-clock time while the referred capital is active, so the
 *  code OWNER can claim any time via claim(...) without the investor acting.
 */
interface IReferralVault {
    // ---- driven by the Diamond on deposit / withdraw ----
    function notifyDeposit(bytes32 code, address investor, uint256 principal) external;

    function notifyWithdraw(bytes32 code, uint256 principal) external;

    // ---- anyone may push a code's accrual into its claimable balance ----
    function sync(bytes32 code) external;

    // ---- called directly by the code's current owner ----
    function claim(bytes32 code, address to, uint256 amount) external;

    // ---- views ----
    function pendingReward(bytes32 code) external view returns (uint256);

    function referredBalance(bytes32 code) external view returns (uint256);

    function codeInfo(bytes32 code)
        external
        view
        returns (address owner, uint256 balance, uint256 claimable, uint256 lifetimeClaimed);
}
