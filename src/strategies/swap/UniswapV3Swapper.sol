// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapper} from "../interfaces/ISwapper.sol";

interface ISwapRouterV3 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title  UniswapV3Swapper
 * @notice ISwapper over Uniswap V3 (works for any Uni-V3-fork router). Best for
 *         volatile reward tokens (CRV, CVX, COMP, BAL, ...) where a multi-hop path
 *         through WETH gives the deepest liquidity.
 *
 *   data = the encoded V3 path bytes:
 *          abi.encodePacked(tokenIn, fee0, mid, fee1, tokenOut)   (multi-hop)
 *          or abi.encodePacked(tokenIn, fee, tokenOut)            (single-hop)
 *   The path's first token MUST be tokenIn and last MUST be tokenOut.
 *   `minOut` is the strategy's oracle floor, passed straight to amountOutMinimum.
 */
contract UniswapV3Swapper is ISwapper {
    using SafeERC20 for IERC20;

    ISwapRouterV3 public immutable router;

    constructor(address _router) {
        require(_router != address(0), "ZERO_ADDR");
        router = ISwapRouterV3(_router);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata data)
        external
        override
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        amountOut = router.exactInput(
            ISwapRouterV3.ExactInputParams({
                path: data,
                recipient: msg.sender, // deliver straight back to the strategy
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );

        require(amountOut >= minOut, "MIN_OUT");
        IERC20(tokenIn).forceApprove(address(router), 0);
    }
}
