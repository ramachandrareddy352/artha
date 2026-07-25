// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStorage, VaultModifiers} from "../libraries/VaultStorage.sol";
import {LibVaultMath} from "../libraries/LibVaultMath.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";
import {VaultShareToken} from "../VaultShareToken.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  EmergencyFacet
 * @notice Pause/unpause, the permissionless `sync`, and the guaranteed exit.
 *
 *  PAUSE IS ASYMMETRIC: a guardian pauses instantly; only governance can unpause.
 *
 *  emergencyWithdraw NEVER reverts on shortfall — shares are burned and the caller
 *  receives whatever base can be gathered (idle first, then each strategy's full
 *  unwind, best-effort). Unlike the old design it refreshes NAV first, so the
 *  caller is priced against fresh (not stale) value, and it recomputes the
 *  checkpoint from real holdings afterward instead of a flat decrement.
 */
contract EmergencyFacet is VaultModifiers {
    using SafeERC20 for IERC20;

    event VaultPaused(address indexed by);
    event VaultUnpaused(address indexed by);
    event EmergencyWithdrawn(address indexed caller, address indexed receiver, address owner, uint256 shares, uint256 assetsReceived);

    // ═══════════════════════════════ pause ════════════════════════════════════════

    function pauseVault() external onlyGuardian {
        VaultStorage.layout().paused = true;
        emit VaultPaused(msg.sender);
    }

    function unpauseVault() external onlyGovernance {
        VaultStorage.layout().paused = false;
        emit VaultUnpaused(msg.sender);
    }

    // ═══════════════════════════════ sync ═════════════════════════════════════════

    /// @notice Fold any directly-transferred base ("extra") into idle, then refresh.
    ///         Permissionless — it can only ever add already-received value.
    function sync() external nonReentrant returns (uint256 totalAssets) {
        LibVaultNav.sync();
        totalAssets = LibVaultNav.refreshNav();
    }

    // ═══════════════════════════════ guaranteed exit ══════════════════════════════

    function emergencyWithdraw(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 assetsReceived)
    {
        VaultStorage.Layout storage s = VaultStorage.layout();
        require(receiver != address(0) && owner != address(0), "ZERO_ADDRESS");
        require(shares != 0, "ZERO_SHARES");

        // Fresh, fair pricing (refreshNav try/catches each strategy internally).
        LibVaultNav.refreshNav();
        uint256 entitlement = LibVaultMath.convertToAssetsDown(shares);

        if (msg.sender != owner) {
            VaultShareToken(s.shareToken).spendAllowance(owner, msg.sender, shares);
        }
        VaultShareToken(s.shareToken).burn(owner, shares);

        // Gather up to `entitlement`: idle first, then unwind strategies best-effort.
        if (s.idleBalance < entitlement) {
            address[] storage strats = s.strategies;
            uint256 n = strats.length;
            for (uint256 i; i < n && s.idleBalance < entitlement; i++) {
                _tryFullExit(s, strats[i]);
            }
        }

        assetsReceived = s.idleBalance < entitlement ? s.idleBalance : entitlement;
        s.idleBalance -= assetsReceived;

        if (assetsReceived != 0) {
            IERC20(s.baseAsset).safeTransfer(receiver, assetsReceived);
        }

        // Recompute the checkpoint from real holdings (avoids any decrement desync).
        LibVaultNav.refreshNav();

        emit EmergencyWithdrawn(msg.sender, receiver, owner, shares, assetsReceived);
    }

    /// @dev Best-effort full unwind of one strategy into idle. Never reverts the
    ///      caller's exit — a strategy that can't be unwound simply contributes 0.
    function _tryFullExit(VaultStorage.Layout storage s, address strat) private {
        address receipt = IStrategy(strat).receiptToken();
        if (receipt != address(0)) IERC20(receipt).forceApprove(strat, type(uint256).max);
        try IStrategy(strat).emergencyWithdraw() returns (uint256 freed) {
            s.strategyLastValue[strat] = 0;
            if (freed != 0) s.idleBalance += freed;
        } catch {}
        if (receipt != address(0)) IERC20(receipt).forceApprove(strat, 0);
    }
}
