// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal ERC-4626 tokenized-vault surface. Any yield-bearing wrapper token
///         (sUSDS, sUSDe, sDAI, sFRAX, a MetaMorpho vault, a Yearn V3 vault, ...)
///         exposes this — which is why a single wrapper strategy covers all of them.
interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);
    function balanceOf(address account) external view returns (uint256);
}
