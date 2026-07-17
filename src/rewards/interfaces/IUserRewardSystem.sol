// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IUserRewardSystem
 * @notice Accrual-layer surface: per-vault rate index and per-(vault, user) staked
 *         position. Flat per-share accrual, no oracle, no pool/totalStaked -- but
 *         rate changes are banked into the index immediately, so a position settled
 *         across a rate change is priced correctly for both stretches.
 */
interface IUserRewardSystem {
    /// @param shares            Shares currently staked, 1e18 fixed point.
    /// @param rewardDebt        accRewardPerShare snapshot at this position's last
    ///                          settle. Growth in the index before this value is not
    ///                          this position's to claim.
    /// @param earnedArtha       Settled, unclaimed ARTHA.
    /// @param totalEarnedArtha  Lifetime ARTHA ever earned here (includes claimed).
    /// @param totalClaimedArtha Lifetime ARTHA ever withdrawn from here.
    struct Position {
        uint256 shares;
        uint256 rewardDebt;
        uint256 earnedArtha;
        uint256 totalEarnedArtha;
        uint256 totalClaimedArtha;
    }

    /// @param rewardRate        Current ARTHA per share per second, 1e18 fixed point.
    /// @param accRewardPerShare Cumulative ARTHA per share banked up to
    ///                          `rateCheckpoint`, at the rates active along the way.
    /// @param rateCheckpoint    When accRewardPerShare was last advanced.
    struct Emission {
        uint256 rewardRate;
        uint256 accRewardPerShare;
        uint256 rateCheckpoint;
    }

    event RewardRateUpdated(address indexed vault, uint256 oldRate, uint256 newRate);

    function positionOf(address vault, address user) external view returns (Position memory);
    function emissionOf(address vault) external view returns (Emission memory);
    function rewardRateOf(address vault) external view returns (uint256);
    function stakedShares(address vault, address user) external view returns (uint256);
}
