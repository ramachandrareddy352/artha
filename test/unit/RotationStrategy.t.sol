// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RotationStrategy} from "../../src/strategies/common/RotationStrategy.sol";
import {WbtcRotationStrategy} from "../../src/strategies/wbtc/rotate/WbtcRotationStrategy.sol";
import {MockERC20, MockOracle, MockSwapper, MockERC4626} from "../mocks/Mocks.sol";

contract RotationStrategyTest is Test {
    MockERC20 internal wbtc;
    MockERC20 internal usdc;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockERC4626 internal wbtcPark;
    MockERC4626 internal usdcPark;

    WbtcRotationStrategy internal strat;

    address internal vaultAddr = address(0xAA17);

    uint256 internal constant BTC_START = 60_000e8;
    uint256 internal constant ONE_BTC = 1e8;

    function setUp() public {
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 30);
        wbtcPark = new MockERC4626(address(wbtc));
        usdcPark = new MockERC4626(address(usdc));

        oracle.setPrice(address(wbtc), BTC_START);
        oracle.setPrice(address(usdc), 1e8);

        strat = _deploy(address(0), address(0));
    }

    function _params() internal pure returns (RotationStrategy.Params memory p) {
        p = RotationStrategy.Params({
            enterQuoteDropBps: 2_000,
            enterReboundBps: 0,
            exitQuoteGainBps: 2_000,
            exitTrailingBps: 0,
            exitStopLossBps: 0,
            cooldown: 1 days,
            maxQuoteHold: 0
        });
    }

    function _deploy(address basePark, address quotePark) internal returns (WbtcRotationStrategy s) {
        s = new WbtcRotationStrategy(
            vaultAddr, address(wbtc), address(oracle), address(swapper), address(usdc), basePark, quotePark, _params()
        );
        wbtc.mint(vaultAddr, 100 * ONE_BTC);
        vm.prank(vaultAddr);
        wbtc.approve(address(s), type(uint256).max);
    }

    function _invest(WbtcRotationStrategy s, uint256 amount) internal {
        vm.prank(vaultAddr);
        s.invest(amount);
    }

    function _tend(WbtcRotationStrategy s) internal {
        vm.prank(vaultAddr);
        s.tend();
    }

    function _setBtc(uint256 price8dp) internal {
        oracle.setPrice(address(wbtc), price8dp);
    }

    function _skip(uint256 delta) internal {
        vm.warp(vm.getBlockTimestamp() + delta);
    }

    function test_startsHoldingBase() public view {
        assertEq(uint256(strat.stance()), uint256(RotationStrategy.Stance.HoldBase));
        assertTrue(strat.rotationEnabled());
    }

    function test_investHoldsBaseAndValuesIt() public {
        _invest(strat, ONE_BTC);
        assertEq(wbtc.balanceOf(address(strat)), ONE_BTC);
        assertEq(strat.positionValue(), ONE_BTC);
        assertEq(strat.baseLegAssets(), ONE_BTC);
        assertEq(strat.quoteLegAssets(), 0);
    }

    function test_firstTendSeedsReferenceWithoutRotating() public {
        _invest(strat, ONE_BTC);
        _tend(strat);

        assertEq(uint256(strat.stance()), uint256(RotationStrategy.Stance.HoldBase));
        assertGt(strat.quoteExitPrice(), 0);
        assertEq(strat.rotations(), 0);
    }

    function test_priceIsQuoteDenominatedInBase() public view {
        uint256 p = strat.price();
        assertEq(p, (1e8 * 1e18) / BTC_START);
    }

    function test_doesNotRotateBelowBand() public {
        _invest(strat, ONE_BTC);
        _tend(strat);

        _setBtc(69_000e8);
        _skip(2 days);
        _tend(strat);

        assertEq(uint256(strat.stance()), uint256(RotationStrategy.Stance.HoldBase));
        assertEq(strat.rotations(), 0);
    }

    function test_takesProfitIntoStablesWhenBtcRallies() public {
        _invest(strat, ONE_BTC);
        _tend(strat);

        _setBtc(80_000e8);
        _skip(2 days);
        _tend(strat);

        assertEq(uint256(strat.stance()), uint256(RotationStrategy.Stance.HoldQuote));
        assertEq(strat.rotations(), 1);
        assertEq(wbtc.balanceOf(address(strat)), 0);
        assertApproxEqRel(strat.quoteLegAssets(), 80_000e6, 0.01e18);
    }

    function test_buysBackMoreBtcAfterDrawdown() public {
        _invest(strat, ONE_BTC);
        _tend(strat);

        _setBtc(80_000e8);
        _skip(2 days);
        _tend(strat);

        _setBtc(50_000e8);
        _skip(2 days);
        _tend(strat);

        assertEq(uint256(strat.stance()), uint256(RotationStrategy.Stance.HoldBase));
        assertEq(strat.rotations(), 2);
        assertGt(wbtc.balanceOf(address(strat)), ONE_BTC);
    }

    function test_roundTripBeatsHoldingByTheExpectedMargin() public {
        _invest(strat, ONE_BTC);
        _tend(strat);

        _setBtc(80_000e8);
        _skip(2 days);
        _tend(strat);

        _setBtc(50_000e8);
        _skip(2 days);
        _tend(strat);

        uint256 expected = (ONE_BTC * 80_000) / 50_000;
        uint256 afterFees = (expected * 9_970 * 9_970) / (10_000 * 10_000);
        assertApproxEqRel(wbtc.balanceOf(address(strat)), afterFees, 0.001e18);
    }

    function test_cooldownBlocksImmediateSecondRotation() public {
        _invest(strat, ONE_BTC);
        _tend(strat);

        _setBtc(80_000e8);
        _skip(2 days);
        _tend(strat);
        assertEq(strat.rotations(), 1);

        _setBtc(50_000e8);
        _tend(strat);
        assertEq(strat.rotations(), 1);
        assertEq(uint256(strat.stance()), uint256(RotationStrategy.Stance.HoldQuote));

        _skip(1 days);
        _tend(strat);
        assertEq(strat.rotations(), 2);
    }

    function test_reboundConfirmationBlocksEntryUntilTroughIsLeft() public {
        RotationStrategy.Params memory p = _params();
        p.enterReboundBps = 300;
        WbtcRotationStrategy s = _deploy(address(0), address(0));
        vm.prank(vaultAddr);
        s.setParams(p);

        _invest(s, ONE_BTC);
        _tend(s);

        _setBtc(90_000e8);
        _skip(2 days);
        _tend(s);
        assertEq(uint256(s.stance()), uint256(RotationStrategy.Stance.HoldBase));

        _setBtc(85_000e8);
        _tend(s);
        assertEq(uint256(s.stance()), uint256(RotationStrategy.Stance.HoldQuote));
    }

    function test_trailingStopBanksAPartialRoundTrip() public {
        RotationStrategy.Params memory p = _params();
        p.exitQuoteGainBps = 5_000;
        p.exitTrailingBps = 500;
        WbtcRotationStrategy s = _deploy(address(0), address(0));
        vm.prank(vaultAddr);
        s.setParams(p);

        _invest(s, ONE_BTC);
        _tend(s);
        _setBtc(80_000e8);
        _skip(2 days);
        _tend(s);
        assertEq(uint256(s.stance()), uint256(RotationStrategy.Stance.HoldQuote));

        _setBtc(60_000e8);
        _skip(2 days);
        _tend(s);
        assertEq(uint256(s.stance()), uint256(RotationStrategy.Stance.HoldQuote));

        _setBtc(64_000e8);
        _skip(2 days);
        _tend(s);
        assertEq(uint256(s.stance()), uint256(RotationStrategy.Stance.HoldBase));
        assertGt(wbtc.balanceOf(address(s)), ONE_BTC);
    }

    function test_stopLossReturnsToBaseWhenTrendKeepsRunning() public {
        RotationStrategy.Params memory p = _params();
        p.exitStopLossBps = 1_500;
        WbtcRotationStrategy s = _deploy(address(0), address(0));
        vm.prank(vaultAddr);
        s.setParams(p);

        _invest(s, ONE_BTC);
        _tend(s);
        _setBtc(80_000e8);
        _skip(2 days);
        _tend(s);

        _setBtc(100_000e8);
        _skip(2 days);
        _tend(s);

        assertEq(uint256(s.stance()), uint256(RotationStrategy.Stance.HoldBase));
        assertLt(wbtc.balanceOf(address(s)), ONE_BTC);
        assertGt(wbtc.balanceOf(address(s)), (ONE_BTC * 75) / 100);
    }

    function test_maxQuoteHoldForcesReturnAfterWaiting() public {
        RotationStrategy.Params memory p = _params();
        p.maxQuoteHold = 30 days;
        WbtcRotationStrategy s = _deploy(address(0), address(0));
        vm.prank(vaultAddr);
        s.setParams(p);

        _invest(s, ONE_BTC);
        _tend(s);
        _setBtc(80_000e8);
        _skip(2 days);
        _tend(s);
        assertEq(uint256(s.stance()), uint256(RotationStrategy.Stance.HoldQuote));

        _skip(31 days);
        _tend(s);
        assertEq(uint256(s.stance()), uint256(RotationStrategy.Stance.HoldBase));
    }

    function test_positionValueRisesInBaseTermsWhenHoldingQuoteAndBtcFalls() public {
        _invest(strat, ONE_BTC);
        _tend(strat);
        _setBtc(80_000e8);
        _skip(2 days);
        _tend(strat);

        uint256 valueAtExit = strat.positionValue();
        _setBtc(40_000e8);
        uint256 valueAfterCrash = strat.positionValue();

        assertApproxEqRel(valueAfterCrash, valueAtExit * 2, 0.01e18);
    }

    function test_investWhileHoldingQuoteJoinsTheQuoteLeg() public {
        _invest(strat, ONE_BTC);
        _tend(strat);
        _setBtc(80_000e8);
        _skip(2 days);
        _tend(strat);

        _invest(strat, ONE_BTC);

        assertEq(wbtc.balanceOf(address(strat)), 0);
        assertApproxEqRel(strat.quoteLegAssets(), 160_000e6, 0.01e18);
    }

    function test_divestWhileHoldingQuoteSellsEnoughQuote() public {
        _invest(strat, 2 * ONE_BTC);
        _tend(strat);
        _setBtc(80_000e8);
        _skip(2 days);
        _tend(strat);

        uint256 vaultBefore = wbtc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(ONE_BTC);

        assertEq(withdrawn, ONE_BTC);
        assertEq(wbtc.balanceOf(vaultAddr) - vaultBefore, ONE_BTC);
        assertGt(strat.quoteLegAssets(), 0);
    }

    function test_divestWhileHoldingBaseNeedsNoSwap() public {
        _invest(strat, 2 * ONE_BTC);
        swapper.setBroken(true);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(ONE_BTC);

        assertEq(withdrawn, ONE_BTC);
    }

    function test_emergencyWithdrawUnwindsBothLegs() public {
        _invest(strat, ONE_BTC);
        _tend(strat);
        _setBtc(80_000e8);
        _skip(2 days);
        _tend(strat);

        uint256 vaultBefore = wbtc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();

        assertGt(withdrawn, 0);
        assertEq(wbtc.balanceOf(vaultAddr) - vaultBefore, withdrawn);
        assertEq(strat.quoteLegAssets(), 0);
    }

    function test_emergencyWithdrawIsPartialWhenSwapVenueIsDead() public {
        _invest(strat, ONE_BTC);
        _tend(strat);
        _setBtc(80_000e8);
        _skip(2 days);
        _tend(strat);

        swapper.setBroken(true);
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();

        assertEq(withdrawn, 0);
        assertGt(strat.quoteLegAssets(), 0);
        assertGt(strat.positionValue(), 0);
    }

    function test_rotationDisabledFreezesTheStance() public {
        _invest(strat, ONE_BTC);
        _tend(strat);

        vm.prank(vaultAddr);
        strat.setRotationEnabled(false);

        _setBtc(80_000e8);
        _skip(2 days);
        _tend(strat);

        assertEq(uint256(strat.stance()), uint256(RotationStrategy.Stance.HoldBase));
    }

    function test_forceStanceBypassesBandsAndCooldown() public {
        _invest(strat, ONE_BTC);

        vm.prank(vaultAddr);
        strat.forceStance(RotationStrategy.Stance.HoldQuote);

        assertEq(uint256(strat.stance()), uint256(RotationStrategy.Stance.HoldQuote));
        assertGt(strat.quoteLegAssets(), 0);
    }

    function test_previewTendReportsThePendingAction() public {
        _invest(strat, ONE_BTC);
        _tend(strat);

        (bool act,,) = strat.previewTend();
        assertFalse(act);

        _setBtc(80_000e8);
        _skip(2 days);
        (bool act2, RotationStrategy.Stance target,) = strat.previewTend();
        assertTrue(act2);
        assertEq(uint256(target), uint256(RotationStrategy.Stance.HoldQuote));
    }

    function test_parkedLegsEarnYieldWhileWaiting() public {
        WbtcRotationStrategy s = _deploy(address(wbtcPark), address(usdcPark));
        _invest(s, ONE_BTC);

        assertEq(wbtc.balanceOf(address(s)), 0);
        assertEq(s.baseLegAssets(), ONE_BTC);

        wbtcPark.accrueBps(500);
        assertApproxEqRel(s.baseLegAssets(), (ONE_BTC * 105) / 100, 0.001e18);
    }

    function test_parkedQuoteLegUnwindsOnRotation() public {
        WbtcRotationStrategy s = _deploy(address(wbtcPark), address(usdcPark));
        _invest(s, ONE_BTC);
        _tend(s);

        _setBtc(80_000e8);
        _skip(2 days);
        _tend(s);

        assertEq(uint256(s.stance()), uint256(RotationStrategy.Stance.HoldQuote));
        assertGt(usdcPark.balanceOf(address(s)), 0);

        usdcPark.accrueBps(200);
        _setBtc(50_000e8);
        _skip(2 days);
        _tend(s);

        assertEq(usdcPark.balanceOf(address(s)), 0);
        assertGt(wbtcPark.balanceOf(address(s)), 0);
    }

    function test_divestFromParkedBaseLeg() public {
        WbtcRotationStrategy s = _deploy(address(wbtcPark), address(usdcPark));
        _invest(s, 2 * ONE_BTC);

        vm.prank(vaultAddr);
        uint256 withdrawn = s.divest(ONE_BTC);

        assertEq(withdrawn, ONE_BTC);
        assertApproxEqAbs(s.baseLegAssets(), ONE_BTC, 1);
    }

    function test_slippageFloorRejectsABadFill() public {
        _invest(strat, ONE_BTC);
        _tend(strat);
        swapper.setFeeBps(300);

        _setBtc(80_000e8);
        _skip(2 days);
        vm.prank(vaultAddr);
        vm.expectRevert(bytes("MIN_OUT"));
        strat.tend();
    }

    function test_widerSlippageToleranceAcceptsTheSameFill() public {
        _invest(strat, ONE_BTC);
        _tend(strat);
        swapper.setFeeBps(300);
        vm.prank(vaultAddr);
        strat.setMaxSlippageBps(400);

        _setBtc(80_000e8);
        _skip(2 days);
        _tend(strat);

        assertEq(uint256(strat.stance()), uint256(RotationStrategy.Stance.HoldQuote));
    }

    function test_priceRevertsWhenOracleIsDown() public {
        oracle.setReverting(address(wbtc), true);
        vm.expectRevert(bytes("ORACLE_DOWN"));
        strat.price();
    }

    function test_paramsMustHaveSaneBands() public {
        RotationStrategy.Params memory p = _params();
        p.cooldown = 10 minutes;
        vm.prank(vaultAddr);
        vm.expectRevert(bytes("COOLDOWN_TOO_SHORT"));
        strat.setParams(p);

        p = _params();
        p.enterQuoteDropBps = 10_000;
        vm.prank(vaultAddr);
        vm.expectRevert(bytes("BAND_TOO_WIDE"));
        strat.setParams(p);
    }

    function test_quoteCannotBeTheBaseAsset() public {
        vm.expectRevert(bytes("BAD_QUOTE"));
        new WbtcRotationStrategy(
            vaultAddr,
            address(wbtc),
            address(oracle),
            address(swapper),
            address(wbtc),
            address(0),
            address(0),
            _params()
        );
    }

    function test_parkMustMatchItsLegAsset() public {
        vm.expectRevert(bytes("QUOTE_PARK_MISMATCH"));
        new WbtcRotationStrategy(
            vaultAddr,
            address(wbtc),
            address(oracle),
            address(swapper),
            address(usdc),
            address(0),
            address(wbtcPark),
            _params()
        );
    }

    function test_sellQuoteLegIsSelfOnly() public {
        vm.expectRevert(bytes("ONLY_SELF"));
        strat.sellQuoteLeg(1);
    }

    function test_rescueProtectsBothLegsAndParks() public {
        WbtcRotationStrategy s = _deploy(address(wbtcPark), address(usdcPark));

        vm.prank(vaultAddr);
        vm.expectRevert(bytes("PROTECTED_TOKEN"));
        s.rescue(address(wbtc));

        vm.prank(vaultAddr);
        vm.expectRevert(bytes("PROTECTED_TOKEN"));
        s.rescue(address(usdc));

        vm.prank(vaultAddr);
        vm.expectRevert(bytes("PROTECTED_TOKEN"));
        s.rescue(address(usdcPark));
    }

    function testFuzz_stanceOnlyChangesAtABand(uint256 btcPrice) public {
        btcPrice = bound(btcPrice, 10_000e8, 500_000e8);
        _invest(strat, ONE_BTC);
        _tend(strat);

        uint256 refPrice = strat.quoteExitPrice();
        _setBtc(btcPrice);
        _skip(2 days);

        uint256 p = strat.price();
        bool shouldRotate = p <= (refPrice * 8_000) / 10_000;

        _tend(strat);
        bool rotated = uint256(strat.stance()) == uint256(RotationStrategy.Stance.HoldQuote);
        assertEq(rotated, shouldRotate);
    }

    function testFuzz_roundTripNeverLosesBaseWhenBandsAreMet(uint256 rallyBps, uint256 dropBps) public {
        rallyBps = bound(rallyBps, 2_600, 20_000);
        dropBps = bound(dropBps, 2_100, 7_000);

        _invest(strat, ONE_BTC);
        _tend(strat);

        _setBtc((BTC_START * (10_000 + rallyBps)) / 10_000);
        _skip(2 days);
        _tend(strat);
        assertEq(uint256(strat.stance()), uint256(RotationStrategy.Stance.HoldQuote));

        uint256 peak = oracle.getPrice(address(wbtc));
        _setBtc((peak * (10_000 - dropBps)) / 10_000);
        _skip(2 days);
        _tend(strat);
        assertEq(uint256(strat.stance()), uint256(RotationStrategy.Stance.HoldBase));

        assertGt(wbtc.balanceOf(address(strat)), ONE_BTC);
    }
}
