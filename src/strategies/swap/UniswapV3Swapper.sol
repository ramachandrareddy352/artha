// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISwapper} from "../../interfaces/ISwapper.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

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
 * @notice Executes swaps on Uniswap V3. `data` selects the route:
 *           - empty or abi.encode(uint24 fee): single-hop exactInputSingle
 *           - abi.encode(bytes path): multi-hop exactInput (path is the V3 encoded path)
 *
 *  Pulls tokenIn from msg.sender (the Diamond), swaps, sends tokenOut back to it.
 *  The caller (AllocationFacet) also enforces an oracle value-floor on top of
 *  `minOut`, so this adapter just needs to honour minOut at the DEX level.
 */
contract UniswapV3Swapper is ISwapper {
    using SafeERC20 for IERC20;

    ISwapRouter02 public immutable router;
    uint24 public constant DEFAULT_FEE = 3000; // 0.3%

    constructor(address _router) {
        require(_router != address(0), "ZERO_ADDR");
        router = ISwapRouter02(_router);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata data)
        external
        override
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        if (data.length > 32) {
            // multi-hop: data is an abi-encoded bytes path
            bytes memory path = abi.decode(data, (bytes));
            amountOut = router.exactInput(
                ISwapRouter02.ExactInputParams({
                    path: path,
                    recipient: msg.sender,
                    amountIn: amountIn,
                    amountOutMinimum: minOut
                })
            );
        } else {
            uint24 fee = data.length == 32 ? abi.decode(data, (uint24)) : DEFAULT_FEE;
            amountOut = router.exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: msg.sender,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        IERC20(tokenIn).forceApprove(address(router), 0);
    }
}
