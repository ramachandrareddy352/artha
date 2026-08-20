// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStorage} from "./VaultStorage.sol";

/**
 * @title  LibVaultCap
 * @notice Per-block flow-rate limiting for a single vault, independent of the
 *         overall TVL cap. A TVL cap bounds how big the vault gets; this bounds
 *         how FAST value can move in or out in one block — the defense against a
 *         single-block attack or a bank-run cascade.
 *
 *  Deposit and withdraw each have their own cap, tracked CUMULATIVELY across
 *  every caller in the same block (a per-tx-only cap is trivially split across
 *  transactions in one block). A transaction that would push the block's
 *  cumulative flow over the cap REVERTS outright. Exempt addresses skip entirely.
 */
library LibVaultCap {
    event DepositCapConsumed(uint256 blockNumber, uint256 amount, uint256 cumulative);
    event WithdrawCapConsumed(uint256 blockNumber, uint256 amount, uint256 cumulative);

    function checkAndConsumeDeposit(address who, uint256 amount) internal {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        if (s.isCapExempt[who]) return;

        uint256 cap = s.depositCapPerBlock;
        if (cap == 0) return; // 0 = uncapped

        if (s.depositFlowBlock != uint64(block.number)) {
            s.depositFlowBlock = uint64(block.number);
            s.depositFlowAmount = 0;
        }

        // `cap <= type(uint192).max` is enforced in the setters, and cumulative <= cap
        // is required below, so the uint192 downcast can never truncate.
        uint256 cumulative = uint256(s.depositFlowAmount) + amount;
        require(cumulative <= cap, "DEPOSIT_CAP_EXCEEDED");

        s.depositFlowAmount = uint192(cumulative);
        emit DepositCapConsumed(block.number, amount, cumulative);
    }

    function checkAndConsumeWithdraw(address who, uint256 amount) internal {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        if (s.isCapExempt[who]) return;

        uint256 cap = s.withdrawCapPerBlock;
        if (cap == 0) return;

        if (s.withdrawFlowBlock != uint64(block.number)) {
            s.withdrawFlowBlock = uint64(block.number);
            s.withdrawFlowAmount = 0;
        }

        uint256 cumulative = uint256(s.withdrawFlowAmount) + amount;
        require(cumulative <= cap, "WITHDRAW_CAP_EXCEEDED");

        s.withdrawFlowAmount = uint192(cumulative);
        emit WithdrawCapConsumed(block.number, amount, cumulative);
    }
}
