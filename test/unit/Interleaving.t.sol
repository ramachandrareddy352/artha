// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultFixture} from "../helpers/VaultFixture.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {DepositFacet} from "../../src/facets/DepositFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {RotationStrategy} from "../../src/strategies/common/RotationStrategy.sol";
import {UsdcRotationStrategy} from "../../src/strategies/usdc/rotate/UsdcRotationStrategy.sol";
import {ERC4626WrapperStrategy} from "../../src/strategies/common/ERC4626WrapperStrategy.sol";
import {MockERC20, MockERC4626} from "../mocks/Mocks.sol";

contract InterleavingTest is VaultFixture {
    function setUp() public {
        _setUpFixture(1_000, 9_000);
    }

    function _netValue(address who) internal view returns (uint256) {
        uint256 shares = _shareToken().balanceOf(who);
        if (shares == 0) return 0;
        return ViewFacet(payable(address(vault))).previewRedeem(shares);
    }

    function test_addStrategyWhileUserDeposits() public {
        _addSingleStrategy(address(stratA), 9_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        uint256 aliceValueBefore = _netValue(alice);

        address[] memory all = _strategiesArray(address(stratA), address(stratB));
        _addStrategy(address(stratB), all, _weightsArray(4_500, 4_500), 1_000);
        _deposit(bob, 50_000e6);

        assertApproxEqAbs(_netValue(alice), aliceValueBefore, 2);
        assertApproxEqAbs(_netValue(bob), 50_000e6, 2);
        assertApproxEqAbs(_totalAssets(), 150_000e6, 4);
    }

    function test_removeStrategyWhileUserWithdraws() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deposit(bob, 100_000e6);
        _deployIdle();

        uint256 bobValueBefore = _netValue(bob);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).removeStrategy(address(stratA), 10);

        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, 50_000e6);

        assertEq(usdc.balanceOf(alice) - before, 50_000e6);
        assertApproxEqAbs(_netValue(bob), bobValueBefore, 10);
        assertEq(_strategyList().length, 1);
    }

    function test_migrateStrategyBetweenTwoUserActions() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();
        venueA.accrueBps(300);

        uint256 navBefore = _totalAssets();
        _settle();
        navBefore = _totalAssets();

        MockERC4626 venueC = new MockERC4626(address(usdc));
        ERC4626WrapperStrategy stratC = new ERC4626WrapperStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(venueC)
        );

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).migrateStrategy(address(stratA), address(stratC));

        assertApproxEqAbs(_totalAssets(), navBefore, 10);

        _deposit(bob, 20_000e6);
        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, 10_000e6);

        assertEq(usdc.balanceOf(alice) - before, 10_000e6);
        assertApproxEqAbs(_netValue(bob), 20_000e6, 10);
    }

    function test_reweightWhileUserRedeems() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        uint256 aliceShares = _deposit(alice, 100_000e6);
        _deposit(bob, 100_000e6);
        _deployIdle();

        _setTargets(_strategiesArray(address(stratA), address(stratB)), _weightsArray(1_000, 8_000), 1_000);

        uint256 before = usdc.balanceOf(alice);
        _redeem(alice, aliceShares);

        assertApproxEqAbs(usdc.balanceOf(alice) - before, 100_000e6, 10);
        assertApproxEqAbs(_netValue(bob), 100_000e6, 10);
    }

    function test_disableStrategyThenUserDepositsAndWithdraws() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setStrategyDisabled(address(stratA), true);

        _deposit(bob, 100_000e6);
        _deployIdle();
        assertEq(stratA.positionValue(), 50_000e6);

        uint256 before = usdc.balanceOf(bob);
        _withdraw(bob, 90_000e6);
        assertEq(usdc.balanceOf(bob) - before, 90_000e6);
    }

    function test_raisingIdleTargetThenWithdrawing() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setIdleTargetBps(1_000);

        _setTargets(_strategiesArray(address(stratA), address(stratB)), _weightsArray(4_000, 5_000), 1_000);
        _rebalance();

        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, 20_000e6);
        assertEq(usdc.balanceOf(alice) - before, 20_000e6);
    }

    function test_loweringTvlCapBlocksNewDepositsButNotHolders() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        uint256 aliceShares = _deposit(alice, 100_000e6);
        _deployIdle();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setCaps(100_000e6, 0, 0, 0);

        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("TVL_CAP_EXCEEDED"));
        DepositFacet(payable(address(vault))).deposit(1_000e6, bob, 0);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(alice);
        _redeem(alice, aliceShares);
        assertApproxEqAbs(usdc.balanceOf(alice) - before, 100_000e6, 5);
    }

    function test_guardianPauseCaughtBetweenTwoUserWithdrawals() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        uint256 aliceShares = _deposit(alice, 100_000e6);
        _deployIdle();

        _withdraw(alice, 10_000e6);
        _pause();

        vm.prank(alice);
        vm.expectRevert(bytes("PAUSED"));
        WithdrawFacet(payable(address(vault))).withdraw(10_000e6, alice, alice, type(uint256).max);

        uint256 remaining = _shareToken().balanceOf(alice);
        assertLt(remaining, aliceShares);

        uint256 before = usdc.balanceOf(alice);
        _emergencyWithdraw(alice, remaining);
        assertApproxEqAbs(usdc.balanceOf(alice) - before, 90_000e6, 10);
    }

    function test_rebalanceDoesNotMovePricePerShareForAConcurrentDepositor() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();
        venueA.accrueBps(500);
        _settle();

        uint256 ppsBefore = _pps();
        _rebalance();
        uint256 ppsAfterRebalance = _pps();
        assertApproxEqRel(ppsAfterRebalance, ppsBefore, 0.0001e18);

        uint256 bobShares = _deposit(bob, 50_000e6);
        assertApproxEqRel(ViewFacet(payable(address(vault))).previewRedeem(bobShares), 50_000e6, 0.0001e18);
    }

    function test_userWithdrawsImmediatelyAfterARotationTend() public {
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        oracle.setPrice(address(wbtc), 60_000e8);

        RotationStrategy.Params memory p = RotationStrategy.Params({
            enterQuoteDropBps: 2_000,
            enterReboundBps: 0,
            exitQuoteGainBps: 2_000,
            exitTrailingBps: 0,
            exitStopLossBps: 0,
            cooldown: 1 days,
            maxQuoteHold: 0
        });

        UsdcRotationStrategy rot = new UsdcRotationStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(wbtc), address(0), address(0), p
        );

        _addSingleStrategy(address(rot), 9_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        _tend(address(rot));
        assertEq(uint256(rot.stance()), uint256(RotationStrategy.Stance.HoldBase));

        oracle.setPrice(address(wbtc), 45_000e8);
        _skip(2 days);
        _tend(address(rot));
        assertEq(uint256(rot.stance()), uint256(RotationStrategy.Stance.HoldQuote));

        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, 20_000e6);
        assertEq(usdc.balanceOf(alice) - before, 20_000e6);

        oracle.setPrice(address(wbtc), 60_000e8);
        _skip(2 days);
        _tend(address(rot));
        assertEq(uint256(rot.stance()), uint256(RotationStrategy.Stance.HoldBase));

        assertGt(_totalAssets(), 100_000e6 - 20_000e6);
    }

    function test_execOnStrategyDoesNotMoveNav() public {
        _addSingleStrategy(address(stratAave), 9_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        uint256 navBefore = _totalAssets();
        uint256 ppsBefore = _pps();

        _exec(address(stratAave), abi.encodeCall(stratAave.setMaxSlippageBps, (300)));
        _exec(address(stratAave), abi.encodeCall(stratAave.registerReward, (address(rewardToken), 1e18)));

        assertEq(_totalAssets(), navBefore);
        assertEq(_pps(), ppsBefore);

        _deposit(bob, 10_000e6);
        assertApproxEqAbs(_netValue(bob), 10_000e6, 2);
    }

    function test_donationLiftsEveryHolderOnceSynced() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deposit(bob, 100_000e6);
        _deployIdle();

        uint256 aliceBefore = _netValue(alice);
        usdc.mint(address(vault), 20_000e6);

        assertApproxEqAbs(_netValue(alice), aliceBefore, 2);

        _sync();
        _settle();

        assertApproxEqAbs(_netValue(alice), aliceBefore + 10_000e6, 10);
        assertApproxEqAbs(_netValue(bob), aliceBefore + 10_000e6, 10);
    }

    function test_threeUsersRacingThroughEveryKeeperAndAdminAction() public {
        _addTwoStrategies(5_000, 4_000, 1_000);

        _deposit(alice, 100_000e6);
        _deployIdle();

        _deposit(bob, 50_000e6);
        venueA.accrueBps(200);
        _harvestAll();

        _withdraw(alice, 20_000e6);
        _deposit(carol, 75_000e6);
        _rebalance();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setStrategyDisabled(address(stratB), true);

        _deposit(bob, 25_000e6);
        venueB.accrueBps(150);
        _settle();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setStrategyDisabled(address(stratB), false);

        _setTargets(_strategiesArray(address(stratA), address(stratB)), _weightsArray(6_000, 3_000), 1_000);
        _rebalance();

        _withdraw(carol, 25_000e6);
        _deployIdle();

        uint256 totalUserValue = _netValue(alice) + _netValue(bob) + _netValue(carol);
        assertApproxEqRel(totalUserValue, _totalAssets(), 0.0001e18);

        uint256 aliceShares = _shareToken().balanceOf(alice);
        uint256 bobShares = _shareToken().balanceOf(bob);
        uint256 carolShares = _shareToken().balanceOf(carol);
        assertEq(aliceShares + bobShares + carolShares, _shareToken().totalSupply());

        _redeem(alice, aliceShares);
        _redeem(bob, bobShares);
        _redeem(carol, carolShares);

        assertEq(_shareToken().totalSupply(), 0);
        assertLe(_totalAssets(), 10);
    }

    function testFuzz_interleavedDepositsAndWithdrawalsNeverCreateValue(
        uint96 aliceAmount,
        uint96 bobAmount,
        uint96 yieldBps
    ) public {
        aliceAmount = uint96(bound(aliceAmount, 1_000e6, 200_000e6));
        bobAmount = uint96(bound(bobAmount, 1_000e6, 200_000e6));
        yieldBps = uint96(bound(yieldBps, 0, 500));

        _addTwoStrategies(5_000, 4_000, 1_000);

        _deposit(alice, aliceAmount);
        _deployIdle();
        _deposit(bob, bobAmount);
        _deployIdle();

        venueA.accrueBps(yieldBps);
        _settle();

        uint256 aliceShares = _shareToken().balanceOf(alice);
        uint256 bobShares = _shareToken().balanceOf(bob);

        uint256 aliceOut = _redeem(alice, aliceShares);
        uint256 bobOut = _redeem(bob, bobShares);

        assertLe(aliceOut + bobOut, _idleBalanceBefore(aliceAmount, bobAmount, yieldBps));
    }

    function _idleBalanceBefore(uint96 a, uint96 b, uint96 yieldBps) internal pure returns (uint256) {
        uint256 principal = uint256(a) + uint256(b);
        return principal + (principal * yieldBps) / 10_000 + 10;
    }
}
