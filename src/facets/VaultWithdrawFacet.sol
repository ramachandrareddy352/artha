// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage, Modifiers} from "../libraries/LibAppStorage.sol";
import {LibVaultMath} from "../libraries/LibVaultMath.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";
import {LibVaultCap} from "../libraries/LibVaultCap.sol";
import {VaultShareToken} from "../VaultShareToken.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  VaultWithdrawFacet
 * @notice The normal (non-emergency) exit path. Gated `whenVaultNotPaused` —
 *         during a pause, users still have a guaranteed exit, but only through
 *         VaultEmergencyFacet's `emergencyWithdraw`, which skips harvesting and
 *         reward-selling entirely for the fastest, lowest-surface-area route out.
 *         This facet is the one used every other time.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   DRAIN ORDER: idle first, then strategies in PRIORITY-QUEUE order
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  A withdrawal first spends the vault's idle buffer, and only reaches into
 *  strategies for the shortfall, walking `s.strategies[vault]` in the order
 *  strategies were added — index 0 drains first. A broken (circuit-tripped)
 *  strategy is skipped entirely; its capital simply isn't available to this path
 *  until governance clears it.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HARVEST BEFORE PRICING, ATOMIC REVERT ON ANY SHORTFALL
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  If a withdrawal needs to reach into strategies at all, EVERY active strategy is
 *  harvested (best-effort — a harvest failure is swallowed, not fatal, so an
 *  unrelated strategy's temporary swap-slippage issue can never trap a user's
 *  exit) before the withdrawal's own share price is computed. This folds freshly
 *  realized reward value into NAV before anyone's shares are priced against it —
 *  neutral-to-positive for every holder, not just the withdrawer, and it is why a
 *  withdrawing user's shares reflect their TRUE pro-rata rewards rather than the
 *  conservative haircut estimate `totalAssets()` otherwise carries.
 *
 *  If, after draining idle and walking the entire strategy queue, the vault still
 *  cannot produce the requested amount, the ENTIRE transaction reverts — nothing
 *  partially unwinds, no partial burn, no partial payout. A withdrawal either
 *  fully succeeds at the price the caller bounded, or has no effect at all.
 */
contract VaultWithdrawFacet is Modifiers {
    using SafeERC20 for IERC20;

    event Withdrawn(
        address indexed vault,
        address indexed caller,
        address indexed receiver,
        address owner,
        uint256 assets,
        uint256 shares,
        uint256 pricePerShare
    );

    /// @notice Withdraw an exact amount of base token, burning at most
    ///         `maxSharesBurned` shares of `owner`'s. If `msg.sender != owner`,
    ///         the caller must hold sufficient ERC-20 allowance over `owner`'s
    ///         shares (standard ERC-4626 delegated-withdrawal pattern).
    function withdraw(
        address vault,
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxSharesBurned,
        uint256 deadline
    ) external nonReentrant onlyRegisteredVault(vault) whenVaultNotPaused(vault) returns (uint256 shares) {
        require(block.timestamp <= deadline, "EXPIRED");
        require(receiver != address(0) && owner != address(0), "ZERO_ADDRESS");
        require(assets != 0, "ZERO_ASSETS");

        _harvestIfTouched(vault, assets);
        LibVaultNav.refreshNav(vault);

        shares = LibVaultMath.convertToSharesUp(vault, assets);
        require(shares <= maxSharesBurned, "SLIPPAGE");

        _drain(vault, assets);
        _burnAndPay(vault, owner, receiver, shares, assets);

        emit Withdrawn(vault, msg.sender, receiver, owner, assets, shares, LibVaultMath.pricePerShare(vault));
    }

    /// @notice Redeem an exact amount of shares, receiving at least
    ///         `minAssetsOut` base token.
    function redeem(
        address vault,
        uint256 shares,
        address receiver,
        address owner,
        uint256 minAssetsOut,
        uint256 deadline
    ) external nonReentrant onlyRegisteredVault(vault) whenVaultNotPaused(vault) returns (uint256 assets) {
        require(block.timestamp <= deadline, "EXPIRED");
        require(receiver != address(0) && owner != address(0), "ZERO_ADDRESS");
        require(shares != 0, "ZERO_SHARES");

        LibVaultNav.refreshNav(vault);
        assets = LibVaultMath.convertToAssetsDown(vault, shares);

        // If this will reach into strategies, harvest first and REPRICE against
        // the fresh post-harvest NAV — see the contract header for why.
        if (assets > s.idleBalance[vault]) {
            _harvestAllActive(vault);
            LibVaultNav.refreshNav(vault);
            assets = LibVaultMath.convertToAssetsDown(vault, shares);
        }

        require(assets >= minAssetsOut, "SLIPPAGE");
        require(assets != 0, "ZERO_ASSETS");

        _drain(vault, assets);
        _burnAndPay(vault, owner, receiver, shares, assets);

        emit Withdrawn(vault, msg.sender, receiver, owner, assets, shares, LibVaultMath.pricePerShare(vault));
    }

    // ─────────────────────────────── internal ───────────────────────────────────

    function _harvestIfTouched(address vault, uint256 assets) private {
        if (assets > s.idleBalance[vault]) {
            _harvestAllActive(vault);
        }
    }

    function _harvestAllActive(address vault) private {
        address[] storage strats = s.strategies[vault];
        uint256 n = strats.length;
        for (uint256 i; i < n; i++) {
            address strat = strats[i];
            if (s.strategyBroken[vault][strat]) continue;
            try IStrategy(strat).harvest() {} catch {}
        }
    }

    /// @dev Idle first, then the priority queue for the shortfall. Reverts the
    ///      whole transaction if the full amount cannot be produced.
    ///
    ///      Also decrements `strategyLastValue` by exactly what was pulled from
    ///      each touched strategy. Without this, the NEXT `refreshNav` call would
    ///      compare that strategy's (now genuinely lower) `totalAssets()` against
    ///      a STALE, pre-withdrawal cached value — and a large but perfectly
    ///      legitimate withdrawal would look identical to a suspicious value drop,
    ///      falsely tripping the circuit breaker on a healthy strategy.
    function _drain(address vault, uint256 assets) private {
        uint256 idle = s.idleBalance[vault];

        if (idle >= assets) {
            s.idleBalance[vault] = idle - assets;
        } else {
            uint256 remaining = assets - idle;
            s.idleBalance[vault] = 0;

            address[] storage strats = s.strategies[vault];
            uint256 n = strats.length;
            for (uint256 i; i < n && remaining != 0; i++) {
                address strat = strats[i];
                if (s.strategyBroken[vault][strat]) continue;
                uint256 got = IStrategy(strat).withdraw(remaining);
                if (got != 0) {
                    uint256 lastValue = s.strategyLastValue[vault][strat];
                    s.strategyLastValue[vault][strat] = got >= lastValue ? 0 : lastValue - got;
                }
                remaining -= got;
            }
            require(remaining == 0, "INSUFFICIENT_LIQUIDITY");
        }

        s.navCheckpoint[vault] -= assets;
    }

    function _burnAndPay(address vault, address owner, address receiver, uint256 shares, uint256 assets) private {
        LibVaultCap.checkAndConsumeWithdraw(vault, msg.sender, assets);

        if (msg.sender != owner) {
            VaultShareToken(vault).spendAllowance(owner, msg.sender, shares);
        }
        VaultShareToken(vault).burn(owner, shares);

        IERC20(s.baseAsset[vault]).safeTransfer(receiver, assets);
    }
}
