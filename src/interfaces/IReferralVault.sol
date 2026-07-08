// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IReferralVault — subset the core Diamond calls on the SEPARATE referral vault.
/// @notice poolId here is the referral TIER pool (0=LOW,1=MEDIUM,2=HIGH). The core
///         maps its 6 pools -> 3 tiers via RiskTier before calling.
interface IReferralVault {
    function notifyDeposit(uint8 poolId, address investor, uint256 principal) external;
    function notifyWithdraw(uint8 poolId, address investor, uint256 principal) external;
}
