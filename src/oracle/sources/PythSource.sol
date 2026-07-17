// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPyth.sol";

/// @notice Pyth Network price source. Normalizes Pyth's native (price, expo) pair to
///         PriceFeed's fixed 8-decimal format regardless of a feed's actual exponent
///         (Pyth USD feeds commonly use expo = -8, but this does not assume it).
contract PythSource {
    function getPythPrice(address _pyth, bytes32 _priceId, uint256 _maxAge) internal view returns (uint256) {
        IPyth.Price memory p = IPyth(_pyth).getPriceUnsafe(_priceId);

        require(p.price > 0, "INVALID_PRICE");
        require(p.publishTime != 0, "ROUND_INCOMPLETE");
        require(p.publishTime <= block.timestamp, "FUTURE_TIMESTAMP");
        require(block.timestamp - p.publishTime <= _maxAge, "STALE_PRICE");

        return _to8Decimals(uint256(uint64(p.price)), p.expo);
    }

    /// @dev Pyth's actual price is `price * 10^expo`. We want that expressed at 1e8,
    ///      i.e. `price * 10^(expo + 8)`.
    function _to8Decimals(uint256 _price, int32 _expo) private pure returns (uint256) {
        int256 shift = int256(_expo) + 8;
        if (shift >= 0) {
            return _price * (10 ** uint256(shift));
        }
        return _price / (10 ** uint256(-shift));
    }
}
