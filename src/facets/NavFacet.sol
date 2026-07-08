// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Modifiers} from "../libraries/LibAppStorage.sol";
import {LibNav} from "../libraries/LibNav.sol";
import {LibShares} from "../libraries/LibShares.sol";

/**
 * @title  NavFacet
 * @notice Read-only NAV surface: total assets and price-per-share per pool.
 */
contract NavFacet is Modifiers {
    /// @notice USDC (6dp) value of everything the pool holds (idle + basket + strategies).
    function totalAssets(uint8 poolId) external view validPool(poolId) returns (uint256) {
        return LibNav.totalAssets(poolId);
    }

    /// @notice Price per share, scaled by 1e18.
    function pricePerShare(uint8 poolId) external view validPool(poolId) returns (uint256) {
        return LibShares.pricePerShare(poolId);
    }
}
