// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  SkySDaiStrategy — the DAI vault's "do first": the Sky Savings Rate
 * @notice Deposits DAI into sDAI and holds it. sDAI is an ERC-4626 whose `asset()` IS
 *         DAI, so the universal wrapper covers it with no swap leg at all — the reason
 *         a DAI vault reaches for this before the USDC vault's sUSDS equivalent, which
 *         needs one.
 *
 *   invest   : sDAI.deposit(DAI, VAULT)
 *   value    : sDAI.convertToAssets(shares) — the savings rate folded into the price.
 *   harvest  : NO-OP — yield is the share price rising, not a claimable token.
 *
 *   yield : the Sky Savings Rate, backed by RWA T-bills plus protocol fees and set by
 *           Sky governance. No borrower, no liquidation, no emission token — usually
 *           the best risk-adjusted home for DAI that exists.
 */
contract SkySDaiStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _dai, address _oracle, address _swapper, address _sDai)
        ERC4626WrapperStrategy(_vault, _dai, _oracle, _swapper, _sDai)
    {}
}
