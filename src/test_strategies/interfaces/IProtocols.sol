// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/* ─────────────────────────── Aave V3 ─────────────────────────── */
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAaveRewards {
    /// @return rewardsList tokens claimed, claimedAmounts matching amounts
    function claimAllRewards(address[] calldata assets, address to)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}

/* ─────────────────────────── Compound V3 (Comet) ─────────────────────────── */
interface IComet is IERC20 {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function baseToken() external view returns (address);
    // Comet.balanceOf(account) returns the supplied base balance (present value)
}

interface ICometRewards {
    function claim(address comet, address src, bool shouldAccrue) external;
}

/* ─────────────────────────── Curve (2-coin example) ─────────────────────────── */
interface ICurvePool {
    function add_liquidity(uint256[2] calldata amounts, uint256 minMintAmount) external returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/* ─────────────────────────── Convex ─────────────────────────── */
interface IConvexBooster {
    function deposit(uint256 pid, uint256 amount, bool stake) external returns (bool);
}

interface IConvexRewards {
    function getReward() external returns (bool);
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
    function balanceOf(address account) external view returns (uint256); // staked LP amount
}

/* ─────────────────────────── Uniswap V3 router ─────────────────────────── */
interface ISwapRouter {
    struct ExactInputParams {
        bytes path;            // abi.encodePacked(tokenIn, fee, [mid, fee,] tokenOut)
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
