// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {Mainnet} from "../helpers/Addresses.sol";
import {AaveV3DaiStrategy} from "../../src/strategies/dai/lend/AaveV3DaiStrategy.sol";
import {SparkDaiStrategy} from "../../src/strategies/dai/lend/SparkDaiStrategy.sol";
import {SkySDaiStrategy} from "../../src/strategies/dai/yield/SkySDaiStrategy.sol";

contract DaiStrategiesForkTest is ForkBase {
    AaveV3DaiStrategy internal aaveStrat;
    SparkDaiStrategy internal sparkStrat;
    SkySDaiStrategy internal sDaiStrat;

    function setUp() public {
        if (!_forkOrSkip()) return;

        _deployVault(Mainnet.DAI, 1_000, 5_000);
        _registerFeed(Mainnet.DAI, Mainnet.CHAINLINK_DAI_USD);

        address[] memory noRewards = new address[](0);
        aaveStrat = new AaveV3DaiStrategy(
            address(vault),
            Mainnet.DAI,
            address(priceFeed),
            address(uniSwapper),
            Mainnet.AAVE_V3_POOL,
            Mainnet.AAVE_A_DAI,
            Mainnet.AAVE_REWARDS_CONTROLLER,
            noRewards
        );

        sparkStrat = new SparkDaiStrategy(
            address(vault),
            Mainnet.DAI,
            address(priceFeed),
            address(uniSwapper),
            Mainnet.SPARK_POOL,
            Mainnet.SPARK_SP_DAI,
            address(0),
            noRewards
        );

        sDaiStrat =
            new SkySDaiStrategy(address(vault), Mainnet.DAI, address(priceFeed), address(uniSwapper), Mainnet.SDAI);

        _give(Mainnet.DAI, alice, 5_000_000e18);
        _give(Mainnet.DAI, bob, 5_000_000e18);
    }

    function test_aaveSuppliesRealDai() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e18);
        _deployIdle();

        assertApproxEqRel(aaveStrat.positionValue(), 900_000e18, 0.001e18);

        uint256 before = aaveStrat.positionValue();
        _skipTime(30 days);
        assertGt(aaveStrat.positionValue(), before);
    }

    function test_sparkSuppliesRealDai() public {
        _addSingleStrategy(address(sparkStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e18);
        _deployIdle();

        assertApproxEqRel(sparkStrat.positionValue(), 900_000e18, 0.001e18);
        assertApproxEqRel(IERC20(Mainnet.SPARK_SP_DAI).balanceOf(address(vault)), 900_000e18, 0.001e18);

        uint256 before = sparkStrat.positionValue();
        _skipTime(30 days);
        assertGt(sparkStrat.positionValue(), before);
    }

    function test_sDaiEarnsTheRealSavingsRateOverWarpedTime() public {
        _addSingleStrategy(address(sDaiStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e18);
        _deployIdle();

        uint256 before = sDaiStrat.positionValue();
        assertApproxEqRel(before, 900_000e18, 0.001e18);
        assertGt(IERC20(Mainnet.SDAI).balanceOf(address(vault)), 0);

        _skipTime(180 days);

        uint256 grown = sDaiStrat.positionValue();
        assertGt(grown, before);

        _settle();
        assertGt(_totalAssets(), 1_000_000e18);
    }

    function test_sDaiRoundTripReturnsPrincipalPlusYield() public {
        _addSingleStrategy(address(sDaiStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e18);
        _deployIdle();

        _skipTime(180 days);
        _settle();

        uint256 balBefore = IERC20(Mainnet.DAI).balanceOf(alice);
        _redeem(alice, _shareToken().balanceOf(alice));

        assertGt(IERC20(Mainnet.DAI).balanceOf(alice) - balBefore, 1_000_000e18);
    }

    function test_threeDaiVenuesTogetherWithUserChurn() public {
        _addSingleStrategy(address(sDaiStrat), 9_000, 1_000);

        address[] memory two = new address[](2);
        two[0] = address(sDaiStrat);
        two[1] = address(aaveStrat);
        uint16[] memory w2 = new uint16[](2);
        w2[0] = 4_500;
        w2[1] = 4_500;
        _addStrategy(address(aaveStrat), two, w2, 1_000);

        address[] memory three = new address[](3);
        three[0] = address(sDaiStrat);
        three[1] = address(aaveStrat);
        three[2] = address(sparkStrat);
        uint16[] memory w3 = new uint16[](3);
        w3[0] = 3_000;
        w3[1] = 3_000;
        w3[2] = 3_000;
        _addStrategy(address(sparkStrat), three, w3, 1_000);

        _deposit(alice, 1_000_000e18);
        _deployIdle();
        _skipTime(30 days);

        _deposit(bob, 500_000e18);
        _rebalance();

        _withdraw(alice, 200_000e18);
        _skipTime(30 days);
        _settle();

        assertApproxEqRel(
            sDaiStrat.positionValue() + aaveStrat.positionValue() + sparkStrat.positionValue() + _idleBalance(),
            _totalAssets(),
            0.001e18
        );

        uint256 balBefore = IERC20(Mainnet.DAI).balanceOf(bob);
        _redeem(bob, _shareToken().balanceOf(bob));
        assertGt(IERC20(Mainnet.DAI).balanceOf(bob) - balBefore, 500_000e18);
    }
}
