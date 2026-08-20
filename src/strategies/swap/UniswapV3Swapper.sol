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
 *   `minOut` is the strategy's oracle floor, passed straight to amountOutMinimum.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE PATH IS CHECKED AGAINST THE REQUESTED PAIR
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  A V3 path is opaque packed bytes, and the router happily honours one that ends in a
 *  token nobody asked for — `amountOutMinimum` would then be enforced against THAT
 *  token, so a mis-set route could satisfy the router while delivering the caller
 *  nothing it can use. So the first and last 20 bytes of the path are decoded and
 *  required to equal `tokenIn`/`tokenOut`, and the output is measured as the caller's
 *  own balance delta rather than taken from the router's return value.
 */
contract UniswapV3Swapper is ISwapper {
    using SafeERC20 for IERC20;

    /// @dev A path is 20-byte tokens separated by 3-byte fees: 20 + n*(3 + 20).
    uint256 private constant ADDR_SIZE = 20;
    uint256 private constant FEE_SIZE = 3;

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
        require(data.length >= ADDR_SIZE + FEE_SIZE + ADDR_SIZE, "PATH_TOO_SHORT");
        require((data.length - ADDR_SIZE) % (FEE_SIZE + ADDR_SIZE) == 0, "BAD_PATH_SHAPE");
        require(_tokenAt(data, 0) == tokenIn, "PATH_IN_MISMATCH");
        require(_tokenAt(data, data.length - ADDR_SIZE) == tokenOut, "PATH_OUT_MISMATCH");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        uint256 balBefore = IERC20(tokenOut).balanceOf(msg.sender);
        router.exactInput(
            ISwapRouterV3.ExactInputParams({
                path: data,
                recipient: msg.sender, // deliver straight back to the strategy
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );
        amountOut = IERC20(tokenOut).balanceOf(msg.sender) - balBefore;

        require(amountOut >= minOut, "MIN_OUT");
        IERC20(tokenIn).forceApprove(address(router), 0);
    }

    /// @dev The 20-byte address starting at `offset` of a packed V3 path.
    function _tokenAt(bytes calldata path, uint256 offset) private pure returns (address token) {
        assembly {
            token := shr(96, calldataload(add(path.offset, offset)))
        }
    }
}
