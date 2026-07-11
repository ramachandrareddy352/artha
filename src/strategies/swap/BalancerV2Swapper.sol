// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISwapper} from "../../interfaces/ISwapper.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBalancerVault {
    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address recipient;
        bool toInternalBalance;
    }

    function swap(SingleSwap calldata singleSwap, FundManagement calldata funds, uint256 limit, uint256 deadline)
        external
        payable
        returns (uint256 amountCalculated);
}

/**
 * @title  BalancerV2Swapper
 * @notice Swaps through a Balancer V2 pool. `data` = abi.encode(bytes32 poolId),
 *         the id of the pool to route through. Useful for weighted/stable pools and
 *         assets with deep Balancer liquidity (e.g. wstETH, rETH, BAL/AURA pairs).
 *
 *  Pulls tokenIn from the caller (the Diamond), swaps GIVEN_IN, returns tokenOut.
 */
contract BalancerV2Swapper is ISwapper {
    using SafeERC20 for IERC20;

    IBalancerVault public immutable balancer;

    constructor(address _balancerVault) {
        require(_balancerVault != address(0), "ZERO_ADDR");
        balancer = IBalancerVault(_balancerVault);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata data)
        external
        override
        returns (uint256 amountOut)
    {
        bytes32 poolId = abi.decode(data, (bytes32));

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(balancer), amountIn);

        amountOut = balancer.swap(
            IBalancerVault.SingleSwap({
                poolId: poolId,
                kind: IBalancerVault.SwapKind.GIVEN_IN,
                assetIn: tokenIn,
                assetOut: tokenOut,
                amount: amountIn,
                userData: ""
            }),
            IBalancerVault.FundManagement({
                sender: address(this),
                fromInternalBalance: false,
                recipient: msg.sender,
                toInternalBalance: false
            }),
            minOut,
            block.timestamp
        );

        require(amountOut >= minOut, "MIN_OUT");
        IERC20(tokenIn).forceApprove(address(balancer), 0);
    }
}
