// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStorage, VaultModifiers} from "../libraries/VaultStorage.sol";
import {LibVaultMath} from "../libraries/LibVaultMath.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";
import {LibStrategyRegistry} from "../libraries/LibStrategyRegistry.sol";
import {VaultShareToken} from "../VaultShareToken.sol";
import {IStrategy} from "../strategies/interfaces/IStrategy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

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
        VaultStorage.vaultLayout().paused = true;
        emit VaultPaused(msg.sender);
    }

    function unpauseVault() external onlyGovernance {
        VaultStorage.vaultLayout().paused = false;
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

    /// @notice The guaranteed exit, available ONLY once an emergency has been
    ///         declared (guardian pause, or the automatic pause a circuit break
    ///         triggers). Outside a pause the normal `withdraw`/`redeem` path is open,
    ///         so the two are complementary and exactly one is live at any time.
    ///
    /// @dev    `whenPaused` is load-bearing. Left permissionless and always-on, this
    ///         function let ANY address with a single wei of shares force a full,
    ///         slippage-unbounded unwind of a whole strategy whenever idle was short —
    ///         repeatable every block, for the cost of gas — and let any whale skip
    ///         `withdrawCapPerBlock` entirely by routing around `WithdrawFacet`.
    function emergencyWithdraw(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        whenPaused
        returns (uint256 assetsReceived)
    {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(receiver != address(0) && owner != address(0), "ZERO_ADDRESS");
        require(shares != 0, "ZERO_SHARES");
        // Checked up front so an under-funded call cannot make the vault unwind
        // strategies before reverting.
        require(IERC20(s.shareToken).balanceOf(owner) >= shares, "INSUFFICIENT_SHARES");

        // Fresh pricing (refreshNav try/catches each strategy internally).
        LibVaultNav.refreshNav();
        uint256 entitlement = LibVaultMath.convertToAssetsDown(shares);
        require(entitlement != 0, "ZERO_ENTITLEMENT");

        _gather(s, entitlement);

        // Re-price AFTER the unwind. The gather realizes the venue's exit cost, and
        // whoever triggered that exit should bear it — pricing against the pre-unwind
        // mark and paying it out in full would hand this caller a clean exit and leave
        // the entire cost with the holders who stayed, which is precisely the
        // first-mover advantage that turns a contained loss into a bank run.
        LibVaultNav.refreshNav();
        uint256 repriced = LibVaultMath.convertToAssetsDown(shares);
        if (repriced < entitlement) entitlement = repriced;
        require(entitlement != 0, "ZERO_ENTITLEMENT");

        assetsReceived = s.idleBalance < entitlement ? s.idleBalance : entitlement;
        require(assetsReceived != 0, "NOTHING_RECOVERED");

        // Burn ONLY the shares actually paid for. On a shortfall the remainder of the
        // position survives and can be exited later, instead of the caller forfeiting
        // the difference to everyone else. Rounds UP, so the vault never under-burns.
        uint256 sharesToBurn = assetsReceived >= entitlement
            ? shares
            : Math.mulDiv(shares, assetsReceived, entitlement, Math.Rounding.Ceil);

        if (msg.sender != owner) {
            VaultShareToken(s.shareToken).spendAllowance(owner, msg.sender, sharesToBurn);
        }
        VaultShareToken(s.shareToken).burn(owner, sharesToBurn);

        s.idleBalance -= assetsReceived;
        IERC20(s.baseAsset).safeTransfer(receiver, assetsReceived);

        // Recompute the checkpoint from real holdings (avoids any decrement desync).
        LibVaultNav.refreshNav();

        emit EmergencyWithdrawn(msg.sender, receiver, owner, sharesToBurn, assetsReceived);
    }

    /// @dev Raise idle to `target`, cheapest source first:
    ///        1. idle already held
    ///        2. a BOUNDED divest of the exact shortfall, in priority order
    ///        3. only then a best-effort full unwind
    ///      Step 2 is why a small exit can no longer cost the vault a whole strategy:
    ///      the full-unwind escalation is reached only when the bounded path genuinely
    ///      cannot produce the amount.
    function _gather(VaultStorage.Layout storage s, uint256 target) private {
        if (s.idleBalance >= target) return;

        address[] storage strats = s.strategies;
        uint256 n = strats.length;

        for (uint256 i; i < n && s.idleBalance < target; i++) {
            LibStrategyRegistry.tryDivestFrom(strats[i], target - s.idleBalance);
        }
        for (uint256 i; i < n && s.idleBalance < target; i++) {
            _tryFullExit(s, strats[i]);
        }
    }

    /// @dev Best-effort full unwind of one strategy into idle. Never reverts the
    ///      caller's exit — a strategy that can't be unwound simply contributes 0.
    ///      Credits the vault's own BALANCE DELTA rather than the strategy's return
    ///      value, so `idleBalance` can only ever move by base that really arrived.
    function _tryFullExit(VaultStorage.Layout storage s, address strat) private {
        address receipt;
        try IStrategy(strat).receiptToken() returns (address r) {
            receipt = r;
        } catch {
            return;
        }

        if (receipt != address(0)) IERC20(receipt).forceApprove(strat, type(uint256).max);
        uint256 beforeBal = IERC20(s.baseAsset).balanceOf(address(this));
        try IStrategy(strat).emergencyWithdraw() {
            uint256 freed = IERC20(s.baseAsset).balanceOf(address(this)) - beforeBal;
            s.strategyLastValue[strat] = 0;
            s.strategyLastRefresh[strat] = block.timestamp;
            if (freed != 0) s.idleBalance += freed;
        } catch {}
        if (receipt != address(0)) IERC20(receipt).forceApprove(strat, 0);
    }
}
