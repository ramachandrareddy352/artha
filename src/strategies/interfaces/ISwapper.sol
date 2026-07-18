// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISwapper
 * @notice Execution-only reward-selling primitive. A strategy hands it a claimed
 *         reward token to convert to base; `data` carries the venue-specific route
 *         (which pool/path). The strategy computes `minOut` from its ORACLE, never
 *         from the swap venue's own quote — that is the sandwich defence.
 *
 *  Deliberately separate from the price oracle: valuation and execution have
 *  different threat models, so the swap venue's spot price must never be trusted as
 *  the oracle.
 */
interface ISwapper {
    /// @param data Venue-specific route (e.g. abi.encode(pool, i, j) or an aggregator payload).
    /// @return amountOut Base token actually received (measured, not claimed).
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata data)
        external
        returns (uint256 amountOut);
}
