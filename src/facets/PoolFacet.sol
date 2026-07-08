// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Modifiers, AppStorage, RiskTier, PoolKind} from "../libraries/LibAppStorage.sol";
import {LibShares} from "../libraries/LibShares.sol";
import {LibStrategy} from "../libraries/LibStrategy.sol";
import {IReferralVault} from "../interfaces/IReferralVault.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  PoolFacet
 * @notice User entry points: request a deposit (queued for the day's batch),
 *         claim shares after the batch settles, and withdraw (USDC from buffer,
 *         or fully in-kind).
 *
 *  DEPOSITS ARE END-OF-DAY BATCHED (BatchFacet): requestDeposit only escrows USDC
 *  and records it for the day. No swap on entry.
 *
 *  WITHDRAW paths:
 *    - withdraw(...)        : pays USDC from the pool's idle buffer (reverts if the
 *                             buffer is short — top it up via AllocationFacet first).
 *    - withdrawInKind(...)  : pro-rata of EVERYTHING — idle USDC + idle basket
 *                             tokens + a pro-rata slice of each strategy position,
 *                             pulled and sent to the user. No swaps, always liquid.
 *
 *  FIXED / early-exit: withdrawing before lockedUntil applies earlyExitPenaltyBps.
 *  For the USDC path the penalty splits 10/20/70 (protocol/emergency/remaining).
 *  For the in-kind path the whole penalty stays in the pool (lifts remaining pps).
 */
