// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Local Chainlink wrapper. Returns USD price at 8 decimals.
/// @dev Same shape the referral stack uses -- one oracle serves both stacks.
interface IOracle {
    function getPrice(address baseAsset) external view returns (uint256);
}

/// @notice The one view the reward stack needs from an Artha vault.
interface IArthaVault {
    /// @notice Price of one share denominated in the base asset, scaled to 1e18.
    /// @dev MUST be derived from totalAssets()/totalSupply(). If this is ever an
    ///      admin-written number, whoever holds that key can mint ARTHA at will --
    ///      the entire reward book is priced off it.
    function pricePerShare() external view returns (uint256);
}

/**
 * @title IUserRewardVault
 * @notice Integration surface for the user-staking-reward stack.
 *
 *  Vault layer:  call notifyShareChange() whenever shares move OUTSIDE stake()/
 *                unstake() -- transfers, mints, burns. Read getInfo() for display.
 *  Front-end:    getInfo() / pendingOf() for a position, vaultBooks() for a vault,
 *                globalBooks() for the programme.
 */
interface IUserRewardVault {
    // ── vault integration ──

    /// @notice Report a share movement the vault performed. msg.sender MUST == vault.
    /// @dev Never reverts on accrual failure; emits SettleFailed instead, so a stale
    ///      oracle cannot brick the vault's deposit/withdraw path.
    function notifyShareChange(address vault, address user, uint256 oldShares, uint256 newShares) external;

    /// @notice Everything the front-end needs about one position, in one call.
    /// @return stakedShares Shares currently staked.
    /// @return pendingUSD   Settled + unsettled USD, 18dp.
    /// @return pendingArtha What claiming right now would ACTUALLY pay (cap included).
    /// @return rateBps      The vault's APR in force now. 1_000 = 1%.
    /// @return stakedAt     First-ever stake timestamp.
    function getInfo(address vault, address user)
        external
        view
        returns (uint256 stakedShares, uint256 pendingUSD, uint256 pendingArtha, uint256 rateBps, uint256 stakedAt);

    // ── user ──

    function stake(address vault, uint256 amount) external;
    function unstake(address vault, uint256 amount) external;
    function settle(address vault, address user) external;
    function claimArtha(address vault, address to, uint256 amount) external;
    function claimAll(address to) external;

    // ── views ──

    function artha() external view returns (address);
    function arthaRemaining() external view returns (uint256);
    function sharePriceUSD(address vault) external view returns (uint256);
    function currentRate(address vault) external view returns (uint256);
    function stakedShares(address vault, address user) external view returns (uint256);

    function pendingOf(address vault, address user)
        external
        view
        returns (uint256 pendingUSD, uint256 pendingArtha);

    function pendingAll(address user)
        external
        view
        returns (address[] memory vaults, uint256[] memory usdAmounts, uint256 totalPendingArtha);

    function vaultBooks(address vault)
        external
        view
        returns (
            address shareToken,
            uint256 rateBps,
            uint256 arthaRatio,
            uint256 stakedShares_,
            uint256 earnedUSD,
            uint256 arthaIssued
        );

    function globalBooks()
        external
        view
        returns (
            uint256 arthaMinted,
            uint256 arthaClaimed,
            uint256 outstandingArtha,
            uint256 arthaLeftInBudget,
            uint256 usdEarned,
            uint256 usdClaimed
        );

    function arthaIssuedPerVault() external view returns (address[] memory vaults, uint256[] memory issued);

    // ── admin ──

    function registerVault(address vault, address shareToken, uint8 decimals, uint256 rateBps, uint256 arthaRatio)
        external;
    function setRewardRate(address vault, uint256 rateBps) external;
    function setArthaRatio(address vault, uint256 arthaRatio) external;
    function setOracle(address newOracle) external;
    function rescue(address token, address to, uint256 amount) external;
}
