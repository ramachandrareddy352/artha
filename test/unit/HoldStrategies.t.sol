// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {HoldStrategy} from "../../src/strategies/common/HoldStrategy.sol";
import {LidoWstEthStrategy} from "../../src/strategies/weth/staking/LidoWstEthStrategy.sol";
import {MockERC20, MockOracle, MockSwapper} from "../mocks/Mocks.sol";
import {MockWstEth} from "../mocks/MockVenues.sol";

contract HoldStrategyTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    HoldStrategy internal strat;

    address internal vaultAddr = address(0xAA17);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(wbtc), 60_000e8);

        strat = new HoldStrategy(vaultAddr, address(usdc), address(oracle), address(swapper), address(wbtc));

        usdc.mint(vaultAddr, 1_000_000e6);
        vm.startPrank(vaultAddr);
        usdc.approve(address(strat), type(uint256).max);
        wbtc.approve(address(strat), type(uint256).max);
        vm.stopPrank();
    }

    function _invest(uint256 amount) internal {
        vm.prank(vaultAddr);
        strat.invest(amount);
    }

    function test_heldTokenIsTheReceiptAndLivesInTheVault() public {
        _invest(60_000e6);

        assertEq(strat.receiptToken(), address(wbtc));
        assertEq(wbtc.balanceOf(vaultAddr), 1e8);
        assertEq(wbtc.balanceOf(address(strat)), 0);
        assertEq(strat.positionValue(), 60_000e6);
    }

    function test_valueTracksThePrice() public {
        _invest(60_000e6);

        oracle.setPrice(address(wbtc), 90_000e8);
        assertEq(strat.positionValue(), 90_000e6);

        oracle.setPrice(address(wbtc), 30_000e8);
        assertEq(strat.positionValue(), 30_000e6);
    }

    function test_divestAlwaysCoversTheRequestAndOvershootIsBounded() public {
        _invest(60_000e6);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(15_000e6);

        assertGe(withdrawn, 15_000e6);
        assertLe(withdrawn, (15_000e6 * 10_102) / 10_000);
        assertEq(usdc.balanceOf(vaultAddr) - before, withdrawn);
        assertLt(wbtc.balanceOf(vaultAddr), 0.75e8);
    }

    function test_divestGrossesUpSoTheVaultGetsWhatItAsked() public {
        _invest(60_000e6);
        swapper.setFeeBps(50);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(15_000e6);

        assertGe(withdrawn, 15_000e6);
        assertLt(wbtc.balanceOf(vaultAddr), 0.75e8);
    }

    function test_divestCapsAtVaultHoldings() public {
        _invest(60_000e6);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(500_000e6);

        assertEq(withdrawn, 60_000e6);
        assertEq(wbtc.balanceOf(vaultAddr), 0);
    }

    function test_emergencyWithdrawSellsEverything() public {
        _invest(60_000e6);
        oracle.setPrice(address(wbtc), 70_000e8);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();

        assertEq(withdrawn, 70_000e6);
        assertEq(wbtc.balanceOf(vaultAddr), 0);
        assertEq(strat.positionValue(), 0);
    }

    function test_harvestIsANoop() public {
        _invest(60_000e6);
        vm.prank(vaultAddr);
        assertEq(strat.harvest(), 0);
    }

    function test_investRefusesAFillBelowTheOracleFloor() public {
        swapper.setFeeBps(200);
        vm.prank(vaultAddr);
        vm.expectRevert(bytes("MIN_OUT"));
        strat.invest(60_000e6);
    }

    function test_heldCannotBeTheBaseAsset() public {
        vm.expectRevert(bytes("BAD_HELD"));
        new HoldStrategy(vaultAddr, address(usdc), address(oracle), address(swapper), address(usdc));
    }

    function test_routesAreVaultOnly() public {
        vm.expectRevert(bytes("NOT_VAULT"));
        strat.setRoutes(hex"11", hex"22");

        vm.prank(vaultAddr);
        strat.setRoutes(hex"11", hex"22");
        assertEq(strat.buyRoute(), hex"11");
        assertEq(strat.sellRoute(), hex"22");
    }

    function testFuzz_valuationIsLinearInPrice(uint256 price) public {
        price = bound(price, 1_000e8, 1_000_000e8);
        _invest(60_000e6);

        oracle.setPrice(address(wbtc), price);
        assertApproxEqRel(strat.positionValue(), (price * 1e8) / 1e8 / 100, 0.0001e18);
    }
}

