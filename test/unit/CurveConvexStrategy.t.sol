// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {CurveConvexStrategy} from "../../src/strategies/common/CurveConvexStrategy.sol";
import {MockERC20, MockOracle, MockSwapper} from "../mocks/Mocks.sol";
import {MockCurvePool, MockConvexBooster, MockConvexRewards} from "../mocks/MockVenues.sol";

contract CurveConvexStrategyTest is Test {
    MockERC20 internal dai;
    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockERC20 internal lp;
    MockERC20 internal crv;
    MockERC20 internal cvx;

    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockCurvePool internal pool;
    MockConvexRewards internal rewards;
    MockConvexBooster internal booster;
    CurveConvexStrategy internal strat;

    address internal vaultAddr = address(0xAA17);

    function setUp() public {
        dai = new MockERC20("Dai", "DAI", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether", "USDT", 6);
        lp = new MockERC20("3pool LP", "3CRV", 18);
        crv = new MockERC20("Curve", "CRV", 18);
        cvx = new MockERC20("Convex", "CVX", 18);

        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(crv), 50e8);
        oracle.setPrice(address(cvx), 30e8);

        address[] memory coins = new address[](3);
        coins[0] = address(dai);
        coins[1] = address(usdc);
        coins[2] = address(usdt);
        pool = new MockCurvePool(coins, address(lp));

        rewards = new MockConvexRewards(address(lp), address(crv), address(cvx));
        booster = new MockConvexBooster(address(lp), address(rewards));
        rewards.setBooster(address(booster));

        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = address(crv);
        rewardTokens[1] = address(cvx);

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
                convexPid: 9,
                baseIndex: 1,
                nCoins: 3,
                crv: address(crv),
                rewardTokens: rewardTokens
            })
        );

        usdc.mint(vaultAddr, 1_000_000e6);
        vm.prank(vaultAddr);
        usdc.approve(address(strat), type(uint256).max);
    }

    function _invest(uint256 amount) internal {
        vm.prank(vaultAddr);
        strat.invest(amount);
    }

    function test_noReceiptForTheVault() public view {
        assertEq(strat.receiptToken(), address(0));
    }

    function test_investAddsLiquidityAndStakesInConvex() public {
        _invest(10_000e6);

        assertEq(strat.stakedLpBalance(), 10_000e18);
        assertEq(lp.balanceOf(address(strat)), 0);
        assertEq(strat.positionValue(), 10_000e6);
    }

    function test_valueRisesWithVirtualPrice() public {
        _invest(10_000e6);
        pool.accrueFeesBps(200);

        assertEq(strat.positionValue(), 10_200e6);
    }

    function test_divestUnstakesAndExitsSingleSided() public {
        _invest(10_000e6);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(3_000e6);

        assertGe(withdrawn, 3_000e6);
        assertEq(usdc.balanceOf(vaultAddr) - before, withdrawn);
        assertLt(strat.stakedLpBalance(), 10_000e18);
    }

    function test_divestCapsAtStakedBalance() public {
        _invest(1_000e6);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(80_000e6);

        assertApproxEqRel(withdrawn, 1_000e6, 0.001e18);
        assertEq(strat.stakedLpBalance(), 0);
    }

    function test_emergencyWithdrawUnwindsEverything() public {
        _invest(10_000e6);
        pool.accrueFeesBps(100);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();

        assertApproxEqRel(withdrawn, 10_100e6, 0.001e18);
        assertEq(strat.stakedLpBalance(), 0);
    }

    function test_exitSlippageBeyondToleranceReverts() public {
        _invest(10_000e6);
        pool.setExitLossBps(300);

        vm.prank(vaultAddr);
        vm.expectRevert(bytes("REMOVE_LIQUIDITY_FAILED"));
        strat.divest(3_000e6);
    }

    function test_pendingRewardsCountCrvOnly() public {
        _invest(10_000e6);
        rewards.accrue(address(strat), 20e18);

        uint256 gross = 20 * 50e6;
        assertEq(strat.pendingRewardsValue(), (gross * 9_800) / 10_000);
    }

    function test_harvestSellsCrvAndCvx() public {
        _invest(10_000e6);
        rewards.accrue(address(strat), 20e18);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 realized = strat.harvest();

        assertEq(realized, 20 * 50e6 + 10 * 30e6);
        assertEq(usdc.balanceOf(vaultAddr) - before, realized);
        assertEq(strat.pendingRewardsValue(), 0);
    }

    function test_brokenGaugeDoesNotBlockValuation() public {
        _invest(10_000e6);
        rewards.setBroken(true);

        assertEq(strat.positionValue(), 10_000e6);

        vm.prank(vaultAddr);
        vm.expectRevert(bytes("GAUGE_BROKEN"));
        strat.divest(1_000e6);
    }

    function test_constructorRejectsWrongCoinIndex() public {
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
                convexPid: 9,
                baseIndex: 0,
                nCoins: 3,
                crv: address(crv),
                rewardTokens: rewardTokens
            })
        );
    }

    function test_constructorRejectsBadPoolSize() public {
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(crv);

        vm.expectRevert(bytes("BAD_NCOINS"));
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
                convexPid: 9,
                baseIndex: 1,
                nCoins: 5,
                crv: address(crv),
                rewardTokens: rewardTokens
            })
        );
    }

    function testFuzz_lpAccountingRoundTrips(uint96 amount) public {
        amount = uint96(bound(amount, 100e6, 500_000e6));
        _invest(amount);

        assertApproxEqRel(strat.positionValue(), amount, 0.0001e18);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();
        assertApproxEqRel(withdrawn, amount, 0.0001e18);
    }
}

contract CurveConvexTwoCoinTest is Test {
    MockERC20 internal weth;
    MockERC20 internal steth;
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
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        steth = new MockERC20("Lido stETH", "stETH", 18);
        lp = new MockERC20("steth LP", "steCRV", 18);
        crv = new MockERC20("Curve", "CRV", 18);

        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(weth), 3_000e8);
        oracle.setPrice(address(crv), 50e8);

        address[] memory coins = new address[](2);
        coins[0] = address(weth);
        coins[1] = address(steth);
        pool = new MockCurvePool(coins, address(lp));

        rewards = new MockConvexRewards(address(lp), address(crv), address(crv));
        booster = new MockConvexBooster(address(lp), address(rewards));
        rewards.setBooster(address(booster));

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = address(crv);

        strat = new CurveConvexStrategy(
            vaultAddr,
            address(weth),
            address(oracle),
            address(swapper),
            CurveConvexStrategy.Config({
                curvePool: address(pool),
                curveLp: address(lp),
                booster: address(booster),
                convexRewards: address(rewards),
                convexPid: 3,
                baseIndex: 0,
                nCoins: 2,
                crv: address(crv),
                rewardTokens: rewardTokens
            })
        );

        weth.mint(vaultAddr, 1_000e18);
        vm.prank(vaultAddr);
        weth.approve(address(strat), type(uint256).max);
    }

    function test_twoCoinPoolAddLiquidityShapeWorks() public {
        vm.prank(vaultAddr);
        strat.invest(10e18);

        assertEq(strat.stakedLpBalance(), 10e18);
        assertEq(strat.positionValue(), 10e18);
    }

    function test_eighteenDecimalBaseRoundTrips() public {
        vm.prank(vaultAddr);
        strat.invest(10e18);
        pool.accrueFeesBps(50);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();
        assertApproxEqRel(withdrawn, 10.05e18, 0.0001e18);
    }
}
