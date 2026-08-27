// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {LpBoosterStrategy} from "../../src/strategies/common/LpBoosterStrategy.sol";
import {ConvexLpStrategy} from "../../src/strategies/lp/boost/ConvexLpStrategy.sol";
import {PendlePtStrategy} from "../../src/strategies/common/PendlePtStrategy.sol";
import {CurveConvexStrategy} from "../../src/strategies/common/CurveConvexStrategy.sol";
import {MockERC20, MockOracle, MockSwapper} from "../mocks/Mocks.sol";
import {MockCurvePool, MockConvexBooster, MockConvexRewards} from "../mocks/MockVenues.sol";

contract MockPendleOracle {
    uint256 public rate = 0.95e18;
    bool public broken;

    function setRate(uint256 r) external {
        rate = r;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function getPtToAssetRate(address, uint32) external view returns (uint256) {
        require(!broken, "NO_TWAP");
        return rate;
    }
}

contract MockPt is MockERC20 {
    bool public expired;

    constructor() MockERC20("Principal Token", "PT", 18) {}

    function setExpired(bool e) external {
        expired = e;
    }

    function isExpired() external view returns (bool) {
        return expired;
    }

    function expiry() external pure returns (uint256) {
        return 1 days;
    }
}

contract LpBoosterStrategyTest is Test {
    MockERC20 internal lp;
    MockERC20 internal crv;
    MockERC20 internal cvx;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockConvexRewards internal rewards;
    MockConvexBooster internal booster;
    ConvexLpStrategy internal strat;

    address internal vaultAddr = address(0xAA17);

    function setUp() public {
        lp = new MockERC20("Curve LP", "3CRV", 18);
        crv = new MockERC20("Curve", "CRV", 18);
        cvx = new MockERC20("Convex", "CVX", 18);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);

        oracle.setPrice(address(lp), 1e8);
        oracle.setPrice(address(crv), 50e8);
        oracle.setPrice(address(cvx), 30e8);

        rewards = new MockConvexRewards(address(lp), address(crv), address(cvx));
        booster = new MockConvexBooster(address(lp), address(rewards));
        rewards.setBooster(address(booster));

        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = address(crv);
        rewardTokens[1] = address(cvx);

        strat = new ConvexLpStrategy(
            vaultAddr,
            address(lp),
            address(oracle),
            address(swapper),
            address(booster),
            address(rewards),
            9,
            address(crv),
            rewardTokens
        );

        lp.mint(vaultAddr, 1_000e18);
        vm.prank(vaultAddr);
        lp.approve(address(strat), type(uint256).max);
    }

    function _invest(uint256 amount) internal {
        vm.prank(vaultAddr);
        strat.invest(amount);
    }

    function test_noReceiptForTheVault() public view {
        assertEq(strat.receiptToken(), address(0));
    }

    function test_stakedLpIsThePositionOneToOne() public {
        _invest(100e18);

        assertEq(strat.stakedLpBalance(), 100e18);
        assertEq(strat.positionValue(), 100e18);
        assertEq(lp.balanceOf(address(strat)), 0);
    }

    function test_divestUnstakesExactlyWhatWasAsked() public {
        _invest(100e18);

        uint256 before = lp.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 freed = strat.divest(40e18);

        assertEq(freed, 40e18);
        assertEq(lp.balanceOf(vaultAddr) - before, 40e18);
        assertEq(strat.positionValue(), 60e18);
    }

    function test_divestCapsAtTheStakedBalance() public {
        _invest(10e18);
        vm.prank(vaultAddr);
        assertEq(strat.divest(500e18), 10e18);
    }

    function test_emergencyWithdrawUnstakesEverything() public {
        _invest(100e18);
        vm.prank(vaultAddr);
        assertEq(strat.emergencyWithdraw(), 100e18);
        assertEq(strat.positionValue(), 0);
    }

    function test_pendingRewardsCountThePrimaryEmissionOnly() public {
        _invest(100e18);
        rewards.accrue(address(strat), 20e18);

        uint256 gross = 20 * 50e18;
        assertEq(strat.pendingRewardsValue(), (gross * 9_800) / 10_000);
    }

    function test_harvestSellsEveryEmissionBackIntoLp() public {
        _invest(100e18);
        rewards.accrue(address(strat), 20e18);

        uint256 before = lp.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 realized = strat.harvest();

        assertEq(realized, 20 * 50e18 + 10 * 30e18);
        assertEq(lp.balanceOf(vaultAddr) - before, realized);
    }

    function test_harvestWithoutAnLpPriceSkipsRatherThanSellingBlind() public {
        _invest(100e18);
        rewards.accrue(address(strat), 20e18);
        oracle.setReverting(address(lp), true);

        vm.prank(vaultAddr);
        assertEq(strat.harvest(), 0);
        assertEq(crv.balanceOf(address(strat)), 20e18);
    }

    function test_valuationSurvivesAnUnpricedLp() public {
        _invest(100e18);
        rewards.accrue(address(strat), 20e18);
        oracle.setReverting(address(lp), true);

        assertEq(strat.positionValue(), 100e18);
    }

    function test_aBrokenGaugeCannotBlockValuation() public {
        _invest(100e18);
        rewards.setBroken(true);

        assertEq(strat.positionValue(), 100e18);

        vm.prank(vaultAddr);
        vm.expectRevert(bytes("GAUGE_BROKEN"));
        strat.divest(10e18);
    }

    function test_onlyVaultGuards() public {
        vm.expectRevert(bytes("NOT_VAULT"));
        strat.invest(1e18);
        vm.expectRevert(bytes("NOT_VAULT"));
        strat.divest(1e18);
        vm.expectRevert(bytes("NOT_VAULT"));
        strat.harvest();
    }

    function testFuzz_stakedLpRoundTripsExactly(uint96 amount) public {
        uint256 a = bound(amount, 1e15, 1_000e18);
        _invest(a);

        vm.prank(vaultAddr);
        assertEq(strat.emergencyWithdraw(), a);
    }
}

