// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Modifiers} from "../libraries/LibAppStorage.sol";
import {LibShares} from "../libraries/LibShares.sol";

/**
 * @title  AccountingFacet
 * @notice ERC-4626-style conversion + balance views. Share mint/burn itself is
 *         done inside PoolFacet/BatchFacet; this facet exposes the read helpers.
 */
contract AccountingFacet is Modifiers {
    function convertToShares(uint8 poolId, uint256 assets) external view validPool(poolId) returns (uint256) {
        return LibShares.convertToShares(poolId, assets);
    }

    function convertToAssets(uint8 poolId, uint256 shares) external view validPool(poolId) returns (uint256) {
        return LibShares.convertToAssets(poolId, shares);
    }

    /// @notice Shares a deposit of `assets` would receive at the current NAV.
    function previewDeposit(uint8 poolId, uint256 assets) external view validPool(poolId) returns (uint256) {
        return LibShares.convertToShares(poolId, assets);
    }

    /// @notice USDC a redemption of `shares` is worth at the current NAV (before penalty).
    function previewRedeem(uint8 poolId, uint256 shares) external view validPool(poolId) returns (uint256) {
        return LibShares.convertToAssets(poolId, shares);
    }

    function totalShares(uint8 poolId) external view returns (uint256) {
        return s.totalShares[poolId];
    }

    function sharesOf(uint8 poolId, address account) external view returns (uint256) {
        return s.shares[poolId][account];
    }

    function idleUsdc(uint8 poolId) external view returns (uint256) {
        return s.idleUsdc[poolId];
    }
}
