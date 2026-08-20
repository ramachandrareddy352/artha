// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {Mainnet} from "../helpers/Addresses.sol";
import {AaveV3WbtcStrategy} from "../../src/strategies/wbtc/lend/AaveV3WbtcStrategy.sol";
import {WbtcRotationStrategy} from "../../src/strategies/wbtc/rotate/WbtcRotationStrategy.sol";
import {RotationStrategy} from "../../src/strategies/common/RotationStrategy.sol";

contract WbtcStrategiesForkTest is ForkBase {
    AaveV3WbtcStrategy internal aaveStrat;
    WbtcRotationStrategy internal rotStrat;

    uint256 internal constant ONE_BTC = 1e8;

    function setUp() public {
        if (!_forkOrSkip()) return;

        _deployVault(Mainnet.WBTC, 1_000, 9_000);

        _registerFeed(Mainnet.WBTC, Mainnet.CHAINLINK_BTC_USD);
        _registerFeed(Mainnet.USDC, Mainnet.CHAINLINK_USDC_USD);

        address[] memory noRewards = new address[](0);
        aaveStrat = new AaveV3WbtcStrategy(
            address(vault),
            Mainnet.WBTC,
            address(priceFeed),
            address(uniSwapper),
            Mainnet.AAVE_V3_POOL,
            Mainnet.AAVE_A_WBTC,
            Mainnet.AAVE_REWARDS_CONTROLLER,
            noRewards
        );

        rotStrat = new WbtcRotationStrategy(
            address(vault),
            Mainnet.WBTC,
            address(priceFeed),
            address(uniSwapper),
            Mainnet.USDC,
            address(0),
            address(0),
            RotationStrategy.Params({
                enterQuoteDropBps: 30,
                enterReboundBps: 0,
                exitQuoteGainBps: 30,
                exitTrailingBps: 0,
                exitStopLossBps: 0,
                cooldown: 1 hours,
                maxQuoteHold: 0
            })
        );

        _give(Mainnet.WBTC, alice, 100 * ONE_BTC);
        _give(Mainnet.WBTC, bob, 100 * ONE_BTC);
    }

    function _wireRotationRoutes() internal {
        bytes memory buy = abi.encodePacked(Mainnet.WBTC, uint24(3000), Mainnet.WETH, uint24(500), Mainnet.USDC);
        bytes memory sell = abi.encodePacked(Mainnet.USDC, uint24(500), Mainnet.WETH, uint24(3000), Mainnet.WBTC);
        _exec(address(rotStrat), abi.encodeCall(rotStrat.setRoutes, (buy, sell)));
        _exec(address(rotStrat), abi.encodeCall(rotStrat.setMaxSlippageBps, (500)));
    }

    function test_aaveSuppliesRealWbtc() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);
        _deposit(alice, 10 * ONE_BTC);
        _deployIdle();

        assertApproxEqRel(aaveStrat.positionValue(), 9 * ONE_BTC, 0.001e18);
        assertApproxEqRel(IERC20(Mainnet.AAVE_A_WBTC).balanceOf(address(vault)), 9 * ONE_BTC, 0.001e18);
    }

    function test_aaveWbtcYieldIsRealButTiny() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);
        _deposit(alice, 10 * ONE_BTC);
        _deployIdle();

        uint256 before = aaveStrat.positionValue();
        _skipTime(365 days);
        uint256 grown = aaveStrat.positionValue();

        assertGe(grown, before);
        assertLt(grown, (before * 105) / 100);
    }

    function test_aaveWbtcRoundTrip() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);
        _deposit(alice, 10 * ONE_BTC);
        _deployIdle();

        _skipTime(30 days);
        _settle();

        uint256 balBefore = IERC20(Mainnet.WBTC).balanceOf(alice);
        _withdraw(alice, 9 * ONE_BTC);
        assertEq(IERC20(Mainnet.WBTC).balanceOf(alice) - balBefore, 9 * ONE_BTC);
    }

    function test_rotationHoldsWbtcUntilTheBandIsCrossed() public {
        _addSingleStrategy(address(rotStrat), 9_000, 1_000);
        _wireRotationRoutes();
        _deposit(alice, ONE_BTC);
        _deployIdle();

        assertEq(IERC20(Mainnet.WBTC).balanceOf(address(rotStrat)), (ONE_BTC * 9) / 10);

        _tend(address(rotStrat));
        assertEq(uint256(rotStrat.stance()), uint256(RotationStrategy.Stance.HoldBase));

        _movePriceBps(Mainnet.WBTC, 10);
        _skipTime(2 hours);
        _tend(address(rotStrat));
        assertEq(uint256(rotStrat.stance()), uint256(RotationStrategy.Stance.HoldBase));
    }

    function test_rotationSellsWbtcIntoUsdcThroughRealUniswapLiquidity() public {
        _addSingleStrategy(address(rotStrat), 9_000, 1_000);
        _wireRotationRoutes();
        _deposit(alice, ONE_BTC);
        _deployIdle();
        _tend(address(rotStrat));

        _movePriceBps(Mainnet.WBTC, 40);
        _skipTime(2 hours);
        _tend(address(rotStrat));

        assertEq(uint256(rotStrat.stance()), uint256(RotationStrategy.Stance.HoldQuote));
        assertEq(IERC20(Mainnet.WBTC).balanceOf(address(rotStrat)), 0);
        assertGt(IERC20(Mainnet.USDC).balanceOf(address(rotStrat)), 0);
        assertGt(rotStrat.positionValue(), 0);
    }

    function test_rotationBuysWbtcBackAndTheVaultEndsWithMoreOfIt() public {
        _addSingleStrategy(address(rotStrat), 9_000, 1_000);
        _wireRotationRoutes();
        _deposit(alice, ONE_BTC);
        _deployIdle();
        _tend(address(rotStrat));

        _movePriceBps(Mainnet.WBTC, 40);
        _skipTime(2 hours);
        _tend(address(rotStrat));
        assertEq(uint256(rotStrat.stance()), uint256(RotationStrategy.Stance.HoldQuote));

        _movePriceBps(Mainnet.WBTC, -40);
        _skipTime(2 hours);
        _tend(address(rotStrat));

        assertEq(uint256(rotStrat.stance()), uint256(RotationStrategy.Stance.HoldBase));
        assertGt(IERC20(Mainnet.WBTC).balanceOf(address(rotStrat)), 0);
        assertEq(IERC20(Mainnet.USDC).balanceOf(address(rotStrat)), 0);
        assertEq(rotStrat.rotations(), 2);
    }

    function test_userWithdrawsWhileTheRotationIsSittingInUsdc() public {
        _addSingleStrategy(address(rotStrat), 9_000, 1_000);
        _wireRotationRoutes();
        _deposit(alice, ONE_BTC);
        _deployIdle();
        _tend(address(rotStrat));

        _movePriceBps(Mainnet.WBTC, 40);
        _skipTime(2 hours);
        _tend(address(rotStrat));
        assertEq(uint256(rotStrat.stance()), uint256(RotationStrategy.Stance.HoldQuote));

        uint256 balBefore = IERC20(Mainnet.WBTC).balanceOf(alice);
        _withdraw(alice, ONE_BTC / 4);

        assertEq(IERC20(Mainnet.WBTC).balanceOf(alice) - balBefore, ONE_BTC / 4);
        assertGt(rotStrat.positionValue(), 0);
    }

    function test_emergencyExitOfARotationSittingInUsdc() public {
        _addSingleStrategy(address(rotStrat), 9_000, 1_000);
        _wireRotationRoutes();
        _deposit(alice, ONE_BTC);
        _deployIdle();
        _tend(address(rotStrat));

        _movePriceBps(Mainnet.WBTC, 40);
        _skipTime(2 hours);
        _tend(address(rotStrat));

        _pause();
        uint256 balBefore = IERC20(Mainnet.WBTC).balanceOf(alice);
        _emergencyWithdraw(alice, _shareToken().balanceOf(alice));

        assertGt(IERC20(Mainnet.WBTC).balanceOf(alice) - balBefore, (ONE_BTC * 95) / 100);
        assertEq(_shareToken().balanceOf(alice), 0);
    }

    function test_governanceCanFreezeTheRotationMidFlight() public {
        _addSingleStrategy(address(rotStrat), 9_000, 1_000);
        _wireRotationRoutes();
        _deposit(alice, ONE_BTC);
        _deployIdle();
        _tend(address(rotStrat));

        _exec(address(rotStrat), abi.encodeCall(rotStrat.setRotationEnabled, (false)));

        _movePriceBps(Mainnet.WBTC, 100);
        _skipTime(2 hours);
        _tend(address(rotStrat));

        assertEq(uint256(rotStrat.stance()), uint256(RotationStrategy.Stance.HoldBase));
        assertEq(rotStrat.rotations(), 0);
    }

    function test_lendingAndRotationSideBySide() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);

        address[] memory two = new address[](2);
        two[0] = address(aaveStrat);
        two[1] = address(rotStrat);
        uint16[] memory w = new uint16[](2);
        w[0] = 4_500;
        w[1] = 4_500;
        _addStrategy(address(rotStrat), two, w, 1_000);
        _wireRotationRoutes();

        _deposit(alice, 2 * ONE_BTC);
        _deployIdle();

        assertApproxEqRel(aaveStrat.positionValue(), (ONE_BTC * 9) / 10, 0.01e18);
        assertApproxEqRel(rotStrat.positionValue(), (ONE_BTC * 9) / 10, 0.01e18);

        _tend(address(rotStrat));
        _movePriceBps(Mainnet.WBTC, 40);
        _skipTime(2 hours);
        _tendAll();

        assertEq(uint256(rotStrat.stance()), uint256(RotationStrategy.Stance.HoldQuote));

        uint256 balBefore = IERC20(Mainnet.WBTC).balanceOf(alice);
        _withdraw(alice, ONE_BTC / 2);
        assertEq(IERC20(Mainnet.WBTC).balanceOf(alice) - balBefore, ONE_BTC / 2);
    }
}
