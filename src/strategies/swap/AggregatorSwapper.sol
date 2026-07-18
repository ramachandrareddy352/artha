// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapper} from "../interfaces/ISwapper.sol";

/**
 * @title  AggregatorSwapper
 * @notice ISwapper that forwards a pre-built off-chain aggregator payload (1inch, 0x,
 *         CoW, Paraswap, OpenOcean, ...) to ONE whitelisted router. Best real-world
 *         execution: the keeper fetches optimal routing off-chain and passes the
 *         calldata in `data`.
 *
 *   data = the router calldata produced by the aggregator's API for this exact swap.
 *
 *   SAFETY MODEL:
 *    - Only the single `router` set at construction can be called (an arbitrary-call
 *      surface pointed at an attacker contract would be a drain — so it is pinned).
 *    - The calldata's CLAIMED output is ignored; the swapper measures the tokenOut
 *      actually received and enforces the strategy's oracle-derived `minOut`. A
 *      malicious or stale payload can at worst revert, never underpay past the floor.
 *    - Approval is set to exactly amountIn and reset to 0 after.
 */
contract AggregatorSwapper is ISwapper {
    using SafeERC20 for IERC20;

    address public immutable router;

    constructor(address _router) {
        require(_router != address(0), "ZERO_ADDR");
        router = _router;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata data)
        external
        override
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(router, amountIn);

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));
        (bool ok,) = router.call(data);
        require(ok, "SWAP_FAILED");
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;

        require(amountOut >= minOut, "MIN_OUT");
        IERC20(tokenIn).forceApprove(router, 0);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
