// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IReferralSystem.sol";

/**
 * @title IReferralVault
 * @notice Full external surface of the deployed ReferralVault (extends the
 *         registry + manager surfaces). This is the interface the Diamond's
 *         facets import to drive deposits/withdrawals, and that investors /
 *         code owners use to set codes and claim.
 * 
 *  poolId convention: 0 = LOW, 1 = MEDIUM, 2 = HIGH.
 *
 *  Diamond call sites (msg.sender must be an approved pool = the Diamond):
 *     - referred deposit  -> notifyDeposit(poolId, investor, principal)
 *     - referred exit      -> notifyWithdraw(poolId, investor, principal)
 *  (The code is resolved from the investor's one-time traderToCode.)
 */
interface IReferralVault is IReferralSystem {
    // constants (exposed as getters)
    function POOL_LOW() external view returns (uint8);
    function POOL_MEDIUM() external view returns (uint8);
    function POOL_HIGH() external view returns (uint8);
    function POOL_COUNT() external view returns (uint8);
    function artha() external view returns (address);

    // per-pool + per-code state (struct getters return tuples)
    function poolState(uint8 poolId)
        external
        view
        returns (uint256 currentRate, uint256 accArthaPerToken, uint256 lastUpdate, uint256 totalReferred);

    function codeAccount(uint8 poolId, bytes32 code)
        external
        view
        returns (uint256 referredBalance, uint256 rewardDebt, uint256 earned, uint256 claimed);

    function totalEarnedArtha() external view returns (uint256);
    function totalClaimedArtha() external view returns (uint256);

    // hooks (from the Diamond)
    function notifyDeposit(uint8 poolId, address investor, uint256 principal) external;
    function notifyWithdraw(uint8 poolId, address investor, uint256 principal) external;
    function sync(uint8 poolId, bytes32 code) external;

    // admin
    function setRate(uint8 poolId, uint256 newRate) external;
    function deactivateCode(bytes32 code) external;
    function rescue(address token, address to, uint256 amount) external;

    // owner claims
    function claim(uint8 poolId, bytes32 code, address to, uint256 amount) external;
    function claimAll(bytes32 code, address to) external;

    // views
    function pendingReward(uint8 poolId, bytes32 code) external view returns (uint256);
    function pendingRewardAllPools(bytes32 code) external view returns (uint256);
}
