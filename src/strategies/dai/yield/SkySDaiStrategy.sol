// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  SkySDaiStrategy  —  DAI's signature Shape-2 strategy (the Sky Savings Rate)
 * @notice Deposits DAI into sDAI (Sky's ERC-4626 savings vault) and holds it. sDAI is
 *         an ERC-4626 whose asset() IS DAI, so the universal wrapper covers it exactly
 *         — this file just names and documents the deployment.
 *
 *   invest   : sDAI.deposit(DAI, this)
 *   value    : sDAI.convertToAssets(shares) -> DAI, the savings rate folded into the
 *              share price (no reward token).
 *   withdraw : sDAI.withdraw(DAI, this, this)
 *   harvest  : NO-OP — yield is the share price rising, not a claimable token.
 *
 *   yield : the Sky Savings Rate, backed by RWA T-bills + protocol fees, governance-set.
 *           No borrower, no liquidation, no emission token — usually the best
 *           risk-adjusted home for DAI, which is why it is the DAI vault's "do first".
 */
contract SkySDaiStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _dai, address _oracle, address _swapper, address _sDai)
        ERC4626WrapperStrategy(_vault, _dai, _oracle, _swapper, _sDai)
    {}
}
