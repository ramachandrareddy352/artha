// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUserRewardVault
 * @notice Integration surface for the simple user-staking-reward programme.
 *
 *  Users stake a vault's share token directly here -- there is no vault-side
 *  integration, no oracle, and no shared pool: every staked share earns independently
 *  of how much anyone else has staked. Each vault has an admin-set ARTHA-per-share-
 *  per-second rate that can change over time; a rate-time index (see
 *  IUserRewardSystem) banks each rate's contribution the moment it changes, so a
 *  position settled across a rate change is priced correctly for both stretches.
 *  See UserRewardSystem/UserRewardVault for the full design notes.
 */
interface IUserRewardVault {
    // ── user ──

    /// @notice Stake vault shares to start earning ARTHA. Caller must approve first.
    /// @dev    Shares are pulled from msg.sender but credited to `user` -- anyone can
    ///         stake on another user's behalf. Only `user` can later unstake or claim.
    function stake(address vault, address user, uint256 amount) external;

    /// @notice Withdraw staked shares. Earned ARTHA is banked, not forfeited.
    /// @dev    Only the position owner (msg.sender) can unstake their own position.
    function unstake(address vault, uint256 amount) external;

    /// @notice Claim all ARTHA earned by the caller's own position in `vault`.
    function claimArtha(address vault) external;

    // ── views ──

    function artha() external view returns (address);

    /// @notice ARTHA left in the 10M lifetime budget.
    function arthaRemaining() external view returns (uint256);

    /// @notice ARTHA accrued but not yet claimed. Keep the balance at or above this.
    function outstandingArtha() external view returns (uint256);

    /// @notice Settled + unsettled ARTHA for a user in a vault. Cap-aware.
    function pendingArtha(address vault, address user) external view returns (uint256);

    /// @notice A vault's ARTHA per share per second, 1e18 fixed point.
    function rewardRateOf(address vault) external view returns (uint256);

    function stakedShares(address vault, address user) external view returns (uint256);

    /// @notice Everything the front-end needs about one position, in one call.
    /// @return stakedShares_      Shares currently staked.
    /// @return pendingArtha_      Settled + unsettled ARTHA.
    /// @return totalEarnedArtha_  Lifetime ARTHA ever earned here (includes claimed).
    /// @return totalClaimedArtha_ Lifetime ARTHA ever withdrawn from here.
    /// @return rewardRate_        ARTHA per share per second for this vault.
    function getInfo(address vault, address user)
        external
        view
        returns (
            uint256 stakedShares_,
            uint256 pendingArtha_,
            uint256 totalEarnedArtha_,
            uint256 totalClaimedArtha_,
            uint256 rewardRate_
        );

    function vaultInfo(address vault)
        external
        view
        returns (bool registered, address shareToken, uint256 totalArthaEarned, uint256 totalArthaClaimed);

    function globalBooks()
        external
        view
        returns (
            uint256 arthaMinted,
            uint256 arthaClaimed,
            uint256 outstanding,
            uint256 arthaLeftInBudget,
            uint256 arthaBalance
        );

    function userTotalArthaClaimed(address user) external view returns (uint256);
    function registeredVaultsCount() external view returns (uint256);

    // ── admin (timelock) ──

    /// @param rewardRate_ ARTHA per share per second, 1e18 fixed point.
    function registerVault(address vault, address shareToken, uint256 rewardRate_) external;

    function setRewardRate(address vault, uint256 rewardRate_) external;
    function rescue(address token, address to, uint256 amount) external;
}
