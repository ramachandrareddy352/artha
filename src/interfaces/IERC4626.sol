// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IERC4626 — minimal tokenized-vault interface used by the generic yield adapter.
/// @notice Covers any ERC-4626 vault: sUSDe (Ethena), sUSDS/sDAI (Sky), MetaMorpho,
///         Euler V2 EVK vaults, Fluid fTokens, Yearn V3, and most yield-bearing stables.
interface IERC4626 {
    function asset() external view returns (address);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    function balanceOf(address account) external view returns (uint256);
}
