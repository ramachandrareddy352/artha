// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultHarness} from "../helpers/VaultHarness.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {DepositFacet} from "../../src/facets/DepositFacet.sol";
import {StrategyFacet} from "../../src/facets/StrategyFacet.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {PriceFeed} from "../../src/oracle/PriceFeed.sol";
import {HoldStrategy} from "../../src/strategies/common/HoldStrategy.sol";
import {RotationStrategy} from "../../src/strategies/common/RotationStrategy.sol";
import {UsdcRotationStrategy} from "../../src/strategies/usdc/rotate/UsdcRotationStrategy.sol";
import {MockERC20, MockOracle, MockSwapper} from "../mocks/Mocks.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

contract OracleGuardTest is VaultHarness {
    MockERC20 internal usdc;
    PriceFeed internal feed;
    MockAggregator internal agg;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        feed = new PriceFeed(address(this), address(0xdead));
        agg = new MockAggregator(1e8);
        feed.setChainlinkConfig(address(usdc), address(agg), 1 hours);
        vm.warp(10 days);
    }

    function test_O1_stalePriceIsRefused() public {
        assertEq(feed.getPrice(address(usdc)), 1e8);

        agg.setStaleBy(2 hours);
        vm.expectRevert(bytes("STALE_PRICE"));
        feed.getPrice(address(usdc));
    }

    function test_O1_priceAtExactlyTheStalenessBoundIsAccepted() public {
        agg.setStaleBy(1 hours);
        assertEq(feed.getPrice(address(usdc)), 1e8);

        agg.setStaleBy(1 hours + 1);
        vm.expectRevert(bytes("STALE_PRICE"));
        feed.getPrice(address(usdc));
    }

    function test_O2_zeroPriceIsRefused() public {
        agg.setAnswer(0);
        vm.expectRevert(bytes("INVALID_PRICE"));
        feed.getPrice(address(usdc));
    }

    function test_O2_negativePriceIsRefused() public {
        agg.setAnswer(-1e8);
        vm.expectRevert(bytes("INVALID_PRICE"));
        feed.getPrice(address(usdc));
    }

    function test_O2_incompleteRoundIsRefused() public {
        agg.setZeroUpdatedAt(true);
        vm.expectRevert(bytes("ROUND_INCOMPLETE"));
        feed.getPrice(address(usdc));
    }

    function test_O2_unstartedRoundIsRefused() public {
        agg.setZeroStartedAt(true);
        vm.expectRevert(bytes("ROUND_NOT_STARTED"));
        feed.getPrice(address(usdc));
    }

    function test_O2_futureDatedAnswerIsRefused() public {
        agg.setFutureTimestamp(true);
        vm.expectRevert(bytes("FUTURE_TIMESTAMP"));
        feed.getPrice(address(usdc));
    }

    function test_O2_answerFromAStaleRoundIsRefused() public {
        agg.setAnsweredInRoundBehind(true);
        vm.expectRevert(bytes("STALE_ROUND"));
        feed.getPrice(address(usdc));
    }

    function test_O3_unconfiguredTokenRevertsRatherThanReturningZero() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.expectRevert(bytes("NOT_CONFIGURED"));
        feed.getPrice(address(other));
    }

    function test_O3_deletedConfigRevertsImmediately() public {
        feed.deleteChainlinkConfig(address(usdc));
        vm.expectRevert(bytes("NOT_CONFIGURED"));
        feed.getPrice(address(usdc));
    }

    function test_O1_stalenessFloorIsEnforcedOnConfiguration() public {
        vm.expectRevert(bytes("INVALID_MAX_AGE"));
        feed.setChainlinkConfig(address(usdc), address(agg), 599);

        feed.setChainlinkConfig(address(usdc), address(agg), 600);
    }

    function test_A1_onlyTheOracleAdminMayReconfigure() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NOT_ORACLE_ADMIN"));
        feed.setChainlinkConfig(address(usdc), address(agg), 1 hours);
    }

    function test_O6_swappingTheFeedTakesEffectImmediatelyWithNoStaleCache() public {
        assertEq(feed.getPrice(address(usdc)), 1e8);

        MockAggregator replacement = new MockAggregator(2e8);
        feed.setChainlinkConfig(address(usdc), address(replacement), 1 hours);

        assertEq(feed.getPrice(address(usdc)), 2e8);
    }
}

