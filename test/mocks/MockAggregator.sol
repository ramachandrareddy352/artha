// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockAggregator {
    int256 private _answer;
    uint80 private _roundId = 1;

    uint256 private _staleBy;
    bool private _zeroUpdatedAt;
    bool private _zeroStartedAt;
    bool private _futureTimestamp;
    int256 private _answeredInRoundDelta;

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

    function setStaleBy(uint256 secondsAgo) external {
        _staleBy = secondsAgo;
    }

    function setZeroUpdatedAt(bool on) external {
        _zeroUpdatedAt = on;
    }

    function setZeroStartedAt(bool on) external {
        _zeroStartedAt = on;
    }

    function setFutureTimestamp(bool on) external {
        _futureTimestamp = on;
    }

    function setAnsweredInRoundBehind(bool on) external {
        _answeredInRoundDelta = on ? -1 : int256(0);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        updatedAt = block.timestamp > _staleBy ? block.timestamp - _staleBy : 0;
        if (_futureTimestamp) updatedAt = block.timestamp + 1 hours;
        if (_zeroUpdatedAt) updatedAt = 0;

        startedAt = _zeroStartedAt ? 0 : updatedAt;

        answeredInRound = _answeredInRoundDelta < 0 ? _roundId - 1 : _roundId;
        return (_roundId, _answer, startedAt, updatedAt, answeredInRound);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}
