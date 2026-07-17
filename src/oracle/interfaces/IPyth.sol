// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Pyth Network surface for a single price read.
/// @dev    getPriceUnsafe (not getPriceNoOlderThan) on purpose: PythSource does its
///         own staleness check so its revert reasons match ChainlinkSource's style,
///         instead of surfacing Pyth's own opaque revert.
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);
}
