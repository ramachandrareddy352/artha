// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapper} from "../interfaces/ISwapper.sol";

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/**
 * @title  UniswapV2Swapper
 * @notice ISwapper over any Uniswap-V2-style router — PancakeSwap (BSC), SushiSwap,
 *         and the many V2 forks. Give it the router at construction.
 *
 *   data = abi.encode(address[] path)   e.g. [CAKE, WBNB, USDT]
 *          path[0] MUST be tokenIn, path[last] MUST be tokenOut.
 *   `minOut` (the strategy's oracle floor) is passed as amountOutMin; the actual
 *   received amount is measured and re-checked, then forwarded to the caller.
 */
contract UniswapV2Swapper is ISwapper {
    using SafeERC20 for IERC20;

    IUniswapV2Router public immutable router;

    constructor(address _router) {
        require(_router != address(0), "ZERO_ADDR");
        router = IUniswapV2Router(_router);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata data)
        external
        override
        returns (uint256 amountOut)
    {
        address[] memory path = abi.decode(data, (address[]));
        require(path.length >= 2 && path[0] == tokenIn && path[path.length - 1] == tokenOut, "BAD_PATH");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        uint256 balBefore = IERC20(tokenOut).balanceOf(msg.sender);
        router.swapExactTokensForTokens(amountIn, minOut, path, msg.sender, block.timestamp);
        amountOut = IERC20(tokenOut).balanceOf(msg.sender) - balBefore;

        require(amountOut >= minOut, "MIN_OUT");
        IERC20(tokenIn).forceApprove(address(router), 0);
    }
}
