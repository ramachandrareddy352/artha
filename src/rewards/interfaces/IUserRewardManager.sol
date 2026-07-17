// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal view surface the reward system needs from a vault.
interface IRewardableVault {
    /// @notice Underlying asset held by the vault.
    function asset() external view returns (address);

    /// @notice Price of one share denominated in the underlying asset, scaled to 1e18.
    /// @dev MUST be derived from totalAssets()/totalSupply(), not admin-written.
    function pricePerShare() external view returns (uint256);

    /// @notice Shares held by `user`.
    function balanceOf(address user) external view returns (uint256);
}

/// @notice Local Chainlink wrapper. Returns USD price at 8 decimals.
interface ILocalOracle {
    /// @param baseAsset Token address to price.
    /// @return price USD price, 8 decimals.
    function getPrice(address baseAsset) external view returns (uint256 price);

    /// @param baseAsset Token address to price.
    /// @return price     USD price, 8 decimals.
    /// @return updatedAt Timestamp of the underlying feed's last update.
    function getPriceWithTimestamp(address baseAsset) external view returns (uint256 price, uint256 updatedAt);
}

/// @title IUserRewardManager
/// @notice Entry point + admin surface. Vaults call this; users claim through this.
interface IUserRewardManager {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event VaultAuthorized(address indexed vault, bool authorized);
    event SystemUpdated(address indexed oldSystem, address indexed newSystem);
    event TimelockUpdated(address indexed oldTimelock, address indexed newTimelock);
    event PausedSet(bool paused);
    event HookFailed(address indexed vault, address indexed user, bytes reason);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorizedVault(address caller);
    error NotTimelock();
    error ZeroAddress();
    error SystemPaused();

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function system() external view returns (address);
    function timelock() external view returns (address);
    function isAuthorizedVault(address vault) external view returns (bool);
    function paused() external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                              VAULT HOOK
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by an authorized vault on any share balance change.
    /// @dev Non-reverting by design: wraps the settle in try/catch so a bad oracle
    ///      can never brick vault deposits or withdrawals.
    function onSharesChanged(address user, uint256 oldShares, uint256 newShares) external;

    /*//////////////////////////////////////////////////////////////
                                 USER
    //////////////////////////////////////////////////////////////*/

    function claim(address vault) external returns (uint256 arthaAmount);
    function claimMany(address[] calldata vaults) external returns (uint256 totalArtha);
    function settle(address vault, address user) external;

    /*//////////////////////////////////////////////////////////////
                             ADMIN (TIMELOCK)
    //////////////////////////////////////////////////////////////*/

    function registerVault(address vault, uint256 initialRateBps) external;
    function setVaultRate(address vault, uint256 newRateBps) external;
    function setVaultEnabled(address vault, bool enabled) external;
    function setArthaPriceUSD(uint256 priceUSD) external;
    function setOracle(address oracle) external;
    function setRewardVault(address rewardVault) external;
    function setStaleAfter(uint256 seconds_) external;
    function setPaused(bool paused) external;
}