contract OracleManipulationTest is VaultHarness {
    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    HoldStrategy internal hold;

    uint256 internal constant BTC = 60_000e8;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(wbtc), BTC);

        _deployVault(address(usdc), 1_000, 2_000);

        hold = new HoldStrategy(address(vault), address(usdc), address(oracle), address(swapper), address(wbtc));

        usdc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 10_000_000e6);
    }

    function _seed(uint256 amount) internal {
        _addSingleStrategy(address(hold), 9_000, 1_000);
        _deposit(alice, amount);
        _deployIdle();
    }

    function test_N1_inflatedOraclePriceTripsTheBreakerBeforeAnyoneRedeems() public {
        _seed(100_000e6);
        uint256 claimBefore = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));

        oracle.setPrice(address(wbtc), BTC * 100);
        _harvestAll();

        (, bool broken,) = _strategyStatus(address(hold));
        assertTrue(broken);

        uint256 claimAfter = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));
        assertApproxEqAbs(claimAfter, claimBefore, 2);
    }

    function test_N1_collapsedOraclePriceTripsTheBreakerRatherThanRacingHoldersOut() public {
        _seed(100_000e6);

        oracle.setPrice(address(wbtc), BTC / 100);
        _harvestAll();

        (, bool broken,) = _strategyStatus(address(hold));
        assertTrue(broken);
        assertTrue(ViewFacet(payable(address(vault))).vaultConfig().paused);
    }

    function test_N1_attackerCannotMintSharesAgainstAnInflatedPrice() public {
        _seed(100_000e6);

        oracle.setPrice(address(wbtc), BTC * 50);

        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("PAUSED"));
        DepositFacet(payable(address(vault))).deposit(10_000e6, bob, 0);
        vm.stopPrank();
    }

    function test_N1_attackerCannotRedeemAgainstAnInflatedPrice() public {
        _seed(100_000e6);
        uint256 aliceShares = _shareToken().balanceOf(alice);

        oracle.setPrice(address(wbtc), BTC * 50);

        vm.prank(alice);
        vm.expectRevert(bytes("PAUSED"));
        WithdrawFacet(payable(address(vault))).redeem(aliceShares, alice, alice, 0);
    }

    function test_O4_deadOracleBreaksTheStrategyInsteadOfMispricing() public {
        _seed(100_000e6);

        oracle.setReverting(address(wbtc), true);
        _harvestAll();

        (, bool broken,) = _strategyStatus(address(hold));
        assertTrue(broken);
        assertTrue(ViewFacet(payable(address(vault))).vaultConfig().paused);
    }

    function test_O4_holdersStillRecoverWhenTheOracleIsDead() public {
        _seed(100_000e6);

        oracle.setReverting(address(wbtc), true);
        _harvestAll();

        uint256 before = usdc.balanceOf(alice);
        _emergencyWithdraw(alice, _shareToken().balanceOf(alice));

        assertGe(usdc.balanceOf(alice) - before, 10_000e6);
    }

    function test_O5_aFillBelowTheOracleFloorIsRefusedAndTheWithdrawalFailsClosed() public {
        _seed(100_000e6);
        uint256 heldBefore = wbtc.balanceOf(address(vault));
        uint256 sharesBefore = _shareToken().balanceOf(alice);

        swapper.setFeeBps(400);
        vm.prank(alice);
        vm.expectRevert(bytes("INSUFFICIENT_LIQUIDITY"));
        WithdrawFacet(payable(address(vault))).withdraw(50_000e6, alice, alice, type(uint256).max);

        assertEq(wbtc.balanceOf(address(vault)), heldBefore);
        assertEq(_shareToken().balanceOf(alice), sharesBefore);
    }

    function test_N3_subThresholdPriceDriftIsBoundedByTheBreakerBand() public {
        _seed(100_000e6);
        uint256 claimBefore = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));

        oracle.setPrice(address(wbtc), (BTC * 11_500) / 10_000);
        _settle();

        (, bool broken,) = _strategyStatus(address(hold));
        assertFalse(broken);

        uint256 claimAfter = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));
        uint256 gain = claimAfter - claimBefore;

        assertLe(gain, (claimBefore * 2_000) / 10_000);
    }

    function testFuzz_N1_anyPriceMoveBeyondTheBandIsRefused(uint256 multiplierBps) public {
        multiplierBps = bound(multiplierBps, 12_100, 1_000_000);
        _seed(100_000e6);

        oracle.setPrice(address(wbtc), (BTC * multiplierBps) / 10_000);
        _harvestAll();

        (, bool broken,) = _strategyStatus(address(hold));
        assertTrue(broken);
    }
}

