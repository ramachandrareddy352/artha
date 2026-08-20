// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {Mainnet} from "../helpers/Addresses.sol";
import {AaveV3UsdcStrategy} from "../../src/strategies/usdc/lend/AaveV3UsdcStrategy.sol";
import {CompoundV3UsdcStrategy} from "../../src/strategies/usdc/lend/CompoundV3UsdcStrategy.sol";
import {CurveConvexUsdcStrategy} from "../../src/strategies/usdc/others/CurveConvexUsdcStrategy.sol";
import {CurveConvexStrategy} from "../../src/strategies/common/CurveConvexStrategy.sol";

interface IConvexBoosterLive {
    function earmarkRewards(uint256 pid) external returns (bool);
}

interface ICometLive {
    function accrueAccount(address account) external;
}

contract UsdcStrategiesForkTest is ForkBase {
    AaveV3UsdcStrategy internal aaveStrat;
    CompoundV3UsdcStrategy internal cometStrat;
    CurveConvexUsdcStrategy internal curveStrat;

    function setUp() public {
        if (!_forkOrSkip()) return;

        _deployVault(Mainnet.USDC, 1_000, 5_000);

        _registerFeed(Mainnet.USDC, Mainnet.CHAINLINK_USDC_USD);
        _registerFeedAt(Mainnet.CRV, 30e8);
        _registerFeedAt(Mainnet.CVX, 25e8);
        _registerFeedAt(Mainnet.COMP, 50e8);

        address[] memory noRewards = new address[](0);
        aaveStrat = new AaveV3UsdcStrategy(
            address(vault),
            Mainnet.USDC,
            address(priceFeed),
            address(uniSwapper),
            Mainnet.AAVE_V3_POOL,
            Mainnet.AAVE_A_USDC,
            Mainnet.AAVE_REWARDS_CONTROLLER,
            noRewards
        );

        cometStrat = new CompoundV3UsdcStrategy(
            address(vault),
            Mainnet.USDC,
            address(priceFeed),
            address(uniSwapper),
            Mainnet.COMET_USDC,
            Mainnet.COMET_REWARDS,
            Mainnet.COMP
        );

        address[] memory curveRewards = new address[](2);
        curveRewards[0] = Mainnet.CRV;
        curveRewards[1] = Mainnet.CVX;
        curveStrat = new CurveConvexUsdcStrategy(
            address(vault),
            Mainnet.USDC,
            address(priceFeed),
            address(uniSwapper),
            CurveConvexStrategy.Config({
                curvePool: Mainnet.CURVE_3POOL,
                curveLp: Mainnet.CURVE_3POOL_LP,
                booster: Mainnet.CONVEX_BOOSTER,
                convexRewards: Mainnet.CONVEX_3POOL_REWARDS,
                convexPid: Mainnet.CONVEX_3POOL_PID,
                baseIndex: 1,
                nCoins: 3,
                crv: Mainnet.CRV,
                rewardTokens: curveRewards
            })
        );

        _give(Mainnet.USDC, alice, 5_000_000e6);
        _give(Mainnet.USDC, bob, 5_000_000e6);
    }

    function test_aaveSuppliesRealUsdcAndAccruesRealInterest() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e6);
        _deployIdle();

        assertApproxEqRel(aaveStrat.positionValue(), 900_000e6, 0.001e18);
        assertApproxEqRel(IERC20(Mainnet.AAVE_A_USDC).balanceOf(address(vault)), 900_000e6, 0.001e18);

        uint256 before = aaveStrat.positionValue();
        _skipTime(30 days);

        uint256 grown = aaveStrat.positionValue();
        assertGt(grown, before);

        _settle();
        assertGt(_totalAssets(), 1_000_000e6);
    }

    function test_aaveWithdrawalReturnsPrincipalPlusInterest() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e6);
        _deployIdle();

        _skipTime(90 days);
        _settle();

        uint256 shares = _shareToken().balanceOf(alice);
        uint256 balBefore = IERC20(Mainnet.USDC).balanceOf(alice);
        _redeem(alice, shares);

        uint256 received = IERC20(Mainnet.USDC).balanceOf(alice) - balBefore;
        assertGt(received, 1_000_000e6);
    }

    function test_cometSuppliesRealUsdcAndAccruesRealInterest() public {
        _addSingleStrategy(address(cometStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e6);
        _deployIdle();

        uint256 before = cometStrat.positionValue();
        assertApproxEqRel(before, 900_000e6, 0.001e18);

        _skipTime(30 days);
        assertGt(cometStrat.positionValue(), before);
    }

    function test_cometCompAccrualIsOnlyVisibleAfterAnAccrueAccountPoke() public {
        _addSingleStrategy(address(cometStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e6);
        _deployIdle();

        _skipTime(30 days);
        assertEq(cometStrat.pendingRewardAmount(Mainnet.COMP), 0);

        ICometLive(Mainnet.COMET_USDC).accrueAccount(address(cometStrat));
        assertGt(cometStrat.pendingRewardAmount(Mainnet.COMP), 0);
        assertGt(cometStrat.pendingRewardsValue(), 0);
    }

    function test_harvestSurvivesAnUnderfundedCometRewardsContract() public {
        _addSingleStrategy(address(cometStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e6);
        _deployIdle();

        _skipTime(30 days);
        ICometLive(Mainnet.COMET_USDC).accrueAccount(address(cometStrat));
        assertGt(cometStrat.pendingRewardAmount(Mainnet.COMP), 0);

        uint256 idleBefore = _idleBalance();
        uint256 realized = _harvest(address(cometStrat));

        assertEq(_idleBalance(), idleBefore + realized);
        assertGt(cometStrat.positionValue(), 0);
    }

    function test_rebalanceSurvivesAnUnderfundedRewardsContract() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);

        address[] memory two = new address[](2);
        two[0] = address(aaveStrat);
        two[1] = address(cometStrat);
        uint16[] memory w2 = new uint16[](2);
        w2[0] = 4_500;
        w2[1] = 4_500;
        _addStrategy(address(cometStrat), two, w2, 1_000);

        _deposit(alice, 1_000_000e6);
        _deployIdle();

        _skipTime(30 days);
        ICometLive(Mainnet.COMET_USDC).accrueAccount(address(cometStrat));

        _rebalance();

        assertApproxEqRel(aaveStrat.positionValue(), cometStrat.positionValue(), 0.02e18);
    }

    function test_governanceCanStillRetireAStrategyWithUnpayableRewards() public {
        _addSingleStrategy(address(cometStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e6);
        _deployIdle();

        _skipTime(30 days);
        ICometLive(Mainnet.COMET_USDC).accrueAccount(address(cometStrat));

        vm.prank(GOV);
        (bool ok,) = address(vault).call(
            abi.encodeWithSignature("removeStrategy(address,uint256)", address(cometStrat), uint256(1_000e6))
        );
        assertTrue(ok);
        assertEq(_strategyList().length, 0);
    }

    function test_curveConvexEntersRealPoolAndStakes() public {
        _addSingleStrategy(address(curveStrat), 9_000, 1_000);
        _deposit(alice, 500_000e6);
        _deployIdle();

        assertGt(curveStrat.stakedLpBalance(), 0);
        assertApproxEqRel(curveStrat.positionValue(), 450_000e6, 0.01e18);
    }

    function test_curveConvexAccruesCrvAfterEarmark() public {
        _addSingleStrategy(address(curveStrat), 9_000, 1_000);
        _deposit(alice, 500_000e6);
        _deployIdle();

        IConvexBoosterLive(Mainnet.CONVEX_BOOSTER).earmarkRewards(Mainnet.CONVEX_3POOL_PID);
        _skipTime(6 days);

        assertGt(curveStrat.pendingRewardAmount(Mainnet.CRV), 0);
        assertGt(curveStrat.pendingRewardsValue(), 0);
    }

    function test_curveConvexPartialWithdrawalThroughTheRealPool() public {
        _addSingleStrategy(address(curveStrat), 9_000, 1_000);
        _deposit(alice, 500_000e6);
        _deployIdle();

        uint256 balBefore = IERC20(Mainnet.USDC).balanceOf(alice);
        _withdraw(alice, 400_000e6);

        assertEq(IERC20(Mainnet.USDC).balanceOf(alice) - balBefore, 400_000e6);
        assertGt(curveStrat.positionValue(), 0);
    }

    function test_fullRedeemFromASlippageBearingVenueNeedsTheEmergencyExit() public {
        _addSingleStrategy(address(curveStrat), 9_000, 1_000);
        _deposit(alice, 500_000e6);
        _deployIdle();

        uint256 shares = _shareToken().balanceOf(alice);

        vm.prank(alice);
        (bool ok,) = address(vault).call(
            abi.encodeWithSignature("redeem(uint256,address,address,uint256)", shares, alice, alice, uint256(0))
        );
        assertFalse(ok);

        uint256 balBefore = IERC20(Mainnet.USDC).balanceOf(alice);
        _withdraw(alice, 499_000e6);
        assertEq(IERC20(Mainnet.USDC).balanceOf(alice) - balBefore, 499_000e6);

        _pause();
        _emergencyWithdraw(alice, _shareToken().balanceOf(alice));
        assertEq(_shareToken().balanceOf(alice), 0);
    }

    function test_threeRealVenuesSideBySideWithRebalance() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);

        address[] memory two = new address[](2);
        two[0] = address(aaveStrat);
        two[1] = address(cometStrat);
        uint16[] memory w2 = new uint16[](2);
        w2[0] = 4_500;
        w2[1] = 4_500;
        _addStrategy(address(cometStrat), two, w2, 1_000);

        address[] memory three = new address[](3);
        three[0] = address(aaveStrat);
        three[1] = address(cometStrat);
        three[2] = address(curveStrat);
        uint16[] memory w3 = new uint16[](3);
        w3[0] = 3_000;
        w3[1] = 3_000;
        w3[2] = 3_000;
        _addStrategy(address(curveStrat), three, w3, 1_000);

        _deposit(alice, 1_000_000e6);
        _deployIdle();

        assertApproxEqRel(aaveStrat.positionValue(), 300_000e6, 0.01e18);
        assertApproxEqRel(cometStrat.positionValue(), 300_000e6, 0.01e18);
        assertApproxEqRel(curveStrat.positionValue(), 300_000e6, 0.02e18);

        _skipTime(30 days);
        _deposit(bob, 500_000e6);
        _rebalance();

        assertApproxEqRel(
            aaveStrat.positionValue() + cometStrat.positionValue() + curveStrat.positionValue() + _idleBalance(),
            _totalAssets(),
            0.001e18
        );

        uint256 aliceShares = _shareToken().balanceOf(alice);
        uint256 balBefore = IERC20(Mainnet.USDC).balanceOf(alice);
        _redeem(alice, aliceShares);
        assertGt(IERC20(Mainnet.USDC).balanceOf(alice) - balBefore, 990_000e6);
    }

    function test_userWithdrawsWhileAaveInterestIsStillAccruing() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e6);
        _deployIdle();

        _skipTime(10 days);
        _deposit(bob, 500_000e6);
        _deployIdle();

        _skipTime(10 days);
        uint256 balBefore = IERC20(Mainnet.USDC).balanceOf(alice);
        _withdraw(alice, 200_000e6);
        assertEq(IERC20(Mainnet.USDC).balanceOf(alice) - balBefore, 200_000e6);

        _skipTime(10 days);
        _settle();

        uint256 bobShares = _shareToken().balanceOf(bob);
        uint256 bobValue = _previewRedeem(bobShares);
        assertGt(bobValue, 500_000e6);
    }

    function _previewRedeem(uint256 shares) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            address(vault).staticcall(abi.encodeWithSignature("previewRedeem(uint256)", shares));
        require(ok, "PREVIEW_FAILED");
        return abi.decode(data, (uint256));
    }
}
