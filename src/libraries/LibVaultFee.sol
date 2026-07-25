// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStorage, BPS_DENOMINATOR, PPS_SCALE, DECIMALS_OFFSET} from "./VaultStorage.sol";
import {LibVaultMath} from "./LibVaultMath.sol";
import {VaultShareToken} from "../VaultShareToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @title  LibVaultFee
 * @notice Vault-wide, aggregate high-water-mark performance fee — the "split the
 *         profit between protocol and user." On new profit above the mark, the
 *         PROTOCOL's cut (`performanceFeeBps`) is minted as fresh shares to the
 *         treasury; the remaining profit stays in NAV and lifts every holder's
 *         share value (the USER's cut). No base token is ever deducted, so
 *         charging a fee never sells anything and never touches a user's balance
 *         directly. This runs inside `refreshNav`, which every withdrawal calls,
 *         so the protocol/user split is realized around each withdrawal.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE HIGH-WATER-MARK SCALE FIX
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `pricePerShare = (nav+1)·PPS_SCALE / (supply + 10^DECIMALS_OFFSET)`. Because
 *  the first deposit mints `assets · 10^DECIMALS_OFFSET` shares, the NATURAL
 *  genesis price-per-share is exactly `PPS_SCALE / 10^DECIMALS_OFFSET` (= 1e12),
 *  NOT `PPS_SCALE` (1e18). The mark is therefore seeded at that genesis value by
 *  `initialize` (see `GENESIS_PPS`), so the fee crystallizes on real yield rather
 *  than being permanently dormant (which it would be if seeded at 1e18).
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   TRUE HIGH-WATER MARK
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  The mark is raised to the newly reached peak BEFORE minting the dilutive fee
 *  shares, and is raised even when `performanceFeeBps == 0`. A price that dips
 *  below the mark and recovers to the same level is never charged again — only a
 *  NEW peak above the stored mark is profit for fee purposes.
 */
library LibVaultFee {
    /// @notice The natural price-per-share at genesis and the correct initial HWM.
    uint256 internal constant GENESIS_PPS = PPS_SCALE / (10 ** DECIMALS_OFFSET); // 1e12

    event PerformanceFeeMinted(uint256 profitAssets, uint256 feeAssets, uint256 feeShares, uint256 pricePerShare);
    event HighWaterMarkRaised(uint256 oldMark, uint256 newMark);

    function chargePerformanceFee() internal {
        VaultStorage.Layout storage s = VaultStorage.layout();

        uint256 supply = IERC20(s.shareToken).totalSupply();
        if (supply == 0) return; // nothing to dilute, nothing to charge

        uint256 pps = LibVaultMath.pricePerShare();
        uint256 hwm = s.highWaterMarkPps;
        if (pps <= hwm) return; // no new peak, nothing owed

        s.highWaterMarkPps = pps;
        emit HighWaterMarkRaised(hwm, pps);

        uint16 feeBps = s.performanceFeeBps;
        if (feeBps == 0) return;
        // Fail-safe: an unset treasury must never brick every deposit/withdraw/
        // harvest (all of which refresh NAV). Skip crystallizing this round; the
        // mark is already raised so no profit is lost, only the fee is deferred.
        if (s.treasury == address(0)) return;

        uint256 profitPerShare = pps - hwm; // PPS_SCALE fixed point
        uint256 profitAssets = Math.mulDiv(profitPerShare, supply, PPS_SCALE);
        uint256 feeAssets = Math.mulDiv(profitAssets, feeBps, BPS_DENOMINATOR);
        if (feeAssets == 0) return;

        // Priced against CURRENT (pre-mint) supply/nav — the mint below applies
        // the dilution, not this conversion.
        uint256 feeShares = LibVaultMath.convertToSharesDown(feeAssets);
        if (feeShares == 0) return;

        VaultShareToken(s.shareToken).mint(s.treasury, feeShares);
        emit PerformanceFeeMinted(profitAssets, feeAssets, feeShares, pps);
    }
}
