// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISwapper} from "../../interfaces/ISwapper.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICurvePool {
    // classic StableSwap signature; `i`,`j` are coin indices
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

/**
 * @title  CurveSwapper
 * @notice Swaps via a Curve StableSwap pool — ideal for stable<->stable legs with
 *         low slippage. `data` = abi.encode(address pool, int128 i, int128 j),
 *         identifying the pool and the in/out coin indices for this pair.
 *
 *  Pulls tokenIn, exchanges, sends tokenOut back to the caller (the Diamond).
 */
contract CurveSwapper is ISwapper {
    using SafeERC20 for IERC20;

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata data)
        external
        override
        returns (uint256 amountOut)
    {
        (address pool, int128 i, int128 j) = abi.decode(data, (address, int128, int128));

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(pool, amountIn);

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        ICurvePool(pool).exchange(i, j, amountIn, minOut);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;

        require(amountOut >= minOut, "MIN_OUT");
        IERC20(tokenIn).forceApprove(pool, 0);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
