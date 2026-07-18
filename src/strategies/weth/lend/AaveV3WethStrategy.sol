// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3UsdcStrategy} from "../../usdc/lend/AaveV3UsdcStrategy.sol";

/**
 * @title  AaveV3WethStrategy  —  WETH deployment of the Aave V3 lending adapter
 * @notice Supplies WETH to Aave V3 and earns borrower interest via rebasing aWETH.
 *         The Aave adapter is fully token-agnostic (asset, pool, aToken are all
 *         constructor args); this file exists only to name and document the WETH
 *         deployment. All lifecycle logic lives in AaveV3UsdcStrategy.
 *
 *   invest   : pool.supply(WETH, amount, this, 0) -> rebasing aWETH
 *   value    : aWETH.balanceOf(this) (already WETH-denominated)
 *   withdraw : pool.withdraw(WETH, amount, this), instant up to Aave liquidity
 *   harvest  : usually a no-op (Aave's WETH market runs no incentives); if a market
 *              does, set the rewards controller and it claims + sells to WETH.
 *   yield    : ETH borrower interest. Lower base APR than stables, but this is the
 *              instant-liquid WETH workhorse and the buffer venue for the WETH vault.
 */
contract AaveV3WethStrategy is AaveV3UsdcStrategy {
    constructor(
        address _vault,
        address _weth,
        address _oracle,
        address _swapper,
        address _pool,
        address _aWeth
    ) AaveV3UsdcStrategy(_vault, _weth, _oracle, _swapper, _pool, _aWeth) {}
}
