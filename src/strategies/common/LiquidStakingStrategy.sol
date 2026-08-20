// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {HoldStrategy} from "./HoldStrategy.sol";

/**
 * @title  LiquidStakingStrategy — hold a staking token, value it by its own rate
 * @notice A `HoldStrategy` for liquid-staking tokens (wstETH, rETH, sfrxETH, ...). The
 *         held token is bought and sold on the MARKET through the swapper, but valued
 *         by the protocol's OWN exchange rate — which only ever climbs, as validator
 *         rewards accrue. That climb IS the yield: there is no reward token, no
 *         emission to sell, and nothing to harvest.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WETH IN, WETH OUT — NEVER NATIVE ETH
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Entry and exit go through the swapper on a deep WETH/LST pool. This strategy never
 *  touches native ETH: it does not wrap, unwrap, hold a balance, or expose a `receive`
 *  — there is no payable surface anywhere in it. That also means it deliberately
 *  SKIPS the protocols' native mint/withdrawal queues (Lido's takes days, Rocket's
 *  depends on deposit-pool capacity); market liquidity for these tokens is deep and
 *  instant, and an exit that can block for days is not an exit a vault can rely on.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE CONSERVATIVE-VALUATION RULE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Two numbers describe what an LST is worth, and they disagree exactly when it
 *  matters: the NATIVE rate (what the protocol says a share of stake is worth) and the
 *  MARKET price (what someone will actually pay today). In the June 2022 stETH
 *  dislocation the gap ran 6-8% for weeks.
 *
 *  So this always takes the LOWER of the two, in both directions:
 *
 *    valuing the position  -> the lower number, so NAV never carries a premium the
 *                             vault could not realize by selling.
 *    flooring a swap       -> the lower number, so `minOut` is a floor the trade can
 *                             actually clear rather than an optimistic target that
 *                             reverts every harvest during a dislocation.
 *
 *  If the market price is unavailable (no oracle configured for the LST), the native
 *  rate stands alone — reverting valuation would trip the vault's breaker and pause it.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   RISK
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Validator slashing (small, tail), and the dislocation above — during which an exit
 *  realizes less than the native rate implies. `maxSlippageBps` bounds a single trade;
 *  it does not bound a sustained discount. This belongs in a higher-risk tier than
 *  plain WETH lending.
 */
abstract contract LiquidStakingStrategy is HoldStrategy {
    constructor(address _vault, address _weth, address _oracle, address _swapper, address _lst)
        HoldStrategy(_vault, _weth, _oracle, _swapper, _lst)
    {}

    /// @dev The protocol's own rate: `lstAmount` -> base (WETH) units.
    function _nativeToBase(uint256 lstAmount) internal view virtual returns (uint256);

    /// @dev The protocol's own rate, inverted: `baseAmount` (WETH) -> LST units.
    function _nativeToHeld(uint256 baseAmount) internal view virtual returns (uint256);

    /// @inheritdoc HoldStrategy
    function _heldToBase(uint256 amount) internal view override returns (uint256) {
        uint256 native = _nativeToBase(amount);
        (bool ok, uint256 market) = _tryConvert(address(held), heldDecimals, amount, address(asset), assetDecimals);
        return (ok && market < native) ? market : native;
    }

    /// @inheritdoc HoldStrategy
    function _baseToHeld(uint256 amount) internal view override returns (uint256) {
        uint256 native = _nativeToHeld(amount);
        (bool ok, uint256 market) = _tryConvert(address(asset), assetDecimals, amount, address(held), heldDecimals);
        return (ok && market < native) ? market : native;
    }

    /// @notice The two valuations side by side, for monitoring the dislocation the rule
    ///         above exists to survive. Equal in normal conditions.
    /// @return nativeValue  one whole LST in base units, per the protocol's rate
    /// @return marketValue  the same, per the oracle. 0 when unconfigured.
    function valuationSpread() external view returns (uint256 nativeValue, uint256 marketValue) {
        uint256 one = 10 ** heldDecimals;
        nativeValue = _nativeToBase(one);
        (, marketValue) = _tryConvert(address(held), heldDecimals, one, address(asset), assetDecimals);
    }
}