contract RotationOracleAttackTest is VaultHarness {
    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    UsdcRotationStrategy internal rot;

    uint256 internal constant BTC = 60_000e8;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 30);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(wbtc), BTC);

        _deployVault(address(usdc), 1_000, 9_000);

        RotationStrategy.Params memory p = RotationStrategy.Params({
            enterQuoteDropBps: 2_000,
            enterReboundBps: 0,
            exitQuoteGainBps: 2_000,
            exitTrailingBps: 0,
            exitStopLossBps: 0,
            cooldown: 1 days,
            maxQuoteHold: 0
        });

        rot = new UsdcRotationStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(wbtc), address(0), address(0), p
        );

        usdc.mint(alice, 10_000_000e6);
        _addSingleStrategy(address(rot), 9_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();
    }

    function _skipTime(uint256 d) internal {
        vm.warp(vm.getBlockTimestamp() + d);
    }

    function test_T6_cooldownBoundsHowOftenAPriceMoveCanForceARotation() public {
        _tend(address(rot));

        oracle.setPrice(address(wbtc), (BTC * 7_500) / 10_000);
        _skipTime(2 days);
        _tend(address(rot));
        assertEq(uint256(rot.stance()), uint256(RotationStrategy.Stance.HoldQuote));

        oracle.setPrice(address(wbtc), BTC);
        _tend(address(rot));
        assertEq(uint256(rot.stance()), uint256(RotationStrategy.Stance.HoldQuote));
    }

    function test_T6_repeatedForcedRotationsBleedNoMoreThanTheSlippageBound() public {
        _tend(address(rot));
        uint256 valueBefore = rot.positionValue();

        for (uint256 i; i < 5; ++i) {
            oracle.setPrice(address(wbtc), (BTC * 7_000) / 10_000);
            _skipTime(2 days);
            _tend(address(rot));

            oracle.setPrice(address(wbtc), BTC);
            _skipTime(2 days);
            _tend(address(rot));
        }

        uint256 valueAfter = rot.positionValue();
        uint256 maxBleed = (valueBefore * 10 * 30) / 10_000;
        assertGe(valueAfter + maxBleed, valueBefore);
    }

    function test_O5_rotationRefusesToSwapWhenTheVenueCannotClearTheOracleFloor() public {
        _tend(address(rot));
        swapper.setFeeBps(400);

        uint256 valueBefore = rot.positionValue();
        oracle.setPrice(address(wbtc), (BTC * 7_000) / 10_000);
        _skipTime(2 days);

        vm.prank(KEEPER);
        vm.expectRevert(bytes("TEND_FAILED"));
        StrategyFacet(payable(address(vault))).tend(address(rot));

        assertEq(uint256(rot.stance()), uint256(RotationStrategy.Stance.HoldBase));
        assertEq(rot.positionValue(), valueBefore);
        assertEq(rot.rotations(), 0);
    }

    function test_O4_rotationRefusesToActWhenTheOracleIsDead() public {
        _tend(address(rot));
        oracle.setReverting(address(wbtc), true);

        vm.prank(KEEPER);
        vm.expectRevert();
        StrategyFacet(payable(address(vault))).tend(address(rot));

        assertEq(uint256(rot.stance()), uint256(RotationStrategy.Stance.HoldBase));
    }

    function test_T5_onlyTheKeeperCanTriggerARotation() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NOT_KEEPER"));
        StrategyFacet(payable(address(vault))).tend(address(rot));
    }
}