contract PoolFacet is Modifiers {
    using SafeERC20 for IERC20;

    event DepositRequested(uint8 indexed poolId, address indexed user, uint256 day, uint256 usdcAmount);
    event SharesClaimed(uint8 indexed poolId, address indexed user, uint256 day, uint256 shares);
    event Withdrawn(uint8 indexed poolId, address indexed user, uint256 shares, uint256 payout, uint256 penalty);
    event WithdrawnInKind(uint8 indexed poolId, address indexed user, uint256 shares, uint256 penaltyShares);

    /// @dev Core pool (0..5) -> referral tier pool (0=LOW,1=MED,2=HIGH).
    function _referralPool(uint8 poolId) private view returns (uint8) {
        return uint8(s.poolTier[poolId]);
    }

    function _notifyRefWithdraw(uint8 poolId, uint256 assetsValue) private {
        if (s.referralVault != address(0)) {
            IReferralVault(s.referralVault).notifyWithdraw(_referralPool(poolId), msg.sender, assetsValue);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function requestDeposit(uint8 poolId, uint256 usdcAmount)
        external
        validPool(poolId)
        whenNotPaused
        nonReentrant
    {
        require(s.poolActive[poolId], "POOL_INACTIVE");
        require(usdcAmount >= s.minDepositUsdc, "BELOW_MIN_DEPOSIT");

        IERC20(s.usdc).safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 day = block.timestamp / 1 days;
        s.pendingDeposit[poolId][day] += usdcAmount;
        s.userPendingDeposit[poolId][day][msg.sender] += usdcAmount;

        uint256 lock = s.lockDuration[poolId];
        if (lock != 0) {
            uint256 unlockAt = block.timestamp + lock;
            if (unlockAt > s.lockedUntil[poolId][msg.sender]) {
                s.lockedUntil[poolId][msg.sender] = unlockAt;
            }
        }

        if (s.referralVault != address(0)) {
            IReferralVault(s.referralVault).notifyDeposit(_referralPool(poolId), msg.sender, usdcAmount);
        }

        emit DepositRequested(poolId, msg.sender, day, usdcAmount);
    }

    function claimShares(uint8 poolId, uint256 day) external validPool(poolId) nonReentrant returns (uint256 shares) {
        require(s.daySettled[poolId][day], "DAY_NOT_SETTLED");
        uint256 pending = s.userPendingDeposit[poolId][day][msg.sender];
        require(pending != 0, "NOTHING_TO_CLAIM");

        shares = (pending * s.sharesPerAsset[poolId][day]) / 1e18;

        s.userPendingDeposit[poolId][day][msg.sender] = 0;
        s.shares[poolId][msg.sender] += shares; // totalShares already counted at settle
        emit SharesClaimed(poolId, msg.sender, day, shares);
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAW — USDC (buffer)
    //////////////////////////////////////////////////////////////*/

    function withdraw(uint8 poolId, uint256 shares)
        external
        validPool(poolId)
        whenNotPaused
        nonReentrant
        returns (uint256 payout)
    {
        uint256 userShares = s.shares[poolId][msg.sender];
        require(shares != 0 && shares <= userShares, "BAD_SHARES");

        uint256 assets = LibShares.convertToAssets(poolId, shares);

        uint256 penalty;
        if (block.timestamp < s.lockedUntil[poolId][msg.sender]) {
            penalty = (assets * s.earlyExitPenaltyBps) / 10000;
        }
        payout = assets - penalty;

        s.shares[poolId][msg.sender] = userShares - shares;
        s.totalShares[poolId] -= shares;

        require(s.idleUsdc[poolId] >= assets, "INSUFFICIENT_IDLE_LIQUIDITY");
        s.idleUsdc[poolId] -= assets;

        if (penalty != 0) {
            uint256 toProto = (penalty * s.penToProtocolBps) / 10000;
            uint256 toEmerg = (penalty * s.penToEmergencyBps) / 10000;
            uint256 toUsers = penalty - toProto - toEmerg;
            s.idleUsdc[poolId] += toUsers; // stays in pool -> lifts remaining pps
            if (toProto != 0) IERC20(s.usdc).safeTransfer(s.treasury, toProto);
            if (toEmerg != 0) IERC20(s.usdc).safeTransfer(s.emergencyFund, toEmerg);
        }

        _notifyRefWithdraw(poolId, assets);
        IERC20(s.usdc).safeTransfer(msg.sender, payout);
        emit Withdrawn(poolId, msg.sender, shares, payout, penalty);
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAW — IN-KIND (always liquid)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Redeem `shares` for a pro-rata slice of the pool's entire holdings:
     *         idle USDC, idle basket tokens, and a pro-rata cut of every strategy
     *         position (pulled from the venue and forwarded). No swaps, so this
     *         always has liquidity regardless of how deployed the pool is.
     */
    function withdrawInKind(uint8 poolId, uint256 shares)
        external
        validPool(poolId)
        whenNotPaused
        nonReentrant
    {
        uint256 userShares = s.shares[poolId][msg.sender];
        require(shares != 0 && shares <= userShares, "BAD_SHARES");

        uint256 supply = s.totalShares[poolId];      // pre-burn, denominator for fractions
        uint256 assetsValue = LibShares.convertToAssets(poolId, shares); // for referral

        uint256 penaltyShares;
        if (block.timestamp < s.lockedUntil[poolId][msg.sender]) {
            penaltyShares = (shares * s.earlyExitPenaltyBps) / 10000; // stays in pool
        }
        uint256 num = shares - penaltyShares; // net numerator paid to user

        // burn the full `shares`
        s.shares[poolId][msg.sender] = userShares - shares;
        s.totalShares[poolId] = supply - shares;

        // 1) fraction of idle USDC
        uint256 usdcOut = (s.idleUsdc[poolId] * num) / supply;
        if (usdcOut != 0) {
            s.idleUsdc[poolId] -= usdcOut;
            IERC20(s.usdc).safeTransfer(msg.sender, usdcOut);
        }

        // 2) fraction of idle basket tokens
        address[] memory basket = s.poolBasket[poolId];
        for (uint256 i; i < basket.length; i++) {
            uint256 bal = s.poolTokenBalance[poolId][basket[i]];
            uint256 outTok = (bal * num) / supply;
            if (outTok != 0) {
                s.poolTokenBalance[poolId][basket[i]] -= outTok;
                IERC20(basket[i]).safeTransfer(msg.sender, outTok);
            }
        }

        // 3) fraction of each strategy position, redeemed straight to the user
        LibStrategy.redeemProRataToUser(s, poolId, msg.sender, num, supply);

        _notifyRefWithdraw(poolId, assetsValue);
        emit WithdrawnInKind(poolId, msg.sender, shares, penaltyShares);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function pendingDepositOf(uint8 poolId, uint256 day, address user) external view returns (uint256) {
        return s.userPendingDeposit[poolId][day][user];
    }

    function lockedUntil(uint8 poolId, address user) external view returns (uint256) {
        return s.lockedUntil[poolId][user];
    }
}
