// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IAggregatorV3.sol";

/// @notice Chainlink price source. Feeds registered with this MUST already report
///         8-decimal USD prices -- see IAggregatorV3 for why this never rescales.
contract ChainlinkSource {
    function getChainlinkPrice(address _feed, uint256 _maxAge) internal view returns (uint256) {
        (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(_feed).latestRoundData();

        require(price > 0, "INVALID_PRICE");
        require(updatedAt != 0, "ROUND_INCOMPLETE"); // round not yet finalised
        require(startedAt != 0, "ROUND_NOT_STARTED"); // defensive: incomplete round
        require(updatedAt <= block.timestamp, "FUTURE_TIMESTAMP"); // reject future-dated answers
        require(answeredInRound >= roundId, "STALE_ROUND"); // answer is from a stale round

        // Safe now that updatedAt <= block.timestamp (no underflow), and correct
        // staleness direction (large _maxAge can no longer overflow the RHS).
        require(block.timestamp - updatedAt <= _maxAge, "STALE_PRICE");

        return uint256(price);
    }
}
