// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISwapper} from "../../interfaces/ISwapper.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  AggregatorSwapper
 * @notice Executes a swap using pre-built calldata from an off-chain aggregator
 *         (1inch / 0x / CoW / Paraswap). The Diamond's backend fetches the best
 *         route and passes the router calldata as `data`; this adapter forwards it
 *         to a single whitelisted `aggregator` router.
 *
 *  SAFETY: the target is a fixed, governance-set router (not arbitrary), and the
 *  adapter measures tokenOut received and returns it, so the AllocationFacet's
 *  oracle value-floor + `minOut` still bind regardless of what the calldata claims.
 *  Any tokenIn dust left after the swap is returned to the caller.
 */
contract AggregatorSwapper is ISwapper {
    using SafeERC20 for IERC20;

    address public immutable aggregator; // e.g. 1inch AggregationRouterV6

    constructor(address _aggregator) {
        require(_aggregator != address(0), "ZERO_ADDR");
        aggregator = _aggregator;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata data)
        external
        override
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(aggregator, amountIn);

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        (bool ok, bytes memory ret) = aggregator.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
        require(amountOut >= minOut, "MIN_OUT");

        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        // return any unspent tokenIn and clear approval
        IERC20(tokenIn).forceApprove(aggregator, 0);
        uint256 leftover = IERC20(tokenIn).balanceOf(address(this));
        if (leftover != 0) IERC20(tokenIn).safeTransfer(msg.sender, leftover);
    }
}
