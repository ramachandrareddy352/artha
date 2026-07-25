// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3UsdcStrategy} from "../../usdc/lend/AaveV3UsdcStrategy.sol";

/**
 * @title  AaveV3UsdtStrategy  —  USDT deployment of the Aave V3 lending adapter
 * @notice Supplies USDT to Aave V3 for borrower interest via rebasing aUSDT. Logic is
 *         token-agnostic (lives in AaveV3UsdcStrategy); this names the USDT deployment.
 *
 *   invest/value/withdraw/harvest : identical to the USDC adapter, on the USDT market.
 *   yield  : USDT borrower interest — typically the highest stablecoin lending APR of
 *            the three (USDT borrow demand runs hot), so a strong "do first" for USDT.
 *   note   : USDT's non-standard ERC20 (no return bool) is handled by SafeERC20 in the
 *            base — no special casing needed here.
 */
contract AaveV3UsdtStrategy is AaveV3UsdcStrategy {
    constructor(
        address _vault,
        address _usdt,
        address _oracle,
        address _swapper,
        address _pool,
        address _aUsdt
    ) AaveV3UsdcStrategy(_vault, _usdt, _oracle, _swapper, _pool, _aUsdt) {}
}
