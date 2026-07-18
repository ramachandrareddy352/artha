// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapper} from "../interfaces/ISwapper.sol";

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
        address payable recipient;
        bool toInternalBalance;
    }

    function swap(SingleSwap calldata singleSwap, FundManagement calldata funds, uint256 limit, uint256 deadline)
        external
        payable
        returns (uint256 amountCalculated);
}

/**
 * @title  BalancerV2Swapper
 * @notice ISwapper over the Balancer V2 Vault, GIVEN_IN single-pool swap. Useful for
 *         reward tokens (BAL, AURA) and assets whose deepest venue is a Balancer pool.
 *
 *   data = abi.encode(bytes32 poolId)   the pool to route through
 *   `minOut` (oracle floor) becomes the swap `limit` (min amount out for GIVEN_IN).
 *
 *   NOTE: verify the IBalancerVault ABI against the live deployment before use — the
 *   struct layout is stable across mainnets but confirm for your target chain.
 */
contract BalancerV2Swapper is ISwapper {
    using SafeERC20 for IERC20;

    IBalancerVault public immutable balancerVault;

    constructor(address _balancerVault) {
        require(_balancerVault != address(0), "ZERO_ADDR");
        balancerVault = IBalancerVault(_balancerVault);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata data)
        external
        override
        returns (uint256 amountOut)
    {
        bytes32 poolId = abi.decode(data, (bytes32));

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(balancerVault), amountIn);

        IBalancerVault.SingleSwap memory s = IBalancerVault.SingleSwap({
            poolId: poolId,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: tokenIn,
            assetOut: tokenOut,
            amount: amountIn,
            userData: ""
        });
        IBalancerVault.FundManagement memory f = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(msg.sender), // deliver straight to the strategy
            toInternalBalance: false
        });

        amountOut = balancerVault.swap(s, f, minOut, block.timestamp);
        require(amountOut >= minOut, "MIN_OUT");
        IERC20(tokenIn).forceApprove(address(balancerVault), 0);
    }
}
