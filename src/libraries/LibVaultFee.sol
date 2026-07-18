// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage, LibAppStorage, BPS_DENOMINATOR, PPS_SCALE} from "./LibAppStorage.sol";
import {LibVaultMath} from "./LibVaultMath.sol";
import {VaultShareToken} from "../VaultShareToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title  LibVaultFee
 * @notice The vault-wide, aggregate high-water-mark performance fee. Realized by
 *         MINTING new shares to the treasury — never by deducting base token —
 *         so charging a fee never requires selling anything and never touches a
 *         user's own balance directly; it only dilutes everyone's share of the
 *         vault proportionally, funded purely by the profit that was made.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY AGGREGATE, NOT PER-STRATEGY
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  A per-strategy fee-at-harvest would charge on strategy A's gain even while
 *  strategy B is losing money in the same vault, over-collecting relative to the
 *  vault's TRUE net performance. Comparing the whole vault's price-per-share
 *  against a single high-water mark charges only on genuine, net-of-everything
 *  growth.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY THIS RUNS INSIDE refreshNav, NOT ONLY AT HARVEST
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Price-per-share can rise from pure interest accrual (a lending strategy's
 *  position value climbs continuously — see BaseStrategy's `_positionValue`) with
 *  no harvest event at all. Tying the fee check to "every time NAV is refreshed"
 *  rather than "only when harvest() is explicitly called" means the fee is
 *  assessed consistently no matter WHAT triggered the NAV to grow — a deposit, a
 *  withdrawal, an explicit harvest, or a permissionless `settle()`.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   TRUE HIGH-WATER MARK
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  The mark is raised to the newly reached peak BEFORE minting the dilutive fee
 *  shares (so it reflects the GROSS peak, not the post-fee price), and it is
 *  raised even when `performanceFeeBps == 0` — a fee-free vault still tracks its
 *  peak so that if a fee is switched on later, it only charges on growth from
 *  that point forward, never retroactively. A price-per-share that dips below the
 *  mark and recovers to the SAME level is never charged again — only a NEW peak
 *  above the stored mark is profit for fee purposes.
 */
library LibVaultFee {
    event PerformanceFeeMinted(address indexed vault, uint256 profitAssets, uint256 feeAssets, uint256 feeShares, uint256 pricePerShare);
    event HighWaterMarkRaised(address indexed vault, uint256 oldMark, uint256 newMark);

    function chargePerformanceFee(address vault) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();

        uint256 supply = IERC20(vault).totalSupply();
        if (supply == 0) return; // nothing to dilute, nothing to charge

        uint256 pps = LibVaultMath.pricePerShare(vault);
        uint256 hwm = s.highWaterMarkPps[vault];
        if (pps <= hwm) return; // no new peak, nothing owed

        s.highWaterMarkPps[vault] = pps;
        emit HighWaterMarkRaised(vault, hwm, pps);

        uint16 feeBps = s.performanceFeeBps[vault];
        if (feeBps == 0) return;
        // Fail-safe, not fail-shut: an unset treasury must never brick every
        // deposit/withdraw/harvest in the vault (every one of them refreshes NAV,
        // which runs this). Skip crystallizing the fee this round instead —
        // the high-water mark above is already raised, so no profit is lost,
        // only its fee collection is deferred until governance sets a treasury.
        if (s.treasury == address(0)) return;

        uint256 profitPerShare = pps - hwm; // PPS_SCALE-fixed point
        uint256 profitAssets = Math.mulDiv(profitPerShare, supply, PPS_SCALE);
        uint256 feeAssets = Math.mulDiv(profitAssets, feeBps, BPS_DENOMINATOR);
        if (feeAssets == 0) return;

        // Priced against CURRENT (pre-mint) totalSupply/navCheckpoint — the mint
        // below is what applies the dilution, not this conversion.
        uint256 feeShares = LibVaultMath.convertToSharesDown(vault, feeAssets);
        if (feeShares == 0) return;

        VaultShareToken(vault).mint(s.treasury, feeShares);
        emit PerformanceFeeMinted(vault, profitAssets, feeAssets, feeShares, pps);
    }
}