contract PendlePtStrategyTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal underlying;
    MockPt internal pt;
    MockPendleOracle internal ptOracle;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    PendlePtStrategy internal strat;

    address internal vaultAddr = address(0xAA17);
    address internal market = address(0x9A12);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        underlying = new MockERC20("Ethena USD", "USDe", 18);
        pt = new MockPt();
        ptOracle = new MockPendleOracle();
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);

        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(underlying), 1e8);
        oracle.setPrice(address(pt), 0.95e8);

        strat = new PendlePtStrategy(
            vaultAddr,
            address(usdc),
            address(oracle),
            address(swapper),
            address(pt),
            market,
            address(ptOracle),
            address(underlying),
            3600
        );

        usdc.mint(vaultAddr, 1_000_000e6);
        vm.startPrank(vaultAddr);
        usdc.approve(address(strat), type(uint256).max);
        pt.approve(address(strat), type(uint256).max);
        vm.stopPrank();
    }

    function _invest(uint256 amount) internal {
        vm.prank(vaultAddr);
        strat.invest(amount);
    }

    function test_thePtIsCustodiedByTheVault() public {
        _invest(95_000e6);

        assertEq(strat.receiptToken(), address(pt));
        assertGt(pt.balanceOf(vaultAddr), 0);
        assertEq(pt.balanceOf(address(strat)), 0);
    }

    function test_valueIsThePtRateConvertedToBase() public {
        _invest(95_000e6);

        uint256 held = pt.balanceOf(vaultAddr);
        uint256 expected = (held * 0.95e18) / 1e18 / 1e12;
        assertApproxEqRel(strat.positionValue(), expected, 0.001e18);
    }

    function test_valueAccretesAsTheRatePullsToPar() public {
        _invest(95_000e6);
        uint256 before = strat.positionValue();

        ptOracle.setRate(1e18);
        assertGt(strat.positionValue(), before);
    }

    function test_divestSellsPtBackToBase() public {
        _invest(95_000e6);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 freed = strat.divest(20_000e6);

        assertGe(freed, 20_000e6);
        assertEq(usdc.balanceOf(vaultAddr) - before, freed);
    }

    function test_emergencyWithdrawSellsTheWholePosition() public {
        _invest(95_000e6);

        vm.prank(vaultAddr);
        assertGt(strat.emergencyWithdraw(), 0);
        assertEq(pt.balanceOf(vaultAddr), 0);
    }

    function test_harvestIsANoop() public {
        _invest(95_000e6);
        vm.prank(vaultAddr);
        assertEq(strat.harvest(), 0);
    }

    function test_aDeadTwapMakesValuationRevertRatherThanGuess() public {
        _invest(95_000e6);
        ptOracle.setBroken(true);

        vm.expectRevert(bytes("NO_TWAP"));
        strat.positionValue();
    }

    function test_aZeroRateIsRefused() public {
        _invest(95_000e6);
        ptOracle.setRate(0);

        vm.expectRevert(bytes("NO_RATE"));
        strat.positionValue();
    }

    function test_theTwapWindowHasAFloor() public {
        vm.prank(vaultAddr);
        vm.expectRevert(bytes("TWAP_TOO_SHORT"));
        strat.setTwapDuration(899);

        vm.prank(vaultAddr);
        strat.setTwapDuration(900);
        assertEq(strat.twapDuration(), 900);

        vm.expectRevert(bytes("TWAP_TOO_SHORT"));
        new PendlePtStrategy(
            vaultAddr,
            address(usdc),
            address(oracle),
            address(swapper),
            address(pt),
            market,
            address(ptOracle),
            address(underlying),
            300
        );
    }

    function test_maturityIsReported() public {
        assertFalse(strat.isExpired());
        pt.setExpired(true);
        assertTrue(strat.isExpired());
        assertEq(strat.expiry(), 1 days);
    }

    function test_onlyVaultGuards() public {
        vm.expectRevert(bytes("NOT_VAULT"));
        strat.setTwapDuration(3600);
        vm.expectRevert(bytes("NOT_VAULT"));
        strat.setRoutes("", "");
    }
}

