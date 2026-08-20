// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "../helpers/ForkBase.sol";
import {Mainnet} from "../helpers/Addresses.sol";
import {AaveV3UsdtStrategy} from "../../src/strategies/usdt/lend/AaveV3UsdtStrategy.sol";
import {CompoundV3UsdtStrategy} from "../../src/strategies/usdt/lend/CompoundV3UsdtStrategy.sol";

contract UsdtStrategiesForkTest is ForkBase {
    AaveV3UsdtStrategy internal aaveStrat;
    CompoundV3UsdtStrategy internal cometStrat;

    function setUp() public {
        if (!_forkOrSkip()) return;

        _deployVault(Mainnet.USDT, 1_000, 5_000);
        _registerFeed(Mainnet.USDT, Mainnet.CHAINLINK_USDT_USD);
        _registerFeedAt(Mainnet.COMP, 50e8);

        address[] memory noRewards = new address[](0);
        aaveStrat = new AaveV3UsdtStrategy(
            address(vault),
            Mainnet.USDT,
            address(priceFeed),
            address(uniSwapper),
            Mainnet.AAVE_V3_POOL,
            Mainnet.AAVE_A_USDT,
            Mainnet.AAVE_REWARDS_CONTROLLER,
            noRewards
        );

        cometStrat = new CompoundV3UsdtStrategy(
            address(vault),
            Mainnet.USDT,
            address(priceFeed),
            address(uniSwapper),
            Mainnet.COMET_USDT,
            Mainnet.COMET_REWARDS,
            Mainnet.COMP
        );

        _give(Mainnet.USDT, alice, 5_000_000e6);
        _give(Mainnet.USDT, bob, 5_000_000e6);
    }

    function test_nonStandardUsdtApproveIsHandled() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e6);
        _deployIdle();

        assertApproxEqRel(aaveStrat.positionValue(), 900_000e6, 0.001e18);
        assertApproxEqRel(IERC20(Mainnet.AAVE_A_USDT).balanceOf(address(vault)), 900_000e6, 0.001e18);
    }

    function test_aaveUsdtAccruesRealInterest() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e6);
        _deployIdle();

        uint256 before = aaveStrat.positionValue();
        _skipTime(30 days);
        assertGt(aaveStrat.positionValue(), before);

        _settle();
        assertGt(_totalAssets(), 1_000_000e6);
    }

    function test_cometUsdtMarketAccruesInterest() public {
        _addSingleStrategy(address(cometStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e6);
        _deployIdle();

        uint256 before = cometStrat.positionValue();
        assertApproxEqRel(before, 900_000e6, 0.001e18);

        _skipTime(30 days);
        assertGt(cometStrat.positionValue(), before);
    }

    function test_usdtWithdrawalRoundTrip() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);
        _deposit(alice, 1_000_000e6);
        _deployIdle();

        _skipTime(60 days);
        _settle();

        uint256 balBefore = IERC20(Mainnet.USDT).balanceOf(alice);
        _redeem(alice, _shareToken().balanceOf(alice));
        assertGt(IERC20(Mainnet.USDT).balanceOf(alice) - balBefore, 1_000_000e6);
    }

    function test_bothUsdtVenuesWithRebalanceAndChurn() public {
        _addSingleStrategy(address(aaveStrat), 9_000, 1_000);

        address[] memory two = new address[](2);
        two[0] = address(aaveStrat);
        two[1] = address(cometStrat);
        uint16[] memory w = new uint16[](2);
        w[0] = 4_500;
        w[1] = 4_500;
        _addStrategy(address(cometStrat), two, w, 1_000);

        _deposit(alice, 1_000_000e6);
        _deployIdle();
        _skipTime(30 days);

        _deposit(bob, 500_000e6);
        _rebalance();
        _withdraw(alice, 300_000e6);

        assertApproxEqRel(
            aaveStrat.positionValue() + cometStrat.positionValue() + _idleBalance(), _totalAssets(), 0.001e18
        );
    }
}
