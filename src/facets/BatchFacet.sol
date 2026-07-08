// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Modifiers} from "../libraries/LibAppStorage.sol";
import {LibShares} from "../libraries/LibShares.sol";

/**
 * @title  BatchFacet
 * @notice End-of-day settlement. The bounded EXECUTOR triggers this once per day
 *         per pool. It converts the day's aggregated pending USDC into shares at
 *         the current NAV and moves that USDC into the pool's idle balance (which
 *         AllocationFacet then deploys into the basket in batch 3).
 *
 *  Executor-controlled timing is deliberate: it prevents batch front-running and
 *  the ERC-4626 inflation attack (an attacker can't sandwich an unpredictable
 *  settle). All effects stay bounded — the executor cannot mint to itself or move
 *  funds outside this accounting.
 *
 *  THE MIN-PENDING GATE: a day only settles if its pending >= minPendingToSettle,
 *  so tiny batches don't waste gas / cause dust.
 *
 *  FAIRNESS: every user in the batch gets pending_user * sharesPerAsset, i.e.
 *  exactly the shares they'd get depositing individually at this NAV — one
 *  settlement for the whole day.
 */
contract BatchFacet is Modifiers {
    event DaySettled(uint8 indexed poolId, uint256 indexed day, uint256 pendingUsdc, uint256 sharesMinted);

    /**
     * @notice Settle one pool's pending deposits for a given day.
     * @param poolId 0..5
     * @param day    the day index to settle (must not be settled already)
     */
    function settleDay(uint8 poolId, uint256 day) external onlyExecutor validPool(poolId) {
        require(!s.daySettled[poolId][day], "ALREADY_SETTLED");

        uint256 pending = s.pendingDeposit[poolId][day];
        require(pending >= s.minPendingToSettle[poolId], "BELOW_MIN_PENDING");

        // shares for the whole batch, priced at the NAV BEFORE adding this USDC
        uint256 sharesMinted = LibShares.convertToShares(poolId, pending);
        require(sharesMinted != 0, "ZERO_SHARES");

        // per-USDC share price for the day (users claim pending * this / 1e18)
        s.sharesPerAsset[poolId][day] = (sharesMinted * 1e18) / pending;

        // the pending USDC becomes part of pool assets; batch shares are minted to
        // the "escrow" (counted in totalShares now, assigned to users on claim)
        s.idleUsdc[poolId] += pending;
        s.totalShares[poolId] += sharesMinted;

        s.currentDay = block.timestamp / 1 days;
        s.daySettled[poolId][day] = true;

        emit DaySettled(poolId, day, pending, sharesMinted);
    }

    /// @notice Convenience: is a given day ready to be settled (gate satisfied)?
    function canSettle(uint8 poolId, uint256 day) external view returns (bool) {
        if (s.daySettled[poolId][day]) return false;
        return s.pendingDeposit[poolId][day] >= s.minPendingToSettle[poolId];
    }

    function daySettled(uint8 poolId, uint256 day) external view returns (bool) {
        return s.daySettled[poolId][day];
    }

    function sharesPerAsset(uint8 poolId, uint256 day) external view returns (uint256) {
        return s.sharesPerAsset[poolId][day];
    }
}
