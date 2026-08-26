// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultHarness} from "../helpers/VaultHarness.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {ERC4626WrapperStrategy} from "../../src/strategies/common/ERC4626WrapperStrategy.sol";
import {RotationStrategy} from "../../src/strategies/common/RotationStrategy.sol";
import {WbtcRotationStrategy} from "../../src/strategies/wbtc/rotate/WbtcRotationStrategy.sol";
import {MockERC20, MockOracle, MockSwapper, MockERC4626} from "../mocks/Mocks.sol";

interface StrategyFacetLike {
    function deployIdle() external;
}

contract LifecycleTest is VaultHarness {
    MockERC20 internal usdc;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockERC4626 internal venueA;
    MockERC4626 internal venueB;
    MockERC4626 internal venueC;
    ERC4626WrapperStrategy internal sA;
    ERC4626WrapperStrategy internal sB;
    ERC4626WrapperStrategy internal sC;

    address[] internal holders;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);

        _deployVault(address(usdc), 1_000, 5_000);

        venueA = new MockERC4626(address(usdc));
        venueB = new MockERC4626(address(usdc));
        venueC = new MockERC4626(address(usdc));
        sA = _strategyFor(venueA);
        sB = _strategyFor(venueB);
        sC = _strategyFor(venueC);

        usdc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 10_000_000e6);
        usdc.mint(carol, 10_000_000e6);
    }

    function _strategyFor(MockERC4626 v) internal returns (ERC4626WrapperStrategy) {
        return new ERC4626WrapperStrategy(address(vault), address(usdc), address(oracle), address(swapper), address(v));
    }

    function _skip(uint256 d) internal {
        vm.warp(vm.getBlockTimestamp() + d);
    }

    function _claim(address who) internal view returns (uint256) {
        uint256 sh = _shareToken().balanceOf(who);
        return sh == 0 ? 0 : ViewFacet(payable(address(vault))).previewRedeem(sh);
    }

    function _assertSolvent() internal view {
        assertLe(_idleBalance(), usdc.balanceOf(address(vault)));
        uint256 claims = _claim(alice) + _claim(bob) + _claim(carol) + _claim(TREASURY);
        assertLe(claims, _totalAssets() + 4);
    }

    function _addThree() internal {
        _addSingleStrategy(address(sA), 9_000, 1_000);

        address[] memory two = new address[](2);
        two[0] = address(sA);
        two[1] = address(sB);
        uint16[] memory w2 = new uint16[](2);
        w2[0] = 4_500;
        w2[1] = 4_500;
        _addStrategy(address(sB), two, w2, 1_000);

        address[] memory three = new address[](3);
        three[0] = address(sA);
        three[1] = address(sB);
        three[2] = address(sC);
        uint16[] memory w3 = new uint16[](3);
        w3[0] = 3_000;
        w3[1] = 3_000;
        w3[2] = 3_000;
        _addStrategy(address(sC), three, w3, 1_000);
    }

    // ═══════════════════ 1. cradle to grave ═══════════════════

    function test_E2E_cradleToGrave() public {
        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setPerformanceFee(1_000);

        _deposit(alice, 500_000e6);
        _assertSolvent();

        _addThree();
        _deployIdle();
        _assertSolvent();

        for (uint256 month; month < 6; ++month) {
            _skip(30 days);
            venueA.accrueBps(80);
            venueB.accrueBps(60);
            venueC.accrueBps(100);
            _harvestAll();
            _assertSolvent();
        }

        _deposit(bob, 250_000e6);
        _deployIdle();
        _assertSolvent();

        address[] memory three = new address[](3);
        three[0] = address(sA);
        three[1] = address(sB);
        three[2] = address(sC);
        uint16[] memory w = new uint16[](3);
        w[0] = 6_000;
        w[1] = 2_000;
        w[2] = 1_000;
        _setTargets(three, w, 1_000);
        _rebalance();
        _assertSolvent();

        MockERC4626 venueD = new MockERC4626(address(usdc));
        ERC4626WrapperStrategy sD = _strategyFor(venueD);
        vm.prank(GOV);
        AdminFacet(payable(address(vault))).migrateStrategy(address(sC), address(sD));
        _assertSolvent();

        venueA.setRate((venueA.rate() * 3_000) / 10_000);
        _harvestAll();
        _assertSolvent();

        (, bool broken,) = _strategyStatus(address(sA));
        assertTrue(broken);
        assertTrue(ViewFacet(payable(address(vault))).vaultConfig().paused);

        uint256 aliceBefore = usdc.balanceOf(alice);
        _emergencyWithdraw(alice, _shareToken().balanceOf(alice));
        assertGt(usdc.balanceOf(alice) - aliceBefore, 0);
        _assertSolvent();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).removeStrategy(address(sA), type(uint256).max);
        _unpause();
        _assertSolvent();

        uint256 bobBefore = usdc.balanceOf(bob);
        _redeem(bob, _shareToken().balanceOf(bob));
        assertGt(usdc.balanceOf(bob) - bobBefore, 0);
        _assertSolvent();

        assertLe(_claim(alice) + _claim(bob), _totalAssets() + 4);
    }

    // ═══════════════════ 2. bank run ═══════════════════

    function test_E2E_bankRunIsFairToEveryHolder() public {
        _addThree();
        _deposit(alice, 300_000e6);
        _deposit(bob, 300_000e6);
        _deposit(carol, 300_000e6);
        _deployIdle();

        venueA.accrueBps(200);
        venueB.accrueBps(200);
        venueC.accrueBps(200);
        _harvestAll();

        uint256 aliceClaim = _claim(alice);
        uint256 bobClaim = _claim(bob);
        uint256 carolClaim = _claim(carol);
        assertApproxEqRel(aliceClaim, bobClaim, 0.0001e18);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carolBefore = usdc.balanceOf(carol);

        _redeem(alice, _shareToken().balanceOf(alice));
        _redeem(bob, _shareToken().balanceOf(bob));
        _redeem(carol, _shareToken().balanceOf(carol));

        uint256 aliceGot = usdc.balanceOf(alice) - aliceBefore;
        uint256 bobGot = usdc.balanceOf(bob) - bobBefore;
        uint256 carolGot = usdc.balanceOf(carol) - carolBefore;

        assertApproxEqRel(aliceGot, bobGot, 0.0001e18);
        assertApproxEqRel(bobGot, carolGot, 0.0001e18);
        assertApproxEqRel(aliceGot, aliceClaim, 0.0001e18);
    }

    function test_E2E_bankRunAgainstPartiallyIlliquidVenues() public {
        _addThree();
        _deposit(alice, 300_000e6);
        _deposit(bob, 300_000e6);
        _deployIdle();

        venueA.setLiquidityCap(50_000e6);
        venueB.setRevertOnWithdraw(true);

        uint256 available = ViewFacet(payable(address(vault))).availableLiquidity();
        assertGt(available, 0);

        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, available / 2);
        assertEq(usdc.balanceOf(alice) - before, available / 2);
        _assertSolvent();

        assertGt(_claim(bob), 0);
    }

    // ═══════════════════ 3. venue collapse ═══════════════════

    function test_E2E_venueCollapseIsSharedProRataAndTheVaultSurvives() public {
        _addThree();
        _deposit(alice, 300_000e6);
        _deposit(bob, 100_000e6);
        _deployIdle();

        uint256 aliceBefore = _claim(alice);
        uint256 bobBefore = _claim(bob);
        assertApproxEqRel(aliceBefore, bobBefore * 3, 0.001e18);

        // Anchored refreshes only: `settle()` is deliberately unanchored, so it never
        // advances `strategyLastValue` — after the second step every further drop reads
        // as a suspicious jump against the ORIGINAL anchor and NAV snaps back to it.
        // A loss is only ever booked by a refresh that re-anchors.
        for (uint256 i; i < 5; ++i) {
            _skip(1 days);
            venueA.setRate((venueA.rate() * 8_500) / 10_000);
            _harvestAll();
        }

        uint256 aliceAfter = _claim(alice);
        uint256 bobAfter = _claim(bob);

        assertLt(aliceAfter, aliceBefore);
        assertApproxEqRel(aliceAfter, bobAfter * 3, 0.001e18);
        _assertSolvent();
    }

    // ═══════════════════ 4. rotation through a full cycle ═══════════════════

    function test_E2E_rotationCycleGrowsBaseWhileUsersComeAndGo() public {
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        oracle.setPrice(address(wbtc), 60_000e8);

        MockSwapper rotSwapper = new MockSwapper(address(oracle), 20);

        RotationStrategy.Params memory p = RotationStrategy.Params({
            enterQuoteDropBps: 2_000,
            enterReboundBps: 0,
            exitQuoteGainBps: 2_000,
            exitTrailingBps: 0,
            exitStopLossBps: 0,
            cooldown: 1 days,
            maxQuoteHold: 0
        });

        MockERC20 wbtcBase = new MockERC20("Wrapped BTC", "WBTC", 8);
        oracle.setPrice(address(wbtcBase), 60_000e8);
        _deployVault(address(wbtcBase), 1_000, 9_500);

        WbtcRotationStrategy rot = new WbtcRotationStrategy(
            address(vault),
            address(wbtcBase),
            address(oracle),
            address(rotSwapper),
            address(usdc),
            address(0),
            address(0),
            p
        );

        wbtcBase.mint(alice, 100e8);
        wbtcBase.mint(bob, 100e8);

        _addSingleStrategy(address(rot), 9_000, 1_000);
        _deposit(alice, 10e8);
        _deployIdle();
        _tend(address(rot));

        uint256 aliceStartClaim = _claim(alice);

        oracle.setPrice(address(wbtcBase), 78_000e8);
        _skip(2 days);
        _tend(address(rot));
        assertEq(uint256(rot.stance()), uint256(RotationStrategy.Stance.HoldQuote));

        _deposit(bob, 5e8);
        _deployIdle();

        oracle.setPrice(address(wbtcBase), 52_000e8);
        _skip(2 days);
        _tend(address(rot));
        assertEq(uint256(rot.stance()), uint256(RotationStrategy.Stance.HoldBase));

        assertGt(_claim(alice), aliceStartClaim);

        uint256 bobBefore = wbtcBase.balanceOf(bob);
        _redeem(bob, _shareToken().balanceOf(bob));
        assertGt(wbtcBase.balanceOf(bob) - bobBefore, 0);
    }

    // ═══════════════════ 5. governance-driven reconfiguration ═══════════════════

    function test_E2E_everyAdminLeverExercisedWithUsersActingThroughout() public {
        _addThree();
        _deposit(alice, 400_000e6);
        _deployIdle();
        _assertSolvent();

        vm.startPrank(GOV);
        AdminFacet(payable(address(vault))).setCaps(5_000_000e6, 1_000_000e6, 1_000_000e6, 100e6);
        AdminFacet(payable(address(vault))).setIdleTargetBps(500);
        AdminFacet(payable(address(vault))).setStrategyMaxDeltaBps(4_000);
        AdminFacet(payable(address(vault))).setHarvestMaxImpactBps(4_000);
        AdminFacet(payable(address(vault))).setPerformanceFee(1_500);
        vm.stopPrank();

        _deposit(bob, 200_000e6);
        _assertSolvent();

        address[] memory three = new address[](3);
        three[0] = address(sA);
        three[1] = address(sB);
        three[2] = address(sC);
        uint16[] memory w = new uint16[](3);
        w[0] = 4_000;
        w[1] = 3_000;
        w[2] = 2_500;
        _setTargets(three, w, 500);
        _rebalance();
        _assertSolvent();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setStrategyDisabled(address(sB), true);
        _deposit(carol, 150_000e6);
        _deployIdle();
        _assertSolvent();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setStrategyDisabled(address(sB), false);

        venueA.accrueBps(150);
        venueB.accrueBps(150);
        venueC.accrueBps(150);
        _harvestAll();
        _assertSolvent();

        _withdraw(alice, 100_000e6);
        _assertSolvent();

        _pause();
        _emergencyWithdraw(carol, _shareToken().balanceOf(carol) / 2);
        _unpause();
        _assertSolvent();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setKeeper(alice, true);
        assertTrue(ViewFacet(payable(address(vault))).isKeeper(alice));

        vm.prank(alice);
        StrategyFacetLike(payable(address(vault))).deployIdle();
        _assertSolvent();

        uint256 supply = _shareToken().totalSupply();
        assertEq(
            _shareToken().balanceOf(alice) + _shareToken().balanceOf(bob) + _shareToken().balanceOf(carol)
                + _shareToken().balanceOf(TREASURY),
            supply
        );
    }

    // ═══════════════════ 6. two vaults never touch each other ═══════════════════

    function test_E2E_twoVaultsSharingFacetsStayIsolated() public {
        _addThree();
        _deposit(alice, 200_000e6);
        _deployIdle();

        address firstVault = address(vault);
        uint256 firstNav = _totalAssets();
        address firstShare = address(_shareToken());

        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        oracle.setPrice(address(dai), 1e8);
        _deployVault(address(dai), 1_000, 5_000);

        MockERC4626 daiVenue = new MockERC4626(address(dai));
        ERC4626WrapperStrategy daiStrat = new ERC4626WrapperStrategy(
            address(vault), address(dai), address(oracle), address(swapper), address(daiVenue)
        );

        dai.mint(bob, 1_000e18);
        _addSingleStrategy(address(daiStrat), 9_000, 1_000);
        _deposit(bob, 500e18);
        _deployIdle();

        assertTrue(address(vault) != firstVault);
        assertTrue(address(_shareToken()) != firstShare);
        assertEq(_totalAssets(), 500e18);

        assertEq(ViewFacet(payable(firstVault)).totalAssets(), firstNav);
        assertEq(ViewFacet(payable(firstVault)).vaultConfig().baseAsset, address(usdc));
        assertEq(ViewFacet(payable(address(vault))).vaultConfig().baseAsset, address(dai));

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(dai.balanceOf(firstVault), 0);
    }

    // ═══════════════════ 7. a full year of ordinary operation ═══════════════════

    function test_E2E_aYearOfOrdinaryOperationNeverLosesValue() public {
        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setPerformanceFee(1_000);

        _addThree();
        _deposit(alice, 500_000e6);
        _deposit(bob, 300_000e6);
        _deployIdle();

        uint256 principal = 800_000e6;

        for (uint256 week; week < 52; ++week) {
            _skip(7 days);
            venueA.accrueBps(15);
            venueB.accrueBps(12);
            venueC.accrueBps(18);

            if (week % 4 == 0) _harvestAll();
            if (week % 13 == 0) _rebalance();
            if (week % 7 == 0) _deposit(carol, 10_000e6);
            if (week % 11 == 0 && _claim(alice) > 20_000e6) _withdraw(alice, 20_000e6);

            _assertSolvent();
        }

        assertGt(_totalAssets(), principal);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 carolBefore = usdc.balanceOf(carol);

        _redeem(alice, _shareToken().balanceOf(alice));
        _redeem(bob, _shareToken().balanceOf(bob));
        _redeem(carol, _shareToken().balanceOf(carol));

        assertGt(usdc.balanceOf(bob) - bobBefore, 300_000e6);
        assertGt(usdc.balanceOf(alice) - aliceBefore, 0);
        assertGt(usdc.balanceOf(carol) - carolBefore, 0);

        assertLe(_totalAssets(), _claim(TREASURY) + 10e6);
    }
}
