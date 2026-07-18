// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage, LibAppStorage, DECIMALS_OFFSET, PPS_SCALE} from "./LibAppStorage.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title  LibVaultMath
 * @notice Share <-> asset conversion. Reads `AppStorage.navCheckpoint[vault]` — the
 *         CHECKPOINTED total value, not a live recomputation — and `totalSupply()`
 *         on the vault's own share token (the sole source of truth for share
 *         counts; see LibAppStorage's header for why shares live in a real ERC-20
 *         rather than in this struct).
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   CALL ORDER: refresh the checkpoint BEFORE calling anything here
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  This library never triggers a NAV refresh itself — that is LibVaultNav's job
 *  (`LibVaultNav.refreshNav(vault)`), and it is deliberately a SEPARATE step so a
 *  view function can price shares against the last checkpoint without paying for a
 *  fresh strategy sweep (see the design discussion: checkpointed NAV, not live,
 *  precisely to keep balance checks and previews cheap). Every STATE-CHANGING facet
 *  entry point (deposit/mint/withdraw/redeem/harvest/settle) MUST call
 *  `LibVaultNav.refreshNav` first, in that order, every time — pricing a mutating
 *  action against a stale checkpoint is a mispricing bug, not a gas optimization.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE VIRTUAL-OFFSET INFLATION DEFENSE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Adding virtual shares (10^DECIMALS_OFFSET) and a virtual asset (1) on both sides
 *  of every conversion makes the classic first-depositor attack (mint 1 wei of
 *  shares, donate a large balance directly to the vault, round the next real
 *  depositor's mint to zero) economically irrational: an attacker would need to
 *  donate roughly 10^DECIMALS_OFFSET times their own deposit to move the price
 *  enough to hurt a victim, which is a pure loss to the attacker with no offsetting
 *  gain (donated funds are NOT recoverable — they are just extra vault assets that
 *  round to the attacker's own tiny share count).
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ROUNDING ALWAYS FAVORS THE VAULT / EXISTING HOLDERS, NEVER THE CALLER
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *      deposit(assets) -> shares minted   : ROUND DOWN (caller gets fewer shares)
 *      mint(shares)    -> assets required : ROUND UP   (caller pays more assets)
 *      withdraw(assets)-> shares burned   : ROUND UP   (caller burns more shares)
 *      redeem(shares)  -> assets returned : ROUND DOWN (caller receives fewer assets)
 *
 *  This is the standard ERC-4626 convention, applied consistently rather than
 *  decided per-function — a system where rounding direction is chosen ad hoc is a
 *  system where someone eventually picks the wrong one under deadline pressure.
 */
library LibVaultMath {
    /// @dev assets -> shares, rounding DOWN. Used by deposit().
    function convertToSharesDown(address vault, uint256 assets) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 supply = IERC20(vault).totalSupply();
        uint256 ta = s.navCheckpoint[vault];
        uint256 offset = 10 ** DECIMALS_OFFSET;
        return Math.mulDiv(assets, supply + offset, ta + 1, Math.Rounding.Floor);
    }

    /// @dev shares -> assets required, rounding UP. Used by mint().
    function convertToAssetsUp(address vault, uint256 shares) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 supply = IERC20(vault).totalSupply();
        uint256 ta = s.navCheckpoint[vault];
        uint256 offset = 10 ** DECIMALS_OFFSET;
        return Math.mulDiv(shares, ta + 1, supply + offset, Math.Rounding.Ceil);
    }

    /// @dev assets -> shares burned, rounding UP. Used by withdraw().
    function convertToSharesUp(address vault, uint256 assets) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 supply = IERC20(vault).totalSupply();
        uint256 ta = s.navCheckpoint[vault];
        uint256 offset = 10 ** DECIMALS_OFFSET;
        return Math.mulDiv(assets, supply + offset, ta + 1, Math.Rounding.Ceil);
    }

    /// @dev shares -> assets returned, rounding DOWN. Used by redeem().
    function convertToAssetsDown(address vault, uint256 shares) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 supply = IERC20(vault).totalSupply();
        uint256 ta = s.navCheckpoint[vault];
        uint256 offset = 10 ** DECIMALS_OFFSET;
        return Math.mulDiv(shares, ta + 1, supply + offset, Math.Rounding.Floor);
    }

    /// @notice Informational price-per-share, PPS_SCALE (1e18) fixed point. NEVER
    ///         used internally for deposit/withdraw math (those always go through
    ///         the offset-aware conversions above) — this is for display and for
    ///         the high-water-mark fee comparison only.
    function pricePerShare(address vault) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 supply = IERC20(vault).totalSupply();
        uint256 ta = s.navCheckpoint[vault];
        uint256 offset = 10 ** DECIMALS_OFFSET;
        return Math.mulDiv(ta + 1, PPS_SCALE, supply + offset, Math.Rounding.Floor);
    }
}