contract CurveFourCoinTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal a;
    MockERC20 internal b;
    MockERC20 internal c;
    MockERC20 internal lp;
    MockERC20 internal crv;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockCurvePool internal pool;
    MockConvexRewards internal rewards;
    MockConvexBooster internal booster;
    CurveConvexStrategy internal strat;

    address internal vaultAddr = address(0xAA17);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        a = new MockERC20("A", "A", 18);
        b = new MockERC20("B", "B", 18);
        c = new MockERC20("C", "C", 18);
        lp = new MockERC20("LP", "LP", 18);
        crv = new MockERC20("Curve", "CRV", 18);

        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(crv), 50e8);

        address[] memory coins = new address[](4);
        coins[0] = address(a);
        coins[1] = address(usdc);
        coins[2] = address(b);
        coins[3] = address(c);
        pool = new MockCurvePool(coins, address(lp));

        rewards = new MockConvexRewards(address(lp), address(crv), address(crv));
        booster = new MockConvexBooster(address(lp), address(rewards));
        rewards.setBooster(address(booster));

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(crv);

        strat = new CurveConvexStrategy(
            vaultAddr,
            address(usdc),
            address(oracle),
            address(swapper),
            CurveConvexStrategy.Config({
                curvePool: address(pool),
                curveLp: address(lp),
                booster: address(booster),
                convexRewards: address(rewards),
                convexPid: 4,
                baseIndex: 1,
                nCoins: 4,
                crv: address(crv),
                rewardTokens: rewardTokens
            })
        );

        usdc.mint(vaultAddr, 1_000_000e6);
        vm.prank(vaultAddr);
        usdc.approve(address(strat), type(uint256).max);
    }

    function test_theFourCoinAddLiquidityShapeWorks() public {
        vm.prank(vaultAddr);
        strat.invest(10_000e6);

        assertEq(strat.stakedLpBalance(), 10_000e18);
        assertEq(strat.positionValue(), 10_000e6);
    }

    function test_theFourCoinPoolRoundTrips() public {
        vm.prank(vaultAddr);
        strat.invest(10_000e6);
        pool.accrueFeesBps(100);

        vm.prank(vaultAddr);
        uint256 freed = strat.emergencyWithdraw();
        assertApproxEqRel(freed, 10_100e6, 0.0001e18);
    }

    function test_aMisdeclaredCoinIndexIsRejected() public {
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(crv);

        vm.expectRevert(bytes("COIN_MISMATCH"));
        new CurveConvexStrategy(
            vaultAddr,
            address(usdc),
            address(oracle),
            address(swapper),
            CurveConvexStrategy.Config({
                curvePool: address(pool),
                curveLp: address(lp),
                booster: address(booster),
                convexRewards: address(rewards),
                convexPid: 4,
                baseIndex: 3,
                nCoins: 4,
                crv: address(crv),
                rewardTokens: rewardTokens
            })
        );
    }
}
