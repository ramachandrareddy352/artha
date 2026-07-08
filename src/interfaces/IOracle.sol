// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IOracle — separate price oracle (Chainlink+Pyth aggregator, batch 4).
interface IOracle {
    /// @return usdcValue USDC (6dp) value of `amount` raw `token`.
    function valueInUsdc(address token, uint256 amount) external view returns (uint256 usdcValue);
    /// @return tokenAmount raw `token` amount worth `usdcValue` USDC (6dp). (reverse of valueInUsdc)
    function amountForUsdc(address token, uint256 usdcValue) external view returns (uint256 tokenAmount);
    /// @return usdcPer1e18Token USDC per whole token, scaled 1e18.
    function price(address token) external view returns (uint256 usdcPer1e18Token);
}
