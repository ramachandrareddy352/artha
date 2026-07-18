// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapper} from "../interfaces/ISwapper.sol";

interface ICurvePoolExchange {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

/**
 * @title  CurveSwapper
 * @notice ISwapper over a Curve StableSwap pool — the low-slippage route for
 *         stable<->stable legs (and reward tokens that pair well on Curve).
 *
 *   data = abi.encode(address pool, int128 i, int128 j)
 *   flow : pull tokenIn from the caller (the strategy) -> exchange -> return tokenOut.
 *          `minOut` is the strategy's ORACLE-derived floor, enforced here too.
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
        ICurvePoolExchange(pool).exchange(i, j, amountIn, minOut);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;

        require(amountOut >= minOut, "MIN_OUT");
        IERC20(tokenIn).forceApprove(pool, 0);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
