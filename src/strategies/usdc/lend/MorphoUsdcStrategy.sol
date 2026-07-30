// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseStrategy} from "../../BaseStrategy.sol";
import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  MorphoUsdcStrategy  —  Shape 1 via a curated MetaMorpho vault
 * @notice Supplies USDC into a MetaMorpho vault (Morpho Blue's curated allocator
 *         layer). A MetaMorpho vault IS an ERC-4626, so mechanically this is the
 *         universal wrapper — it is given its own named file only so the Morpho-
 *         specific notes below live next to the deployment.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW WE INVEST
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   invest   : metaMorpho.deposit(USDC, this). The vault's curator spreads it across
 *              isolated Morpho Blue markets (each with its own collateral + LLTV).
 *   value    : metaMorpho.convertToAssets(shares) — USDC, interest folded into the
 *              share price (Shape 2 mechanics over Shape 1 interest underneath).
 *   withdraw : metaMorpho.withdraw(USDC, this, this). Bounded by the vault's available
 *              (un-utilized) liquidity — see maxWithdraw, inherited from the wrapper.
 *   harvest  : no-op. Base interest is in the share price. If a market pays MORPHO
 *              incentives, those are distributed off-chain via a merkle URD and are
 *              NOT auto-claimable on-chain here — treat them as out of scope, claim
 *              and fold them in separately if ever material.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   RISK NOTE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Risk lives in the CURATOR's market choices (which collaterals, what LLTV), not in
 *  Morpho Blue itself. Morpho does not socialize bad debt across markets — a bad
 *  market is isolated — so only supply into vaults whose curator you have vetted.
 *  Pick the target MetaMorpho vault as a governance decision.
 */
contract MorphoUsdcStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _asset, address _oracle, address _swapper, address _metaMorpho)
        ERC4626WrapperStrategy(_vault, _asset, _oracle, _swapper, _metaMorpho)
    {}
}
