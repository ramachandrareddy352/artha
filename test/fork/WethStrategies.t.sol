// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {Mainnet} from "../helpers/Addresses.sol";
import {AaveV3WethStrategy} from "../../src/strategies/weth/lend/AaveV3WethStrategy.sol";
import {CompoundV3WethStrategy} from "../../src/strategies/weth/lend/CompoundV3WethStrategy.sol";
import {LidoWstEthStrategy} from "../../src/strategies/weth/staking/LidoWstEthStrategy.sol";

interface IWstEthLive {
    function getStETHByWstETH(uint256 amount) external view returns (uint256);
}

contract WethStrategiesForkTest is ForkBase {
    AaveV3WethStrategy internal aaveStrat;
    CompoundV3WethStrategy internal cometStrat;
    LidoWstEthStrategy internal lidoStrat;

    function setUp() public {
        if (!_forkOrSkip()) return;

        _deployVault(Mainnet.WETH, 1_000, 5_000);
        _registerFeed(Mainnet.WETH, Mainnet.CHAINLINK_ETH_USD);

        address[] memory noRewards = new address[](0);
        aaveStrat = new AaveV3WethStrategy(
            address(vault),
            Mainnet.WETH,
            address(priceFeed),
            address(uniSwapper),
            Mainnet.AAVE_V3_POOL,
            Mainnet.AAVE_A_WETH,
            Mainnet.AAVE_REWARDS_CONTROLLER,
            noRewards
        );

        cometStrat = new CompoundV3WethStrategy(
            address(vault),
            Mainnet.WETH,
            address(priceFeed),
            address(uniSwapper),
            Mainnet.COMET_WETH,
            Mainnet.COMET_REWARDS,
            Mainnet.COMP
        );

        lidoStrat = new LidoWstEthStrategy(
            address(vault), Mainnet.WETH, address(priceFeed), address(uniSwapper), Mainnet.WSTETH
        );

        _give(Mainnet.WETH, alice, 10_000e18);
        _give(Mainnet.WETH, bob, 10_000e18);
    }

    function _wireLidoRoutes() internal {
        bytes memory buy = abi.encodePacked(Mainnet.WETH, uint24(100), Mainnet.WSTETH);
        bytes memory sell = abi.encodePacked(Mainnet.WSTETH, uint24(100), Mainnet.WETH);
        _exec(address(lidoStrat), abi.encodeCall(lidoStrat.setRoutes, (buy, sell)));
        _exec(address(lidoStrat), abi.encodeCall(lidoStrat.setMaxSlippageBps, (500)));
    }

    function test_aaveSuppliesRealWeth() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);
        _deposit(alice, 1_000e18);
        _deployIdle();

        assertApproxEqRel(aaveStrat.positionValue(), 900e18, 0.001e18);

        uint256 before = aaveStrat.positionValue();
        _skipTime(30 days);
        assertGt(aaveStrat.positionValue(), before);
    }

    function test_cometWethMarketAccruesInterest() public {
        _addSingleStrategy(address(cometStrat), 9_000, 1_000);
        _deposit(alice, 1_000e18);
        _deployIdle();

        uint256 before = cometStrat.positionValue();
        assertApproxEqRel(before, 900e18, 0.001e18);

        _skipTime(30 days);
        assertGt(cometStrat.positionValue(), before);
    }

    function test_lidoBuysRealWstEthAndHoldsItInTheVault() public {
        _addSingleStrategy(address(lidoStrat), 9_000, 1_000);
        _wireLidoRoutes();
        _deposit(alice, 100e18);
        _deployIdle();

        assertGt(IERC20(Mainnet.WSTETH).balanceOf(address(vault)), 0);
        assertEq(IERC20(Mainnet.WSTETH).balanceOf(address(lidoStrat)), 0);
        assertApproxEqRel(lidoStrat.positionValue(), 90e18, 0.02e18);
    }

    function test_lidoValuesByTheNativeRateWhenNoMarketPriceIsConfigured() public {
        _addSingleStrategy(address(lidoStrat), 9_000, 1_000);
        _wireLidoRoutes();
        _deposit(alice, 100e18);
        _deployIdle();

        uint256 wstHeld = IERC20(Mainnet.WSTETH).balanceOf(address(vault));
        uint256 nativeValue = IWstEthLive(Mainnet.WSTETH).getStETHByWstETH(wstHeld);
        assertEq(lidoStrat.positionValue(), nativeValue);

        (uint256 nativeOne, uint256 marketOne) = lidoStrat.valuationSpread();
        assertGt(nativeOne, 1e18);
        assertEq(marketOne, 0);
    }

    function test_lidoRoundTripThroughRealLiquidity() public {
        _addSingleStrategy(address(lidoStrat), 9_000, 1_000);
        _wireLidoRoutes();
        _deposit(alice, 100e18);
        _deployIdle();

        uint256 balBefore = IERC20(Mainnet.WETH).balanceOf(alice);
        _withdraw(alice, 50e18);

        assertEq(IERC20(Mainnet.WETH).balanceOf(alice) - balBefore, 50e18);
        assertGt(IERC20(Mainnet.WSTETH).balanceOf(address(vault)), 0);
    }

    function test_lidoAndLendingSideBySideWithUserChurn() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);

        address[] memory two = new address[](2);
        two[0] = address(aaveStrat);
        two[1] = address(lidoStrat);
        uint16[] memory w = new uint16[](2);
        w[0] = 4_500;
        w[1] = 4_500;
        _addStrategy(address(lidoStrat), two, w, 1_000);
        _wireLidoRoutes();

        _deposit(alice, 200e18);
        _deployIdle();

        assertApproxEqRel(aaveStrat.positionValue(), 90e18, 0.01e18);
        assertApproxEqRel(lidoStrat.positionValue(), 90e18, 0.02e18);

        _skipTime(30 days);
        _deposit(bob, 100e18);
        _settle();

        uint256 balBefore = IERC20(Mainnet.WETH).balanceOf(alice);
        _withdraw(alice, 100e18);
        assertEq(IERC20(Mainnet.WETH).balanceOf(alice) - balBefore, 100e18);
    }
}
