// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockAggregator {
    int256 private _answer;
    uint80 private _roundId = 1;

    constructor(int256 answer8dp) {
        _answer = answer8dp;
    }

    function setAnswer(int256 answer8dp) external {
        _answer = answer8dp;
        _roundId++;
    }

    function moveBps(int256 bps) external {
        _answer = bps >= 0
            ? (_answer * int256(10_000 + uint256(bps))) / 10_000
            : (_answer * int256(10_000 - uint256(-bps))) / 10_000;
        _roundId++;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, block.timestamp, block.timestamp, _roundId);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}
