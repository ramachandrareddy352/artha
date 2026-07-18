// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage, LibAppStorage} from "./LibAppStorage.sol";

/**
 * @title  LibVaultCap
 * @notice Per-block flow-rate limiting, independent of the vault's overall TVL cap.
 *         A TVL cap bounds how big a vault gets; this bounds how FAST money can move
 *         in or out in a single block — the defense against a single-block attack
 *         (e.g. an oracle manipulated and drained inside one transaction bundle, or
 *         a bank-run cascade) rather than a slow, visible, interruptible drain.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   SEPARATE CAPS, CUMULATIVE PER BLOCK, FIXED BASE-TOKEN VALUES
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Deposit and withdraw each have their OWN cap (a deposit flood and a withdrawal
 *  drain are different risks — share-price dilution/inflation vs idle-buffer /
 *  liquidity risk — and are tuned independently). Each cap is tracked CUMULATIVELY
 *  across every caller in the same block, not per-transaction: a per-tx-only cap is
 *  trivially bypassed by splitting one large flow across several transactions
 *  mined in the same block, so this sums everyone's flow against `block.number`.
 *  Values are fixed, governance-set, base-token units per vault (a 5 WBTC/block cap
 *  looks nothing like a 1,000,000 USDC/block cap, and that's the point — it is
 *  sized to what the base asset actually is, not a generic percentage).
 *
 *  A transaction that would push the block's cumulative flow over the cap REVERTS
 *  outright — consistent with the vault's withdrawal semantics elsewhere
 *  (revert-the-whole-action rather than partial-fill).
 *
 *  Exempt addresses (`isCapExempt`) skip the check entirely — for a vetted
 *  institutional counterparty or an atomic migration flow that legitimately needs
 *  to move more than the retail-sized per-block budget in one shot.
 */
library LibVaultCap {
    event DepositCapConsumed(address indexed vault, uint256 blockNumber, uint256 amount, uint256 cumulative);
    event WithdrawCapConsumed(address indexed vault, uint256 blockNumber, uint256 amount, uint256 cumulative);

    function checkAndConsumeDeposit(address vault, address who, uint256 amount) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (s.isCapExempt[vault][who]) return;

        uint256 cap = s.depositCapPerBlock[vault];
        if (cap == 0) return; // 0 = uncapped

        if (s.depositFlowBlock[vault] != block.number) {
            s.depositFlowBlock[vault] = block.number;
            s.depositFlowAmount[vault] = 0;
        }

        uint256 cumulative = s.depositFlowAmount[vault] + amount;
        require(cumulative <= cap, "DEPOSIT_CAP_EXCEEDED");

        s.depositFlowAmount[vault] = cumulative;
        emit DepositCapConsumed(vault, block.number, amount, cumulative);
    }

    function checkAndConsumeWithdraw(address vault, address who, uint256 amount) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (s.isCapExempt[vault][who]) return;

        uint256 cap = s.withdrawCapPerBlock[vault];
        if (cap == 0) return;

        if (s.withdrawFlowBlock[vault] != block.number) {
            s.withdrawFlowBlock[vault] = block.number;
            s.withdrawFlowAmount[vault] = 0;
        }

        uint256 cumulative = s.withdrawFlowAmount[vault] + amount;
        require(cumulative <= cap, "WITHDRAW_CAP_EXCEEDED");

        s.withdrawFlowAmount[vault] = cumulative;
        emit WithdrawCapConsumed(vault, block.number, amount, cumulative);
    }
}
