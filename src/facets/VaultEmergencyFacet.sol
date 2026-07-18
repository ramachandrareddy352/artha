// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage, Modifiers} from "../libraries/LibAppStorage.sol";
import {LibVaultMath} from "../libraries/LibVaultMath.sol";
import {VaultShareToken} from "../VaultShareToken.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  VaultEmergencyFacet
 * @notice Pause/unpause and the guaranteed, always-available exit path.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   PAUSE IS ASYMMETRIC ON PURPOSE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  A guardian can pause a vault (or the whole protocol) INSTANTLY — no delay, no
 *  vote, because an incident in progress cannot wait for governance. But a
 *  guardian can NEVER unpause. Unpausing is `onlyGovernance` — the ArthaTimelock —
 *  meaning it requires a full public proposal and delay window. This split
 *  defeats the specific attack of a compromised guardian key pausing and then
 *  immediately unpausing as a distraction, or a rogue guardian repeatedly
 *  toggling pause to grief the protocol: the worst a compromised guardian key can
 *  do is pause (safe by construction — it only prevents new deposits and routes
 *  withdrawals to the slower emergency path) and it can never undo that alone.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   emergencyWithdraw NEVER REVERTS ON SHORTFALL — BY DESIGN, UNLIKE THE NORMAL PATH
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  VaultWithdrawFacet's normal `withdraw`/`redeem` revert the whole transaction if
 *  the vault cannot produce the full requested amount (see its header) — the
 *  right behavior when a queue can legitimately be retried later. This function
 *  is the opposite: it is the guaranteed exit that must NEVER trap a user, so it
 *  always succeeds. `shares` are burned unconditionally and the caller receives
 *  whatever base token could actually be gathered for them — idle first, then
 *  every strategy's own `emergencyWithdraw()` (skip harvest, no swaps, no
 *  slippage bound), best-effort per strategy. If a strategy is genuinely drained
 *  (e.g. mid-exploit) its contribution is honestly zero rather than blocking
 *  every other holder's ability to exit through the strategies that still work.
 *  Any surplus a strategy gives up beyond this caller's own entitlement is
 *  credited back to the vault's idle balance for everyone else, not lost.
 */
contract VaultEmergencyFacet is Modifiers {
    using SafeERC20 for IERC20;

    event VaultPaused(address indexed vault, address indexed by);
    event VaultUnpaused(address indexed vault, address indexed by);
    event ProtocolPaused(address indexed by);
    event ProtocolUnpaused(address indexed by);
    event EmergencyWithdrawn(
        address indexed vault, address indexed caller, address indexed receiver, address owner, uint256 shares, uint256 assetsReceived
    );

    // ═══════════════════════════════ pause (guardian) ═════════════════════════════

    function pauseVault(address vault) external onlyGuardian onlyRegisteredVault(vault) {
        s.vaultPaused[vault] = true;
        emit VaultPaused(vault, msg.sender);
    }

    function pauseProtocol() external onlyGuardian {
        s.globalPaused = true;
        emit ProtocolPaused(msg.sender);
    }

    // ═══════════════════════════════ unpause (governance only) ════════════════════

    function unpauseVault(address vault) external onlyGovernance onlyRegisteredVault(vault) {
        s.vaultPaused[vault] = false;
        emit VaultUnpaused(vault, msg.sender);
    }

    function unpauseProtocol() external onlyGovernance {
        s.globalPaused = false;
        emit ProtocolUnpaused(msg.sender);
    }

    // ═══════════════════════════════ guaranteed exit ═══════════════════════════════

    function emergencyWithdraw(address vault, uint256 shares, address receiver, address owner)
        external
        nonReentrant
        onlyRegisteredVault(vault)
        returns (uint256 assetsReceived)
    {
        require(receiver != address(0) && owner != address(0), "ZERO_ADDRESS");
        require(shares != 0, "ZERO_SHARES");

        // Priced against the last checkpoint AS-IS — deliberately no refreshNav
        // here, to keep this path's external-call surface minimal exactly when
        // that matters most.
        uint256 entitlement = LibVaultMath.convertToAssetsDown(vault, shares);

        if (msg.sender != owner) {
            VaultShareToken(vault).spendAllowance(owner, msg.sender, shares);
        }
        VaultShareToken(vault).burn(owner, shares);

        uint256 remaining = entitlement;
        uint256 idle = s.idleBalance[vault];
        uint256 fromIdle = idle < remaining ? idle : remaining;
        s.idleBalance[vault] = idle - fromIdle;
        remaining -= fromIdle;
        assetsReceived = fromIdle;

        if (remaining != 0) {
            address[] storage strats = s.strategies[vault];
            uint256 n = strats.length;
            for (uint256 i; i < n && remaining != 0; i++) {
                address strat = strats[i];
                try IStrategy(strat).emergencyWithdraw() returns (uint256 freed) {
                    s.strategyLastValue[vault][strat] = 0; // fully unwound by definition
                    if (freed == 0) continue;

                    uint256 used = freed > remaining ? remaining : freed;
                    assetsReceived += used;
                    remaining -= used;

                    if (freed > used) {
                        // gave up more than THIS caller needed -- bank the rest as
                        // idle rather than losing track of it.
                        s.idleBalance[vault] += (freed - used);
                    }
                } catch {}
            }
        }

        s.navCheckpoint[vault] =
            s.navCheckpoint[vault] > assetsReceived ? s.navCheckpoint[vault] - assetsReceived : 0;

        if (assetsReceived != 0) {
            IERC20(s.baseAsset[vault]).safeTransfer(receiver, assetsReceived);
        }

        emit EmergencyWithdrawn(vault, msg.sender, receiver, owner, shares, assetsReceived);
    }
}
