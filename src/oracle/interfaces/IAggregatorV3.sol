// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Chainlink AggregatorV3 surface.
/// @dev    Feeds registered against this MUST already report 8-decimal USD prices --
///         ChainlinkSource does not read decimals() or rescale by it, matching how
///         Chainlink's own USD pairs are published.
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
