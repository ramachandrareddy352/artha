// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage, LibAppStorage} from "./LibAppStorage.sol";
import {LibNav} from "./LibNav.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title  LibShares
 * @notice ERC-4626 share math with OpenZeppelin's virtual-offset defense against
 *         the first-depositor / donation inflation attack. Adding virtual shares
 *         (10^offset) and a virtual asset (1) makes it economically impossible to
 *         seed 1 wei and round a victim's mint to zero.
 *
 *      shares = assets * (supply + 10^offset) / (totalAssets + 1)      [round down]
 *      assets = shares * (totalAssets + 1) / (supply + 10^offset)      [round down]
 */
library LibShares {
    uint256 internal constant PPS_SCALE = 1e18;

    function convertToShares(uint8 poolId, uint256 assets) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 supply = s.totalShares[poolId];
        uint256 ta = LibNav.totalAssets(poolId);
        uint256 offset = 10 ** s.decimalsOffset;
        return Math.mulDiv(assets, supply + offset, ta + 1);
    }

    function convertToAssets(uint8 poolId, uint256 shares) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 supply = s.totalShares[poolId];
        uint256 ta = LibNav.totalAssets(poolId);
        uint256 offset = 10 ** s.decimalsOffset;
        return Math.mulDiv(shares, ta + 1, supply + offset);
    }

    /// @notice Price per share scaled by 1e18 (consistent with the virtual offset).
    function pricePerShare(uint8 poolId) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 supply = s.totalShares[poolId];
        uint256 ta = LibNav.totalAssets(poolId);
        uint256 offset = 10 ** s.decimalsOffset;
        return Math.mulDiv(ta + 1, PPS_SCALE, supply + offset);
    }
}
