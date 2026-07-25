// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStorage, DECIMALS_OFFSET, PPS_SCALE} from "./VaultStorage.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title  LibVaultMath
 * @notice Share <-> asset conversion for a single vault. Reads this vault's
 *         `navCheckpoint` (the CHECKPOINTED total value) and `totalSupply()` on
 *         its own share token (the sole source of truth for share counts).
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   CALL ORDER: refresh the checkpoint BEFORE calling anything here
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  This library never triggers a NAV refresh itself — that is LibVaultNav's job.
 *  Every STATE-CHANGING entry point must call `LibVaultNav.refreshNav()` first.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE VIRTUAL-OFFSET INFLATION DEFENSE / ROUNDING RULE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *      deposit(assets) -> shares minted   : ROUND DOWN (caller gets fewer shares)
 *      mint(shares)    -> assets required : ROUND UP   (caller pays more assets)
 *      withdraw(assets)-> shares burned   : ROUND UP   (caller burns more shares)
 *      redeem(shares)  -> assets returned : ROUND DOWN (caller receives fewer assets)
 *
 *  Rounding always favors the vault / existing holders, applied consistently.
 */
library LibVaultMath {
    function _supply() private view returns (uint256) {
        return IERC20(VaultStorage.layout().shareToken).totalSupply();
    }

    /// @dev assets -> shares, rounding DOWN. Used by deposit().
    function convertToSharesDown(uint256 assets) internal view returns (uint256) {
        uint256 ta = VaultStorage.layout().navCheckpoint;
        uint256 offset = 10 ** DECIMALS_OFFSET;
        return Math.mulDiv(assets, _supply() + offset, ta + 1, Math.Rounding.Floor);
    }

    /// @dev shares -> assets required, rounding UP. Used by mint().
    function convertToAssetsUp(uint256 shares) internal view returns (uint256) {
        uint256 ta = VaultStorage.layout().navCheckpoint;
        uint256 offset = 10 ** DECIMALS_OFFSET;
        return Math.mulDiv(shares, ta + 1, _supply() + offset, Math.Rounding.Ceil);
    }

    /// @dev assets -> shares burned, rounding UP. Used by withdraw().
    function convertToSharesUp(uint256 assets) internal view returns (uint256) {
        uint256 ta = VaultStorage.layout().navCheckpoint;
        uint256 offset = 10 ** DECIMALS_OFFSET;
        return Math.mulDiv(assets, _supply() + offset, ta + 1, Math.Rounding.Ceil);
    }

    /// @dev shares -> assets returned, rounding DOWN. Used by redeem().
    function convertToAssetsDown(uint256 shares) internal view returns (uint256) {
        uint256 ta = VaultStorage.layout().navCheckpoint;
        uint256 offset = 10 ** DECIMALS_OFFSET;
        return Math.mulDiv(shares, ta + 1, _supply() + offset, Math.Rounding.Floor);
    }

    /// @notice Informational price-per-share, PPS_SCALE (1e18) fixed point. NEVER
    ///         used for deposit/withdraw math — only for display and the
    ///         high-water-mark fee comparison.
    function pricePerShare() internal view returns (uint256) {
        uint256 ta = VaultStorage.layout().navCheckpoint;
        uint256 offset = 10 ** DECIMALS_OFFSET;
        return Math.mulDiv(ta + 1, PPS_SCALE, _supply() + offset, Math.Rounding.Floor);
    }
}
