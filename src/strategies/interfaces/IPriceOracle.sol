// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Read-only USD price feed used to value reward tokens and to derive swap
///         floors. Satisfied by oracle/PriceFeed.getPrice(token), which returns an
///         8-decimal USD price. Kept minimal and local so strategies do not couple to
///         a specific oracle implementation.
interface IPriceOracle {
    /// @return price USD price of `token`, 8 decimals.
    function getPrice(address token) external view returns (uint256 price);
}
