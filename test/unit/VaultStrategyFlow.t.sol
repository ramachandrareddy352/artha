// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultFixture} from "../helpers/VaultFixture.sol";
import {DepositFacet} from "../../src/facets/DepositFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {StrategyFacet} from "../../src/facets/StrategyFacet.sol";
import {EmergencyFacet} from "../../src/facets/EmergencyFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";

contract VaultStrategyFlowTest is VaultFixture {
    function setUp() public {
        _setUpFixture(1_000, 5_000);
    }

    function test_depositCreditsIdleAndMintsShares() public {
        uint256 shares = _deposit(alice, 100_000e6);

        assertGt(shares, 0);
        assertEq(_idleBalance(), 100_000e6);
        assertEq(_totalAssets(), 100_000e6);
        assertEq(usdc.balanceOf(address(vault)), 100_000e6);
    }

    function test_deployIdleRespectsWeightsAndIdleTarget() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);

        _deployIdle();

        assertEq(stratA.positionValue(), 50_000e6);
        assertEq(stratB.positionValue(), 40_000e6);
        assertEq(_idleBalance(), 10_000e6);
        assertEq(_totalAssets(), 100_000e6);
    }

    function test_yieldRaisesPricePerShareNotShareCount() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        uint256 sharesBefore = _shareToken().totalSupply();
        uint256 ppsBefore = _pps();

        venueA.accrueBps(1_000);
        _settle();

        assertEq(_shareToken().totalSupply(), sharesBefore);
        assertGt(_pps(), ppsBefore);
        assertEq(_totalAssets(), 105_000e6);
    }

    function test_withdrawDrainsIdleFirstThenStrategiesInOrder() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, 30_000e6);

        assertEq(usdc.balanceOf(alice) - before, 30_000e6);
        assertEq(_idleBalance(), 0);
        assertEq(stratA.positionValue(), 30_000e6);
        assertEq(stratB.positionValue(), 40_000e6);
    }

    function test_fullRedeemReturnsEverything() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        uint256 shares = _deposit(alice, 100_000e6);
        _deployIdle();

        uint256 before = usdc.balanceOf(alice);
        _redeem(alice, shares);

        assertApproxEqAbs(usdc.balanceOf(alice) - before, 100_000e6, 2);
        assertEq(_shareToken().balanceOf(alice), 0);
    }

    function test_rebalanceMovesCapitalBetweenStrategies() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        _setTargets(_strategiesArray(address(stratA), address(stratB)), _weightsArray(2_000, 7_000), 1_000);
        _rebalance();

        assertApproxEqAbs(stratA.positionValue(), 20_000e6, 10);
        assertApproxEqAbs(stratB.positionValue(), 70_000e6, 10);
        assertApproxEqAbs(_totalAssets(), 100_000e6, 10);
    }

    function test_rebalanceDoesNotChangePricePerShare() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        uint256 ppsBefore = _pps();
        _setTargets(_strategiesArray(address(stratA), address(stratB)), _weightsArray(2_000, 7_000), 1_000);
        _rebalance();

        assertApproxEqRel(_pps(), ppsBefore, 0.0001e18);
    }

    function test_harvestCreditsRealizedRewardsToIdle() public {
        _addSingleStrategy(address(stratAave), 9_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        aaveRewards.setClaimer(address(vault), address(stratAave));
        aaveRewards.accrue(address(vault), address(rewardToken), 100e18);

        uint256 idleBefore = _idleBalance();
        uint256 realized = _harvest(address(stratAave));

        assertEq(realized, 1_000e6);
        assertEq(_idleBalance(), idleBefore + 1_000e6);
    }

    function test_harvestAllSkipsNothingWhenAllHealthy() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        _harvestAll();
        assertEq(_totalAssets(), 100_000e6);
    }

    function test_settleIsPermissionlessAndRefreshesNav() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        venueA.accrueBps(500);

        vm.prank(address(0xDEADBEEF));
        StrategyFacet(payable(address(vault))).settle();

        assertEq(_totalAssets(), 102_500e6);
    }

    function test_circuitBreakerTripsAndAutoPausesOnAJump() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        venueA.accrueBps(9_000);
        _settle();

        (, bool brokenBefore,) = _strategyStatus(address(stratA));
        assertFalse(brokenBefore);

        _harvestAll();

        (, bool broken,) = _strategyStatus(address(stratA));
        assertTrue(broken);
        assertTrue(ViewFacet(payable(address(vault))).vaultConfig().paused);
    }

    function test_brokenStrategyKeepsLastValueAndBlocksNewDeploys() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        venueA.accrueBps(9_000);
        _harvestAll();

        (, bool broken, uint256 lastValue) = _strategyStatus(address(stratA));
        assertTrue(broken);
        assertEq(lastValue, 50_000e6);

        vm.prank(KEEPER);
        vm.expectRevert(bytes("STRATEGY_BROKEN"));
        StrategyFacet(payable(address(vault))).harvest(address(stratA));
    }

    function test_pausedVaultBlocksDepositAndWithdrawButNotEmergency() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        uint256 shares = _deposit(alice, 100_000e6);
        _deployIdle();

        _pause();

        vm.startPrank(bob);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(bytes("PAUSED"));
        DepositFacet(payable(address(vault))).deposit(1_000e6, bob, 0);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(bytes("PAUSED"));
        WithdrawFacet(payable(address(vault))).withdraw(1_000e6, alice, alice, type(uint256).max);

        uint256 before = usdc.balanceOf(alice);
        _emergencyWithdraw(alice, shares);
        assertGt(usdc.balanceOf(alice) - before, 0);
    }

    function test_onlyGovernanceCanUnpause() public {
        _pause();

        vm.prank(GUARDIAN);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        EmergencyFacet(payable(address(vault))).unpauseVault();

        vm.prank(alice);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        EmergencyFacet(payable(address(vault))).unpauseVault();

        _unpause();
        _deposit(alice, 1_000e6);
    }

    function test_guardianCanPauseButNobodyElseCan() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NOT_GUARDIAN"));
        EmergencyFacet(payable(address(vault))).pauseVault();

        _pause();
        assertTrue(ViewFacet(payable(address(vault))).vaultConfig().paused);
    }

    function test_keeperOnlyGuards() public {
        _addTwoStrategies(5_000, 4_000, 1_000);

        vm.prank(alice);
        vm.expectRevert(bytes("NOT_KEEPER"));
        StrategyFacet(payable(address(vault))).deployIdle();

        vm.prank(alice);
        vm.expectRevert(bytes("NOT_KEEPER"));
        StrategyFacet(payable(address(vault))).rebalance();

        vm.prank(alice);
        vm.expectRevert(bytes("NOT_KEEPER"));
        StrategyFacet(payable(address(vault))).harvestAll();

        vm.prank(alice);
        vm.expectRevert(bytes("NOT_KEEPER"));
        StrategyFacet(payable(address(vault))).tendAll();
    }

    function test_harvestOfUnregisteredStrategyIsRejected() public {
        vm.prank(KEEPER);
        vm.expectRevert(bytes("UNKNOWN_STRATEGY"));
        StrategyFacet(payable(address(vault))).harvest(address(stratA));
    }

    function test_tendOfUnregisteredStrategyIsRejected() public {
        vm.prank(KEEPER);
        vm.expectRevert(bytes("UNKNOWN_STRATEGY"));
        StrategyFacet(payable(address(vault))).tend(address(stratA));
    }

    function test_tendAllIsSafeWhenNoStrategyNeedsIt() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        _tendAll();
        assertEq(_totalAssets(), 100_000e6);
    }

    function test_syncCreditsADirectDonation() public {
        _deposit(alice, 100_000e6);
        uint256 ppsBefore = _pps();

        usdc.mint(address(vault), 5_000e6);
        assertEq(_idleBalance(), 100_000e6);

        _sync();

        assertEq(_idleBalance(), 105_000e6);
        assertGt(_pps(), ppsBefore);
    }

    function test_venueLossReducesPricePerShareForEveryone() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        uint256 ppsBefore = _pps();
        venueA.setRate(0.8e18);
        _settle();

        assertLt(_pps(), ppsBefore);
        assertEq(_totalAssets(), 90_000e6);
    }

    function test_withdrawalRoutesAroundAFrozenVenue() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        venueA.setLiquidityCap(0);

        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, 45_000e6);

        assertEq(usdc.balanceOf(alice) - before, 45_000e6);
        assertEq(stratA.positionValue(), 50_000e6);
    }

    function testFuzz_depositThenFullRedeemIsValueNeutral(uint96 amount) public {
        amount = uint96(bound(amount, 1e6, 500_000e6));
        _addTwoStrategies(5_000, 4_000, 1_000);

        uint256 before = usdc.balanceOf(alice);
        uint256 shares = _deposit(alice, amount);
        _deployIdle();
        _redeem(alice, shares);

        assertLe(usdc.balanceOf(alice), before);
        assertApproxEqAbs(usdc.balanceOf(alice), before, 3);
    }

    function testFuzz_multipleDepositorsSharePriceFairly(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1_000e6, 200_000e6));
        b = uint96(bound(b, 1_000e6, 200_000e6));
        _addTwoStrategies(5_000, 4_000, 1_000);

        _deposit(alice, a);
        _deployIdle();
        _deposit(bob, b);
        _deployIdle();

        venueA.accrueBps(100);
        _settle();

        uint256 aliceShares = _shareToken().balanceOf(alice);
        uint256 bobShares = _shareToken().balanceOf(bob);
        assertApproxEqRel(
            (aliceShares * 1e18) / (aliceShares + bobShares), (uint256(a) * 1e18) / (uint256(a) + b), 0.001e18
        );
    }
}
