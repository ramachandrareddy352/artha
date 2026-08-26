// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {UserRewardVault} from "../../src/rewards/UserRewardVault.sol";
import {MockERC20} from "../mocks/Mocks.sol";

contract RewardsTest is Test {
    UserRewardVault internal rewards;
    MockERC20 internal artha;
    MockERC20 internal shareToken;

    address internal manager = address(this);
    address internal vaultId = address(0x7A017);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    uint256 internal constant RATE = 1e12;

    function setUp() public {
        vm.warp(365 days);

        artha = new MockERC20("Artha", "ARTHA", 18);
        shareToken = new MockERC20("Share", "avSHARE", 18);
        rewards = new UserRewardVault(address(artha), manager);

        rewards.registerVault(vaultId, address(shareToken), RATE);
        artha.mint(address(rewards), 5_000_000e18);

        shareToken.mint(alice, 1_000e18);
        shareToken.mint(bob, 1_000e18);
        shareToken.mint(carol, 1_000e18);
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        shareToken.approve(address(rewards), type(uint256).max);
        rewards.stake(vaultId, who, amount);
        vm.stopPrank();
    }

    function _skip(uint256 d) internal {
        vm.warp(vm.getBlockTimestamp() + d);
    }

    // ───────────── R1: accrual depends only on your own shares and time ─────────

    function test_R1_accrualIsProportionalToOwnSharesAndTime() public {
        _stake(alice, 100e18);
        _skip(1 days);

        uint256 expected = (100e18 * RATE * 1 days) / 1e18;
        assertEq(rewards.pendingArtha(vaultId, alice), expected);
    }

    function test_R1_anotherUserStakingDoesNotDiluteYou() public {
        _stake(alice, 100e18);
        _skip(1 days);
        uint256 aliceAfterDayOne = rewards.pendingArtha(vaultId, alice);

        _stake(bob, 900e18);
        _skip(1 days);

        uint256 aliceAfterDayTwo = rewards.pendingArtha(vaultId, alice);
        assertEq(aliceAfterDayTwo, aliceAfterDayOne * 2);
    }

    function test_R3_unstakingByAnotherUserDoesNotAffectYourAccrual() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        _skip(1 days);

        vm.prank(bob);
        rewards.unstake(vaultId, 100e18);
        _skip(1 days);

        uint256 expected = (100e18 * RATE * 2 days) / 1e18;
        assertEq(rewards.pendingArtha(vaultId, alice), expected);
    }

    function testFuzz_R1_accrualScalesLinearly(uint96 shares, uint32 elapsed) public {
        uint256 amount = bound(shares, 1e18, 1_000e18);
        uint256 dt = bound(elapsed, 1, 365 days);

        _stake(alice, amount);
        _skip(dt);

        assertEq(rewards.pendingArtha(vaultId, alice), (amount * RATE * dt) / 1e18);
    }

    // ─────────────── R2: a rate change is never retroactive ─────────────────────

    function test_R2_rateChangeAppliesOldRateToOldPeriod() public {
        _stake(alice, 100e18);
        _skip(1 days);

        uint256 earnedAtOldRate = (100e18 * RATE * 1 days) / 1e18;

        rewards.setRewardRate(vaultId, RATE * 2);
        _skip(1 days);

        uint256 earnedAtNewRate = (100e18 * RATE * 2 * 1 days) / 1e18;
        assertEq(rewards.pendingArtha(vaultId, alice), earnedAtOldRate + earnedAtNewRate);
    }

    function test_R2_rateDropToZeroStopsAccrualWithoutLosingWhatWasEarned() public {
        _stake(alice, 100e18);
        _skip(1 days);
        uint256 earned = rewards.pendingArtha(vaultId, alice);

        rewards.setRewardRate(vaultId, 0);
        _skip(30 days);

        assertEq(rewards.pendingArtha(vaultId, alice), earned);
    }

    function test_R2_anUntouchedPositionIsChargedEachRateForItsOwnStretch() public {
        _stake(alice, 100e18);

        _skip(1 days);
        rewards.setRewardRate(vaultId, RATE * 3);
        _skip(1 days);
        rewards.setRewardRate(vaultId, RATE);
        _skip(1 days);

        uint256 expected = (100e18 * 1 days * (RATE + RATE * 3 + RATE)) / 1e18;
        assertEq(rewards.pendingArtha(vaultId, alice), expected);
    }

    // ────────────────────────── staking mechanics ───────────────────────────────

    function test_R3_stakeSettlesBeforeChangingTheBalance() public {
        _stake(alice, 100e18);
        _skip(1 days);

        uint256 beforeSecondStake = rewards.pendingArtha(vaultId, alice);
        _stake(alice, 100e18);
        _skip(1 days);

        uint256 expected = beforeSecondStake + (200e18 * RATE * 1 days) / 1e18;
        assertEq(rewards.pendingArtha(vaultId, alice), expected);
    }

    function test_R3_stakingForAnotherUserGivesThemThePosition() public {
        vm.startPrank(alice);
        shareToken.approve(address(rewards), type(uint256).max);
        rewards.stake(vaultId, bob, 100e18);
        vm.stopPrank();

        _skip(1 days);

        assertGt(rewards.pendingArtha(vaultId, bob), 0);
        assertEq(rewards.pendingArtha(vaultId, alice), 0);

        vm.prank(alice);
        vm.expectRevert(bytes("INSUFFICIENT_STAKE"));
        rewards.unstake(vaultId, 100e18);

        vm.prank(bob);
        rewards.unstake(vaultId, 100e18);
        assertEq(shareToken.balanceOf(bob), 1_000e18 + 100e18);
    }

    function test_R3_unstakeReturnsSharesAndBanksAccrual() public {
        _stake(alice, 100e18);
        _skip(1 days);

        vm.prank(alice);
        rewards.unstake(vaultId, 100e18);

        assertEq(shareToken.balanceOf(alice), 1_000e18);
        assertGt(rewards.pendingArtha(vaultId, alice), 0);

        _skip(30 days);
        assertEq(rewards.pendingArtha(vaultId, alice), (100e18 * RATE * 1 days) / 1e18);
    }

    function test_R3_cannotUnstakeMoreThanStaked() public {
        _stake(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(bytes("INSUFFICIENT_STAKE"));
        rewards.unstake(vaultId, 101e18);
    }

    // ──────────────────────────── claiming ──────────────────────────────────────

    function test_R4_claimTransfersArthaAndClearsTheBalance() public {
        _stake(alice, 100e18);
        _skip(10 days);

        uint256 owed = rewards.pendingArtha(vaultId, alice);
        vm.prank(alice);
        rewards.claimArtha(vaultId);

        assertEq(artha.balanceOf(alice), owed);
        assertEq(rewards.pendingArtha(vaultId, alice), 0);
    }

    function test_R4_claimWithNothingOwedReverts() public {
        _stake(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(bytes("NOTHING_TO_CLAIM"));
        rewards.claimArtha(vaultId);
    }

    function test_R4_partialLiquidityPaysWhatItCanAndKeepsTheRemainderOwed() public {
        UserRewardVault poor = new UserRewardVault(address(artha), manager);
        poor.registerVault(vaultId, address(shareToken), RATE);
        artha.mint(address(poor), 1e18);

        vm.startPrank(alice);
        shareToken.approve(address(poor), type(uint256).max);
        poor.stake(vaultId, alice, 100e18);
        vm.stopPrank();

        _skip(30 days);
        uint256 owed = poor.pendingArtha(vaultId, alice);
        assertGt(owed, 1e18);

        uint256 balBefore = artha.balanceOf(alice);
        vm.prank(alice);
        poor.claimArtha(vaultId);

        assertEq(artha.balanceOf(alice) - balBefore, 1e18);
        assertApproxEqAbs(poor.pendingArtha(vaultId, alice), owed - 1e18, 1e12);
    }

    // ───────────── R5: the escape hatch always returns principal ────────────────

    function test_R5_emergencyUnstakeWorksWhilePaused() public {
        _stake(alice, 100e18);
        _skip(1 days);

        rewards.pause();

        vm.prank(alice);
        vm.expectRevert();
        rewards.unstake(vaultId, 100e18);

        vm.prank(alice);
        rewards.emergencyUnstake(vaultId);
        assertEq(shareToken.balanceOf(alice), 1_000e18);
    }

    function test_R5_emergencyUnstakeWorksWithNoArthaLeft() public {
        UserRewardVault empty = new UserRewardVault(address(artha), manager);
        empty.registerVault(vaultId, address(shareToken), RATE);

        vm.startPrank(alice);
        shareToken.approve(address(empty), type(uint256).max);
        empty.stake(vaultId, alice, 100e18);
        vm.stopPrank();

        _skip(10 days);

        vm.prank(alice);
        empty.emergencyUnstake(vaultId);
        assertEq(shareToken.balanceOf(alice), 1_000e18);
    }

    function test_R5_emergencyUnstakeForfeitsUnsettledButKeepsSettled() public {
        _stake(alice, 100e18);
        _skip(1 days);

        vm.prank(alice);
        rewards.unstake(vaultId, 50e18);
        uint256 settled = rewards.pendingArtha(vaultId, alice);
        assertGt(settled, 0);

        _skip(1 days);

        vm.prank(alice);
        rewards.emergencyUnstake(vaultId);

        assertEq(shareToken.balanceOf(alice), 1_000e18);
        assertEq(rewards.pendingArtha(vaultId, alice), settled);
    }

    function test_R5_emergencyUnstakeWithNoStakeReverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NO_STAKE"));
        rewards.emergencyUnstake(vaultId);
    }

    // ───────────────────────── R6: rescue is bounded ────────────────────────────

    function test_R6_rescueCannotTakeStakedShareTokens() public {
        _stake(alice, 100e18);

        vm.expectRevert(bytes("CANNOT_RESCUE_SHARES"));
        rewards.rescue(address(shareToken), manager, 100e18);
    }

    function test_R6_rescueCannotTakeSettledArthaThatIsOwed() public {
        _stake(alice, 100e18);
        _skip(100 days);

        vm.prank(alice);
        rewards.unstake(vaultId, 1);

        uint256 owed = rewards.outstandingArtha();
        assertGt(owed, 0);

        uint256 balance = artha.balanceOf(address(rewards));
        vm.expectRevert(bytes("EXCEEDS_EXCESS"));
        rewards.rescue(address(artha), manager, balance);

        rewards.rescue(address(artha), manager, balance - owed);
        assertEq(artha.balanceOf(address(rewards)), owed);
    }

    function test_R6_rescueCannotTakeArthaThatIsAccruedButNotYetSettled() public {
        _stake(alice, 100e18);
        _skip(100 days);

        uint256 economicallyOwed = rewards.pendingArtha(vaultId, alice);
        assertGt(economicallyOwed, 0);
        assertEq(rewards.outstandingArtha(), economicallyOwed);

        uint256 balance = artha.balanceOf(address(rewards));
        vm.expectRevert(bytes("EXCEEDS_EXCESS"));
        rewards.rescue(address(artha), manager, balance);

        rewards.rescue(address(artha), manager, balance - economicallyOwed);

        vm.prank(alice);
        rewards.claimArtha(vaultId);
        assertEq(artha.balanceOf(alice), economicallyOwed);
    }

    function test_R6_outstandingTracksMultipleStakersWithoutSettling() public {
        _stake(alice, 100e18);
        _stake(bob, 300e18);
        _skip(7 days);

        uint256 owed = rewards.pendingArtha(vaultId, alice) + rewards.pendingArtha(vaultId, bob);
        assertEq(rewards.outstandingArtha(), owed);
    }

    function test_R6_outstandingSurvivesUnstakeAndEmergencyUnstake() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        _skip(5 days);

        vm.prank(alice);
        rewards.unstake(vaultId, 50e18);

        vm.prank(bob);
        rewards.emergencyUnstake(vaultId);

        _skip(5 days);

        uint256 owed = rewards.pendingArtha(vaultId, alice) + rewards.pendingArtha(vaultId, bob);
        assertEq(rewards.outstandingArtha(), owed);
    }

    function test_R6_outstandingIsClampedToTheRemainingBudget() public {
        rewards.setRewardRate(vaultId, rewards.MAX_REWARD_RATE());
        _stake(alice, 1_000e18);
        _skip(3_650 days);

        assertLe(rewards.outstandingArtha(), rewards.MAX_ARTHA());
    }

    function testFuzz_R6_outstandingAlwaysCoversEveryStakersClaim(uint96 aliceShares, uint96 bobShares, uint32 elapsed)
        public
    {
        uint256 a = bound(aliceShares, 1e18, 1_000e18);
        uint256 b = bound(bobShares, 1e18, 1_000e18);
        uint256 dt = bound(elapsed, 1, 3_650 days);

        _stake(alice, a);
        _stake(bob, b);
        _skip(dt);

        uint256 claims = rewards.pendingArtha(vaultId, alice) + rewards.pendingArtha(vaultId, bob);
        assertGe(rewards.outstandingArtha(), claims > rewards.MAX_ARTHA() ? rewards.MAX_ARTHA() : claims);
    }

    function test_R6_rescueOfAnUnrelatedTokenIsAllowed() public {
        MockERC20 stray = new MockERC20("Stray", "STR", 18);
        stray.mint(address(rewards), 5e18);

        rewards.rescue(address(stray), manager, 5e18);
        assertEq(stray.balanceOf(manager), 5e18);
    }

    // ───────────────────────── budget and registration ──────────────────────────

    function test_R4_theLifetimeBudgetIsNeverExceeded() public {
        rewards.setRewardRate(vaultId, rewards.MAX_REWARD_RATE());
        _stake(alice, 1_000e18);
        _skip(3_650 days);

        vm.prank(alice);
        rewards.claimArtha(vaultId);
        assertLe(rewards.totalArthaMinted(), rewards.MAX_ARTHA());
    }

    function test_A1_onlyTheManagerMayRegisterOrRetune() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NOT_USER_REWARD_MANAGER"));
        rewards.setRewardRate(vaultId, 1);

        vm.prank(alice);
        vm.expectRevert(bytes("NOT_USER_REWARD_MANAGER"));
        rewards.registerVault(address(0xBEEF), address(shareToken), 1);
    }

    function test_A1_theRewardRateCeilingIsEnforced() public {
        uint256 max = rewards.MAX_REWARD_RATE();

        rewards.setRewardRate(vaultId, max);
        assertEq(rewards.rewardRateOf(vaultId), max);

        vm.expectRevert(bytes("RATE_TOO_HIGH"));
        rewards.setRewardRate(vaultId, max + 1);

        vm.expectRevert(bytes("RATE_TOO_HIGH"));
        rewards.registerVault(address(0xBEEF), address(shareToken), max + 1);
    }

    function test_A1_doubleRegistrationIsRefused() public {
        vm.expectRevert(bytes("ALREADY_REGISTERED"));
        rewards.registerVault(vaultId, address(shareToken), RATE);
    }

    function test_A1_stakingIntoAnUnregisteredVaultIsRefused() public {
        vm.startPrank(alice);
        shareToken.approve(address(rewards), type(uint256).max);
        vm.expectRevert(bytes("NOT_REGISTERED"));
        rewards.stake(address(0xBEEF), alice, 1e18);
        vm.stopPrank();
    }

    // ─────────────────────────── accounting integrity ───────────────────────────

    function test_I5_stakedSharesAlwaysMatchTheContractsShareBalance() public {
        _stake(alice, 100e18);
        _stake(bob, 250e18);
        _stake(carol, 50e18);

        assertEq(shareToken.balanceOf(address(rewards)), 400e18);

        vm.prank(bob);
        rewards.unstake(vaultId, 100e18);
        assertEq(shareToken.balanceOf(address(rewards)), 300e18);

        vm.prank(carol);
        rewards.emergencyUnstake(vaultId);
        assertEq(shareToken.balanceOf(address(rewards)), 250e18);
    }

    function test_I5_claimedNeverExceedsEarned() public {
        _stake(alice, 100e18);
        _skip(10 days);

        vm.prank(alice);
        rewards.claimArtha(vaultId);

        (,, uint256 totalEarned, uint256 totalClaimed,) = rewards.getInfo(vaultId, alice);
        assertLe(totalClaimed, totalEarned);
        assertGt(totalClaimed, 0);
    }
}
