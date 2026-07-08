// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStrategy — per-venue LEND adapter (Aave/Compound/Morpho).
/// @notice A singleton adapter serves all pools; positions are tracked per poolId
///         via internal shares, so `totalValue`, `withdrawShares`, etc. are per-pool.
interface IStrategy {
    function underlying() external view returns (address);

    function totalValue(uint8 poolId) external view returns (uint256 usdcValue);
    function poolShares(uint8 poolId) external view returns (uint256);
    function totalPoolShares() external view returns (uint256);

    /// @notice Vault-only: pull `amount` underlying from the vault and supply it.
    function deposit(uint8 poolId, uint256 amount) external;

    /// @notice Vault-only: redeem ~`amount` underlying for the pool, send to vault.
    function withdraw(uint8 poolId, uint256 amount) external returns (uint256 withdrawn);

    /// @notice Vault-only: redeem a share amount of the pool's position, send to vault.
    function withdrawShares(uint8 poolId, uint256 shareAmount) external returns (uint256 withdrawn);

    /// @notice Vault-only: claim & compound any reward emissions.
    function harvest(uint8 poolId) external returns (uint256 rewards);
}
