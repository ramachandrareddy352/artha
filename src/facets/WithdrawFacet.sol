// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStorage, VaultModifiers} from "../libraries/VaultStorage.sol";
import {LibVaultMath} from "../libraries/LibVaultMath.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";
import {LibVaultCap} from "../libraries/LibVaultCap.sol";
import {LibStrategyRegistry} from "../libraries/LibStrategyRegistry.sol";
import {VaultShareToken} from "../VaultShareToken.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  WithdrawFacet
 * @notice The normal (non-emergency) exit path. Drains idle first, then strategies
 *         in priority order (index 0 first), harvesting before pricing so a
 *         withdrawer's shares reflect true pro-rata value. Reverts the whole
 *         transaction on any shortfall — never a partial burn or partial payout.
 *
 *         The protocol/user profit split happens implicitly here: `refreshNav`
 *         crystallizes the high-water-mark performance fee to the treasury (the
 *         protocol's cut) before the withdrawer is priced, so the withdrawer
 *         receives their share of the post-fee NAV (the user's cut).
 */
contract WithdrawFacet is VaultModifiers {
    using SafeERC20 for IERC20;

    event Withdrawn(
        address indexed caller,
        address indexed receiver,
        address owner,
        uint256 assets,
        uint256 shares,
        uint256 pricePerShare
    );

    function withdraw(uint256 assets, address receiver, address owner, uint256 maxSharesBurned)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(receiver != address(0) && owner != address(0), "ZERO_ADDRESS");
        require(assets != 0, "ZERO_ASSETS");

        if (assets > s.idleBalance) {
            _harvestAllActive(s);
        }
        LibVaultNav.refreshNav();

        shares = LibVaultMath.convertToSharesUp(assets);
        require(shares <= maxSharesBurned, "SLIPPAGE");

        _drain(s, assets);
        _burnAndPay(s, owner, receiver, shares, assets);

        emit Withdrawn(msg.sender, receiver, owner, assets, shares, LibVaultMath.pricePerShare());
    }

    function redeem(uint256 shares, address receiver, address owner, uint256 minAssetsOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(receiver != address(0) && owner != address(0), "ZERO_ADDRESS");
        require(shares != 0, "ZERO_SHARES");

        LibVaultNav.refreshNav();
        assets = LibVaultMath.convertToAssetsDown(shares);

        if (assets > s.idleBalance) {
            _harvestAllActive(s);
            LibVaultNav.refreshNav();
            assets = LibVaultMath.convertToAssetsDown(shares);
        }

        require(assets >= minAssetsOut, "SLIPPAGE");
        require(assets != 0, "ZERO_ASSETS");

        _drain(s, assets);
        _burnAndPay(s, owner, receiver, shares, assets);

        emit Withdrawn(msg.sender, receiver, owner, assets, shares, LibVaultMath.pricePerShare());
    }

    // ─────────────────────────────── internal ───────────────────────────────────

    function _harvestAllActive(VaultStorage.Layout storage s) private {
        address[] storage strats = s.strategies;
        uint256 n = strats.length;
        for (uint256 i; i < n; i++) {
            address strat = strats[i];
            if (s.strategyBroken[strat]) continue;
            try IStrategy(strat).harvest() returns (uint256 realized) {
                if (realized != 0) {
                    // harvested base landed in the vault as idle; account for it.
                    s.idleBalance += realized;
                }
            } catch {}
        }
    }

    /// @dev Idle first, then the priority queue for the shortfall. `divestFrom`
    ///      credits the freed base into idle and keeps the breaker cache honest, so
    ///      after the loop idle holds enough to pay the whole `assets`. Reverts the
    ///      whole transaction if the full amount cannot be produced.
    function _drain(VaultStorage.Layout storage s, uint256 assets) private {
        if (s.idleBalance < assets) {
            uint256 remaining = assets - s.idleBalance;

            address[] storage strats = s.strategies;
            uint256 n = strats.length;
            for (uint256 i; i < n && remaining != 0; i++) {
                address strat = strats[i];
                if (s.strategyBroken[strat]) continue;
                uint256 freed = LibStrategyRegistry.divestFrom(strat, remaining);
                remaining -= freed < remaining ? freed : remaining;
            }
            require(remaining == 0, "INSUFFICIENT_LIQUIDITY");
        }

        // idle now covers the full amount (idle_before + Σ freed >= assets).
        s.idleBalance -= assets;
        s.navCheckpoint -= assets;
    }

    function _burnAndPay(VaultStorage.Layout storage s, address owner, address receiver, uint256 shares, uint256 assets)
        private
    {
        LibVaultCap.checkAndConsumeWithdraw(msg.sender, assets);

        if (msg.sender != owner) {
            VaultShareToken(s.shareToken).spendAllowance(owner, msg.sender, shares);
        }
        VaultShareToken(s.shareToken).burn(owner, shares);
 
        IERC20(s.baseAsset).safeTransfer(receiver, assets);
    }
}
