// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUserRewardSystem
/// @notice Accounting core for USD-normalized, prospective-rate staking rewards.
/// @dev All USD values are 8-decimal fixed point, matching the oracle format.
interface IUserRewardSystem {
    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @param shares          Vault shares currently staked by the user.
    /// @param lastAccrualTime Timestamp of the user's last settle.
    /// @param lastSharePriceUSD Share price in USD (8dp) captured at last settle.
    ///                          This is the left endpoint of the next accrual window.
    /// @param earnedUSD       Settled-but-unclaimed reward, denominated in USD (8dp).
    /// @param stakeStartTime  First time this user ever staked in this vault.
    struct UserStake {
        uint256 shares;
        uint256 lastAccrualTime;
        uint256 lastSharePriceUSD;
        uint256 earnedUSD;
        uint256 stakeStartTime;
    }

    /// @param startTime Timestamp this rate became active.
    /// @param rateBps   APR in basis points. 1000 = 10% APR.
    struct RateEpoch {
        uint256 startTime;
        uint256 rateBps;
    }

    /// @param asset          Underlying asset of the vault (for oracle lookup).
    /// @param enabled        Whether accrual is active for this vault.
    /// @param registered     Whether this vault has ever been registered.
    /// @param totalShares    Sum of all users' staked shares in this vault.
    /// @param totalEarnedUSD Lifetime USD rewards accrued by this vault.
    /// @param totalClaimedUSD Lifetime USD rewards claimed from this vault.
    /// @param totalArthaIssued Lifetime ARTHA tokens issued from this vault.
    struct VaultConfig {
        address asset;
        bool enabled;
        bool registered;
        uint256 totalShares;
        uint256 totalEarnedUSD;
        uint256 totalClaimedUSD;
        uint256 totalArthaIssued;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event VaultRegistered(address indexed vault, address indexed asset, uint256 initialRateBps);
    event VaultEnabledSet(address indexed vault, bool enabled);
    event RateUpdated(address indexed vault, uint256 oldRateBps, uint256 newRateBps, uint256 epochIndex);

    event Settled(
        address indexed vault,
        address indexed user,
        uint256 accruedUSD,
        uint256 elapsed,
        uint256 fromSharePriceUSD,
        uint256 toSharePriceUSD
    );

    event SharesChanged(address indexed vault, address indexed user, uint256 oldShares, uint256 newShares);

    event RewardClaimed(
        address indexed vault, address indexed user, uint256 usdAmount, uint256 arthaAmount, bool partial
    );

    event GlobalCapReached(uint256 totalIssued, uint256 cap);
    event ArthaPriceUpdated(uint256 oldPriceUSD, uint256 newPriceUSD);
    event RewardVaultUpdated(address indexed oldVault, address indexed newVault);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ManagerSet(address indexed manager, bool allowed);
    event StaleAfterUpdated(uint256 oldValue, uint256 newValue);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotManager();
    error NotTimelock();
    error VaultNotRegistered(address vault);
    error VaultAlreadyRegistered(address vault);
    error VaultDisabled(address vault);
    error ZeroAddress();
    error RateTooHigh(uint256 rateBps, uint256 maxRateBps);
    error NothingToClaim();
    error GlobalCapExhausted();
    error InvalidArthaPrice();
    error StalePrice(address asset, uint256 updatedAt);
    error EpochWalkTooLong(uint256 epochs, uint256 max);

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function ARTHA_MAX_REWARDS() external view returns (uint256);
    function totalArthaIssued() external view returns (uint256);
    function remainingArthaCap() external view returns (uint256);

    function getVaultConfig(address vault) external view returns (VaultConfig memory);
    function getUserStake(address vault, address user) external view returns (UserStake memory);
    function getCurrentRate(address vault) external view returns (uint256 rateBps);
    function getRateEpochs(address vault) external view returns (RateEpoch[] memory);
    function getRateEpochCount(address vault) external view returns (uint256);

    /// @notice Current share price in USD (8dp) = pricePerShare * assetPriceUSD.
    function getSharePriceUSD(address vault) external view returns (uint256);

    /// @notice Settled + unsettled reward for a user, in USD (8dp). Does not mutate.
    function pendingUSD(address vault, address user) external view returns (uint256);

    /// @notice Settled + unsettled reward for a user, converted to ARTHA. Does not mutate.
    /// @dev Reflects the global cap: returns the payable amount, not the theoretical one.
    function pendingArtha(address vault, address user) external view returns (uint256);

    /// @notice Total ARTHA issued from a single vault, lifetime.
    function vaultArthaIssued(address vault) external view returns (uint256);

    /// @notice Total ARTHA claimed by a single user across a single vault, lifetime.
    function userArthaClaimed(address vault, address user) external view returns (uint256);

    /// @notice Total ARTHA claimed by a single user across all vaults, lifetime.
    function userTotalArthaClaimed(address user) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                                MUTATIVE
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle a user's accrual up to now without changing shares.
    function settle(address vault, address user) external;

    /// @notice Vault hook. Settles at old shares, then writes new shares.
    /// @dev Manager-only. Must be called by the vault on ANY share balance change.
    function onSharesChanged(address vault, address user, uint256 oldShares, uint256 newShares) external;

    /// @notice Settle and pay out the caller's ARTHA for a vault.
    function claim(address vault) external returns (uint256 arthaAmount);

    /// @notice Settle and pay out the caller's ARTHA across many vaults.
    function claimMany(address[] calldata vaults) external returns (uint256 totalArtha);
}
