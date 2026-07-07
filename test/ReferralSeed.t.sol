// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovernanceTestBase} from "./helpers/GovernanceTestBase.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {ReferralVault} from "../src/referral/ReferralVault.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/*//////////////////////////////////////////////////////////////////////////
            ReferralSeed.t.sol — everything the seed script does
//////////////////////////////////////////////////////////////////////////*/
/**
 *  Verifies, on top of the shared GovernanceTestBase setUp:
 *
 *   SEED STATE      codes created + investors linked + rates set on 0/1/2
 *   ADMIN HANDOFF   referral vault admin == ArthaTimelock; deployer locked out
 *   ACCRUAL MATH    exact accumulator math incl. the rate-change boundary
 *   RATE UPDATES    pools 0,1,2 individually updated by the timelock admin
 *   CLAIMS          claim / claimAll, owner gating, funding accounting
 *   TRANSFERS       two-step approve -> execute, revoke, invariant re-check
 *   SAFETY          pause, onlyPool, withdraw clamp, rescue excess-only,
 *                   deactivate wind-down
 */
contract ReferralSeedTest is GovernanceTestBase {
    /*//////////////////////////////////////////////////////////////
                        ACCRUAL MATH (mirror)
    //////////////////////////////////////////////////////////////*/

    /// @dev Exact mirror of the contract's accumulator step so asserts are
    ///      bit-exact:  accDelta = rate * dt * ACC / (USDC_UNIT * YEAR).
    function _accDelta(uint256 rate, uint256 dt) internal pure returns (uint256) {
        return (rate * dt * 1e18) / (1e6 * 365 days);
    }

    /// @dev earned for `balance` over one accumulator delta.
    function _earnedFor(uint256 balance, uint256 accDelta_) internal pure returns (uint256) {
        return (balance * accDelta_) / 1e18;
    }

    /*//////////////////////////////////////////////////////////////
                          1. SEEDED STATE
    //////////////////////////////////////////////////////////////*/

    function test_Seed_CodesCreatedAndTradersLinked() public view {
        // codes -> owners
        assertEq(vault.codeOwner(CODE_A), referrerA);
        assertEq(vault.codeOwner(CODE_B), referrerB);
        assertEq(vault.codeOwner(CODE_C), referrerC);

        // owners -> codes (one code per owner)
        assertEq(vault.ownerToCode(referrerA), CODE_A);
        assertEq(vault.ownerToCode(referrerB), CODE_B);
        assertEq(vault.ownerToCode(referrerC), CODE_C);

        // investors linked once — every future deposit auto-credits the code
        assertEq(vault.traderToCode(investor1), CODE_A);
        assertEq(vault.traderToCode(investor2), CODE_B);
        assertEq(vault.traderToCode(investor3), CODE_C);

        // a live code has an owner; an unknown code resolves to address(0)
        assertTrue(vault.codeOwner(CODE_A) != address(0));
        assertEq(vault.codeOwner(9999), address(0));
    }

    function test_Seed_InitialRatesOnAllPools() public view {
        assertEq(_rate(0), RATE_LOW, "pool 0 = 0.50 ARTHA/USDC/yr");
        assertEq(_rate(1), RATE_MEDIUM, "pool 1 = 0.75 ARTHA/USDC/yr");
        assertEq(_rate(2), RATE_HIGH, "pool 2 = 1.00 ARTHA/USDC/yr");
    }

    function test_Seed_VaultFundedAndDiamondApproved() public view {
        assertEq(artha.balanceOf(address(vault)), VAULT_FUNDING);
        assertTrue(vault.approvedPools(address(diamond)));
    }

    /*//////////////////////////////////////////////////////////////
                    2. ADMIN == TIMELOCK (handoff)
    //////////////////////////////////////////////////////////////*/

    function test_Handoff_AdminIsTimelock() public view {
        assertEq(vault.referralVaultManager(), address(timelock));
    }

    function test_Handoff_OldAdminLockedOut() public {
        // deployer (this test contract) seeded everything pre-handoff, but is
        // now just a bystander for every admin entry point:
        vm.expectRevert(bytes("NOT_REFERRAL_VAULT_MANAGER"));
        vault.setRate(0, 1e18);

        vm.expectRevert(bytes("NOT_REFERRAL_VAULT_MANAGER"));
        vault.createCode(2001, makeAddr("newRef"));

        vm.expectRevert(bytes("NOT_REFERRAL_VAULT_MANAGER"));
        vault.setPool(makeAddr("fakePool"), true);

        vm.expectRevert(bytes("NOT_REFERRAL_VAULT_MANAGER"));
        vault.pause();

        vm.expectRevert(bytes("NOT_REFERRAL_VAULT_MANAGER"));
        vault.setReferralVaultManager(address(this)); // can't grab it back
    }

    function test_Handoff_TimelockHoldsEveryAdminPower() public {
        vm.startPrank(address(timelock));
        vault.setRate(0, 0.6e18);
        vault.createCode(2001, makeAddr("newRef"));
        vault.setPool(makeAddr("otherPool"), true);
        vault.pause();
        vault.unpause();
        vm.stopPrank();

        assertEq(_rate(0), 0.6e18);
        assertEq(vault.codeOwner(2001), makeAddr("newRef"));
    }

    /*//////////////////////////////////////////////////////////////
                     3. CODE / LINK VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_CreateCode_Reverts() public {
        vm.startPrank(address(timelock));

        vm.expectRevert(bytes("INVALID_CODE"));
        vault.createCode(0, makeAddr("x"));

        vm.expectRevert(bytes("INVALID_OWNER"));
        vault.createCode(4001, address(0));

        vm.expectRevert(bytes("CODE_EXISTS"));
        vault.createCode(CODE_A, makeAddr("x")); // 1001 already exists

        vm.expectRevert(bytes("OWNER_HAS_CODE"));
        vault.createCode(4001, referrerA); // referrerA already owns 1001

        vm.stopPrank();
    }

    function test_SetTraderCode_Reverts() public {
        // investor1 already linked in setUp — linking is ONE-TIME
        vm.prank(investor1);
        vm.expectRevert(bytes("CODE_ALREADY_SET"));
        vault.setTraderCode(CODE_B);

        // cannot link to a code that does not exist
        address fresh = makeAddr("freshInvestor");
        vm.prank(fresh);
        vm.expectRevert(bytes("CODE_DOES_NOT_EXIST"));
        vault.setTraderCode(9999);

        // a referrer cannot self-refer through their own code
        vm.prank(referrerA);
        vm.expectRevert(bytes("SELF_REFERRAL"));
        vault.setTraderCode(CODE_A);
    }

    /*//////////////////////////////////////////////////////////////
                 4. ACCRUAL MATH — "assign values"
    //////////////////////////////////////////////////////////////*/

    function test_Deposit_AccruesExactly_HighPool() public {
        // investor1 (linked to CODE_A) deposits 1,000 USDC into HIGH (pool 2).
        //   rate  = 1.0 ARTHA / USDC / yr
        //   time  = 30 days
        //   human math: 1000 * 1.0 * 30/365 = 82.19178... ARTHA
        uint256 principal = 1_000e6;
        diamond.deposit(2, investor1, principal);

        (uint256 bal,,,) = vault.codeAccount(2, CODE_A);
        assertEq(bal, principal, "referred balance recorded");
        (,,, uint256 totalReferred) = vault.poolState(2);
        assertEq(totalReferred, principal);

        vm.warp(block.timestamp + 30 days);

        uint256 expected = _earnedFor(principal, _accDelta(RATE_HIGH, 30 days));
        assertEq(vault.pendingReward(2, CODE_A), expected, "exact 30-day accrual");
        // sanity band on the human number (82.19 ARTHA)
        assertApproxEqAbs(expected, 82.191780e18, 0.000001e18);

        // nothing leaks into pools the code has no balance in
        assertEq(vault.pendingReward(0, CODE_A), 0);
        assertEq(vault.pendingReward(1, CODE_A), 0);
    }

    function test_ThreePools_ThreeCodes_IndependentAccrual() public {
        // Each investor deposits into a different risk pool; each code accrues
        // at ITS pool's rate, fully independently.
        diamond.deposit(0, investor1, 10_000e6); // CODE_A @ 0.50
        diamond.deposit(1, investor2, 10_000e6); // CODE_B @ 0.75
        diamond.deposit(2, investor3, 10_000e6); // CODE_C @ 1.00

        vm.warp(block.timestamp + 365 days); // exactly one year

        // one full year of 10,000 USDC:
        //   pool 0: 10_000 * 0.50 = 5_000 ARTHA
        //   pool 1: 10_000 * 0.75 = 7_500 ARTHA
        //   pool 2: 10_000 * 1.00 = 10_000 ARTHA
        assertEq(vault.pendingReward(0, CODE_A), 5_000e18);
        assertEq(vault.pendingReward(1, CODE_B), 7_500e18);
        assertEq(vault.pendingReward(2, CODE_C), 10_000e18);

        assertEq(vault.pendingRewardAllPools(CODE_A), 5_000e18);
    }

    /*//////////////////////////////////////////////////////////////
            5. RATE UPDATES for pools 0,1,2 (the core ask)
    //////////////////////////////////////////////////////////////*/

    function test_UpdateRates_AllThreePools_ByTimelockAdmin() public {
        vm.startPrank(address(timelock));
        vault.setRate(0, 0.40e18);
        vault.setRate(1, 0.80e18);
        vault.setRate(2, 1.20e18);
        vm.stopPrank();

        assertEq(_rate(0), 0.40e18);
        assertEq(_rate(1), 0.80e18);
        assertEq(_rate(2), 1.20e18);
    }

    function test_RateChange_SettlesOldRateFirst_NeverRetroactive() public {
        // THE boundary case from the design review: accrual before the change
        // must stay at the OLD rate; only accrual after uses the NEW rate.
        uint256 principal = 1_000e6;
        diamond.deposit(2, investor1, principal); // HIGH @ 1.0

        vm.warp(block.timestamp + 30 days); // month 1 at 1.0

        vm.prank(address(timelock));
        vault.setRate(2, 0.5e18); // 1.0 -> 0.5, banks month 1 first

        vm.warp(block.timestamp + 30 days); // month 2 at 0.5

        // month 1: 1000 * 1.0 * 30/365 = 82.19178 ARTHA
        // month 2: 1000 * 0.5 * 30/365 = 41.09589 ARTHA
        uint256 m1 = _earnedFor(principal, _accDelta(1e18, 30 days));
        uint256 m2 = _earnedFor(principal, _accDelta(0.5e18, 30 days));
        assertEq(vault.pendingReward(2, CODE_A), m1 + m2, "old rate banked, not a token more");

        // and the accumulator's lastUpdate moved at the rate change
        (uint256 rNow,, uint256 lastUpdate,) = vault.poolState(2);
        assertEq(rNow, 0.5e18);
        assertEq(lastUpdate, block.timestamp - 30 days);
    }

    function test_RateUpdated_EventEmitted() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit ReferralVault.RateUpdated(1, RATE_MEDIUM, 0.9e18);
        vm.prank(address(timelock));
        vault.setRate(1, 0.9e18);
    }

    /*//////////////////////////////////////////////////////////////
                       6. WITHDRAW / SETTLE
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_SettlesThenReduces_AndClamps() public {
        diamond.deposit(2, investor1, 1_000e6);
        vm.warp(block.timestamp + 10 days);

        // withdrawing settles first, so the 10 days are banked into `earned`
        diamond.withdraw(2, investor1, 400e6);
        (uint256 bal,, uint256 earned,) = vault.codeAccount(2, CODE_A);
        assertEq(bal, 600e6);
        assertEq(earned, _earnedFor(1_000e6, _accDelta(RATE_HIGH, 10 days)));

        // defensive clamp: asking for more than the balance drains to zero,
        // never reverts and never underflows totalReferred
        diamond.withdraw(2, investor1, 5_000e6);
        (bal,,,) = vault.codeAccount(2, CODE_A);
        assertEq(bal, 0);
        (,,, uint256 totalReferred) = vault.poolState(2);
        assertEq(totalReferred, 0);
    }

    function test_FlashDepositWithdraw_EarnsNothing() public {
        // the wash attack the time-based design kills: in-and-out in one
        // second of block time accrues ~0
        diamond.deposit(2, investor1, 1_000_000e6);
        diamond.withdraw(2, investor1, 1_000_000e6); // same timestamp
        assertEq(vault.pendingReward(2, CODE_A), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            7. CLAIMS
    //////////////////////////////////////////////////////////////*/

    function test_Claim_OwnerOnly_ExactAccounting() public {
        diamond.deposit(2, investor1, 1_000e6);
        vm.warp(block.timestamp + 365 days); // 1000 ARTHA pending

        // not the owner -> rejected
        vm.prank(investor1);
        vm.expectRevert(bytes("NOT_CODE_OWNER"));
        vault.claim(2, CODE_A, investor1, 1e18);

        // owner claims part of it to a payout wallet
        address payout = makeAddr("payoutA");
        vm.prank(referrerA);
        vault.claim(2, CODE_A, payout, 400e18);

        assertEq(artha.balanceOf(payout), 400e18);
        (,, uint256 earned, uint256 claimed) = vault.codeAccount(2, CODE_A);
        assertEq(earned, 600e18);
        assertEq(claimed, 400e18);
        assertEq(vault.totalClaimedArtha(), 400e18);
        assertEq(vault.totalEarnedArtha(), 1_000e18);

        // over-claim of the remainder -> rejected
        vm.prank(referrerA);
        vm.expectRevert(bytes("INSUFFICIENT_REWARDS"));
        vault.claim(2, CODE_A, payout, 600e18 + 1);
    }

    function test_ClaimAll_SweepsEveryPool() public {
        // same code earns in all three pools (three deposits by investor1)
        diamond.deposit(0, investor1, 1_000e6);
        diamond.deposit(1, investor1, 1_000e6);
        diamond.deposit(2, investor1, 1_000e6);
        vm.warp(block.timestamp + 365 days);

        // 0.5 + 0.75 + 1.0 = 2.25 => 2,250 ARTHA total
        uint256 total = vault.pendingRewardAllPools(CODE_A);
        assertEq(total, 2_250e18);

        address payout = makeAddr("payoutAll");
        vm.prank(referrerA);
        vault.claimAll(CODE_A, payout);

        assertEq(artha.balanceOf(payout), total);
        assertEq(vault.pendingRewardAllPools(CODE_A), 0);
        assertEq(vault.totalClaimedArtha(), total);
    }

    /*//////////////////////////////////////////////////////////////
                   8. TWO-STEP OWNERSHIP TRANSFER
    //////////////////////////////////////////////////////////////*/

    function test_TwoStepTransfer_ApproveThenAdminExecutes() public {
        address newOwner = makeAddr("newOwnerA");

        // step 1 — CURRENT owner approves
        vm.prank(referrerA);
        vault.approveTransfer(CODE_A, newOwner);
        assertEq(vault.pendingCodeOwner(CODE_A), newOwner);

        // nobody but the admin can execute
        vm.prank(referrerA);
        vm.expectRevert(bytes("NOT_REFERRAL_VAULT_MANAGER"));
        vault.executeTransfer(CODE_A);

        // step 2 — ADMIN (timelock) executes; approval consumed
        vm.prank(address(timelock));
        vault.executeTransfer(CODE_A);

        assertEq(vault.codeOwner(CODE_A), newOwner);
        assertEq(vault.ownerToCode(referrerA), 0);
        assertEq(vault.ownerToCode(newOwner), CODE_A);
        assertEq(vault.pendingCodeOwner(CODE_A), address(0));

        // reward stream follows the code: NEW owner claims, old owner cannot
        diamond.deposit(2, investor1, 1_000e6);
        vm.warp(block.timestamp + 365 days);

        vm.prank(referrerA);
        vm.expectRevert(bytes("NOT_CODE_OWNER"));
        vault.claim(2, CODE_A, referrerA, 1e18);

        vm.prank(newOwner);
        vault.claim(2, CODE_A, newOwner, 1_000e18);
        assertEq(artha.balanceOf(newOwner), 1_000e18);
    }

    function test_TwoStepTransfer_RevokeBeforeExecute() public {
        address newOwner = makeAddr("newOwnerA");
        vm.prank(referrerA);
        vault.approveTransfer(CODE_A, newOwner);

        vm.prank(referrerA);
        vault.revokeTransferApproval(CODE_A);
        assertEq(vault.pendingCodeOwner(CODE_A), address(0));

        vm.prank(address(timelock));
        vm.expectRevert(bytes("NO_PENDING_TRANSFER"));
        vault.executeTransfer(CODE_A);
    }

    function test_TwoStepTransfer_ReChecksInvariantAtExecution() public {
        // approving someone who already owns a code fails immediately
        vm.prank(referrerA);
        vm.expectRevert(bytes("NEW_OWNER_HAS_CODE"));
        vault.approveTransfer(CODE_A, referrerB);

        // the sneaky in-between case: target was clean at approval time but
        // acquires a code BEFORE execution -> execution must re-check + refuse
        address target = makeAddr("targetOwner");
        vm.prank(referrerA);
        vault.approveTransfer(CODE_A, target);

        vm.prank(address(timelock));
        vault.createCode(3001, target); // target now holds a code

        vm.prank(address(timelock));
        vm.expectRevert(bytes("NEW_OWNER_HAS_CODE"));
        vault.executeTransfer(CODE_A);
    }

    /*//////////////////////////////////////////////////////////////
                   9. DEACTIVATION (wind-down rule)
    //////////////////////////////////////////////////////////////*/

    function test_Deactivate_RequiresFullWindDown() public {
        diamond.deposit(2, investor1, 1_000e6);
        vm.warp(block.timestamp + 30 days);

        // live balance -> blocked (rewards would be stranded)
        vm.prank(referrerA);
        vm.expectRevert(bytes("HAS_ACTIVE_BALANCE"));
        vault.deactivateCode(CODE_A);

        // balance gone but rewards unclaimed -> still blocked
        diamond.withdraw(2, investor1, 1_000e6);
        vm.prank(referrerA);
        vm.expectRevert(bytes("HAS_UNCLAIMED_REWARDS"));
        vault.deactivateCode(CODE_A);

        // claim everything -> now the OWNER can retire the code
        vm.prank(referrerA);
        vault.claimAll(CODE_A, referrerA);
        vm.prank(referrerA);
        vault.deactivateCode(CODE_A);

        assertEq(vault.codeOwner(CODE_A), address(0));

        // dead code: new investors cannot link it...
        address fresh = makeAddr("freshInvestor2");
        vm.prank(fresh);
        vm.expectRevert(bytes("CODE_DOES_NOT_EXIST"));
        vault.setTraderCode(CODE_A);

        // ...and deposits from already-linked investors silently stop crediting
        diamond.deposit(2, investor1, 500e6);
        (uint256 bal,,,) = vault.codeAccount(2, CODE_A);
        assertEq(bal, 0, "deactivated code accrues nothing");
    }

    function test_Deactivate_StrangerCannot() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("NOT_OWNER_OR_ADMIN"));
        vault.deactivateCode(CODE_A);
    }

    /*//////////////////////////////////////////////////////////////
                        10. PAUSE + ACCESS
    //////////////////////////////////////////////////////////////*/

    function test_Pause_FreezesHooksAndClaims() public {
        diamond.deposit(2, investor1, 1_000e6);
        vm.warp(block.timestamp + 365 days);

        vm.prank(address(timelock));
        vault.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        diamond.deposit(2, investor1, 1e6);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        diamond.withdraw(2, investor1, 1e6);

        vm.prank(referrerA);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.claim(2, CODE_A, referrerA, 1e18);

        vm.prank(address(timelock));
        vault.unpause();

        vm.prank(referrerA);
        vault.claim(2, CODE_A, referrerA, 1e18); // flows again
    }

    function test_OnlyApprovedPool_CanNotify() public {
        vm.prank(makeAddr("randomEOA"));
        vm.expectRevert(bytes("NOT_ALLOWED_POOL"));
        vault.notifyDeposit(2, investor1, 1_000e6);

        vm.prank(makeAddr("randomEOA"));
        vm.expectRevert(bytes("NOT_ALLOWED_POOL"));
        vault.notifyWithdraw(2, investor1, 1_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                     11. RESCUE — EXCESS ONLY
    //////////////////////////////////////////////////////////////*/

    function test_Rescue_ArthaOnlyAboveOwed() public {
        // create 1,000 ARTHA of SETTLED debt to the codes
        diamond.deposit(2, investor1, 1_000e6);
        vm.warp(block.timestamp + 365 days);
        vault.sync(2, CODE_A); // settle so `owed` is on the books

        uint256 owed = vault.totalEarnedArtha() - vault.totalClaimedArtha();
        assertEq(owed, 1_000e18);
        // rescuable excess mirrors the contract's inline cap: balance - owed
        uint256 excess = VAULT_FUNDING - owed;

        address safe = makeAddr("treasurySafe");

        // touching the owed portion is refused
        vm.prank(address(timelock));
        vm.expectRevert(bytes("EXCEEDS_EXCESS"));
        vault.rescue(address(artha), safe, excess + 1);

        // sweeping the true excess is fine — codes stay fully payable
        vm.prank(address(timelock));
        vault.rescue(address(artha), safe, excess);
        assertEq(artha.balanceOf(safe), excess);

        vm.prank(referrerA);
        vault.claim(2, CODE_A, referrerA, 1_000e18); // owed still there
    }

    function test_Rescue_StrayTokenFully() public {
        MockERC20 stray = new MockERC20("Mock USDC", "mUSDC", 6);
        stray.mint(address(vault), 777e6); // someone fat-fingered a transfer

        address safe = makeAddr("treasurySafe");
        vm.prank(address(timelock));
        vault.rescue(address(stray), safe, 777e6);
        assertEq(stray.balanceOf(safe), 777e6);
    }
}