contract LiquidStakingStrategyTest is Test {
    MockERC20 internal weth;
    MockWstEth internal wstEth;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    LidoWstEthStrategy internal strat;

    address internal vaultAddr = address(0xAA17);

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wstEth = new MockWstEth();
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);

        oracle.setPrice(address(weth), 3_000e8);
        oracle.setPrice(address(wstEth), 3_300e8);

        strat = new LidoWstEthStrategy(vaultAddr, address(weth), address(oracle), address(swapper), address(wstEth));

        weth.mint(vaultAddr, 1_000e18);
        vm.startPrank(vaultAddr);
        weth.approve(address(strat), type(uint256).max);
        wstEth.approve(address(strat), type(uint256).max);
        vm.stopPrank();
    }

    function _invest(uint256 amount) internal {
        vm.prank(vaultAddr);
        strat.invest(amount);
    }

    function test_wstEthIsHeldByTheVault() public {
        _invest(11e18);

        assertEq(strat.receiptToken(), address(wstEth));
        assertApproxEqAbs(wstEth.balanceOf(vaultAddr), 10e18, 1);
        assertEq(wstEth.balanceOf(address(strat)), 0);
    }

    function test_valueUsesTheNativeRateWhenMarketAgrees() public {
        _invest(11e18);
        assertApproxEqAbs(strat.positionValue(), 11e18, 1e12);
    }

    function test_yieldShowsUpAsTheRateClimbing() public {
        _invest(11e18);
        uint256 before = strat.positionValue();

        wstEth.accrueBps(400);
        oracle.setPrice(address(wstEth), 3_432e8);

        assertApproxEqRel(strat.positionValue(), (before * 104) / 100, 0.001e18);
    }

    function test_depegMakesValuationTakeTheLowerMarketPrice() public {
        _invest(11e18);
        uint256 nativeValue = strat.positionValue();

        oracle.setPrice(address(wstEth), 3_069e8);
        uint256 depegged = strat.positionValue();

        assertLt(depegged, nativeValue);
        assertApproxEqRel(depegged, (nativeValue * 93) / 100, 0.01e18);
    }

    function test_premiumIsIgnoredSoNavNeverCarriesIt() public {
        _invest(11e18);
        uint256 nativeValue = strat.positionValue();

        oracle.setPrice(address(wstEth), 3_600e8);
        assertEq(strat.positionValue(), nativeValue);
    }

    function test_valuationSurvivesAnUnpricedLst() public {
        _invest(11e18);
        oracle.setReverting(address(wstEth), true);

        assertApproxEqAbs(strat.positionValue(), 11e18, 1e12);
    }

    function test_valuationSpreadIsReported() public view {
        (uint256 nativeValue, uint256 marketValue) = strat.valuationSpread();
        assertEq(nativeValue, 1.1e18);
        assertEq(marketValue, 1.1e18);
    }

    function test_divestSellsWstEthBackToWeth() public {
        _invest(11e18);

        uint256 before = weth.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(5.5e18);

        assertGe(withdrawn, 5.5e18);
        assertApproxEqRel(withdrawn, 5.5e18, 0.02e18);
        assertEq(weth.balanceOf(vaultAddr) - before, withdrawn);
    }

    function test_emergencyWithdrawSellsTheWholePosition() public {
        _invest(11e18);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();

        assertApproxEqRel(withdrawn, 11e18, 0.001e18);
        assertEq(wstEth.balanceOf(vaultAddr), 0);
    }

    function test_harvestIsANoop() public {
        _invest(11e18);
        vm.prank(vaultAddr);
        assertEq(strat.harvest(), 0);
    }

    function testFuzz_conservativeRuleNeverOvervalues(uint256 marketPrice) public {
        marketPrice = bound(marketPrice, 1_500e8, 6_000e8);
        _invest(11e18);

        oracle.setPrice(address(wstEth), marketPrice);

        uint256 nativeValue = (wstEth.balanceOf(vaultAddr) * wstEth.rate()) / 1e18;
        uint256 marketValue = (wstEth.balanceOf(vaultAddr) * marketPrice) / 3_000e8;

        uint256 reported = strat.positionValue();
        assertLe(reported, nativeValue > marketValue ? marketValue : nativeValue);
    }
}
