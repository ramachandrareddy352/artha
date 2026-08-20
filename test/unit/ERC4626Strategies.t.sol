// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ERC4626WrapperStrategy} from "../../src/strategies/common/ERC4626WrapperStrategy.sol";
import {CrossAssetERC4626Strategy} from "../../src/strategies/common/CrossAssetERC4626Strategy.sol";
import {BeefyStrategy} from "../../src/strategies/common/BeefyStrategy.sol";
import {MockERC20, MockOracle, MockSwapper, MockERC4626} from "../mocks/Mocks.sol";
import {MockBeefyVault} from "../mocks/MockVenues.sol";

contract ERC4626WrapperStrategyTest is Test {
    MockERC20 internal usdc;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockERC4626 internal target;
    ERC4626WrapperStrategy internal strat;

    address internal vaultAddr = address(0xAA17);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);
        target = new MockERC4626(address(usdc));

        strat = new ERC4626WrapperStrategy(vaultAddr, address(usdc), address(oracle), address(swapper), address(target));

        usdc.mint(vaultAddr, 1_000_000e6);
        vm.startPrank(vaultAddr);
        usdc.approve(address(strat), type(uint256).max);
        target.approve(address(strat), type(uint256).max);
        vm.stopPrank();
    }

    function _invest(uint256 amount) internal {
        vm.prank(vaultAddr);
        strat.invest(amount);
    }

    function test_sharesAreCustodiedByTheVault() public {
        _invest(10_000e6);

        assertEq(target.balanceOf(vaultAddr), 10_000e6);
        assertEq(target.balanceOf(address(strat)), 0);
        assertEq(strat.receiptToken(), address(target));
        assertEq(strat.positionValue(), 10_000e6);
    }

    function test_valueRisesWithSharePrice() public {
        _invest(10_000e6);
        target.accrueBps(700);

        assertEq(strat.positionValue(), 10_700e6);
    }

    function test_valueFallsOnVenueLoss() public {
        _invest(10_000e6);
        target.setRate(0.9e18);

        assertEq(strat.positionValue(), 9_000e6);
    }

    function test_divestBurnsVaultSharesAndPaysTheVault() public {
        _invest(10_000e6);
        target.accrueBps(1_000);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(5_000e6);

        assertEq(withdrawn, 5_000e6);
        assertEq(usdc.balanceOf(vaultAddr) - before, 5_000e6);
        assertApproxEqAbs(strat.positionValue(), 6_000e6, 1);
    }

    function test_divestIsCappedByVenueLiquidity() public {
        _invest(10_000e6);
        target.setLiquidityCap(3_000e6);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(10_000e6);

        assertEq(withdrawn, 3_000e6);
        assertEq(strat.maxWithdraw(), 3_000e6);
    }

    function test_emergencyWithdrawRedeemsEverything() public {
        _invest(10_000e6);
        target.accrueBps(500);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();

        assertEq(withdrawn, 10_500e6);
        assertEq(target.balanceOf(vaultAddr), 0);
        assertEq(strat.positionValue(), 0);
    }

    function test_harvestIsANoop() public {
        _invest(10_000e6);
        vm.prank(vaultAddr);
        assertEq(strat.harvest(), 0);
    }

    function test_constructorRejectsAssetMismatch() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        vm.expectRevert(bytes("ASSET_MISMATCH"));
        new ERC4626WrapperStrategy(vaultAddr, address(dai), address(oracle), address(swapper), address(target));
    }

    function testFuzz_roundTripLosesNothingButRounding(uint96 amount) public {
        amount = uint96(bound(amount, 1e6, 500_000e6));
        _invest(amount);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();

        assertApproxEqAbs(withdrawn, amount, 1);
    }
}

contract CrossAssetERC4626StrategyTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal usde;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockERC4626 internal sUsde;
    CrossAssetERC4626Strategy internal strat;

    address internal vaultAddr = address(0xAA17);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usde = new MockERC20("Ethena USD", "USDe", 18);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(usde), 1e8);
        sUsde = new MockERC4626(address(usde));

        strat = new CrossAssetERC4626Strategy(
            vaultAddr, address(usdc), address(oracle), address(swapper), address(sUsde), address(usde)
        );

        usdc.mint(vaultAddr, 1_000_000e6);
        vm.startPrank(vaultAddr);
        usdc.approve(address(strat), type(uint256).max);
        sUsde.approve(address(strat), type(uint256).max);
        vm.stopPrank();
    }

    function _invest(uint256 amount) internal {
        vm.prank(vaultAddr);
        strat.invest(amount);
    }

    function test_investSwapsAndCustodiesSharesInTheVault() public {
        _invest(10_000e6);

        assertEq(sUsde.balanceOf(vaultAddr), 10_000e18);
        assertEq(usdc.balanceOf(address(strat)), 0);
        assertEq(usde.balanceOf(address(strat)), 0);
        assertEq(strat.positionValue(), 10_000e6);
    }

    function test_valueConvertsThroughTheOracle() public {
        _invest(10_000e6);
        sUsde.accrueBps(1_000);
        assertEq(strat.positionValue(), 11_000e6);

        oracle.setPrice(address(usde), 0.95e8);
        assertEq(strat.positionValue(), 10_450e6);
    }

    function test_divestSellsIntermediateBackToBase() public {
        _invest(10_000e6);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(4_000e6);

        assertEq(withdrawn, 4_000e6);
        assertEq(usdc.balanceOf(vaultAddr) - before, 4_000e6);
        assertApproxEqAbs(strat.positionValue(), 6_000e6, 1);
    }

    function test_emergencyWithdrawUnwindsBothLegs() public {
        _invest(10_000e6);
        sUsde.accrueBps(200);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();

        assertEq(withdrawn, 10_200e6);
        assertEq(sUsde.balanceOf(vaultAddr), 0);
    }

    function test_investRevertsWhenSwapCannotClearTheOracleFloor() public {
        swapper.setFeeBps(200);
        vm.prank(vaultAddr);
        vm.expectRevert(bytes("MIN_OUT"));
        strat.invest(10_000e6);
    }

    function test_valuationRevertsWithoutAPrice() public {
        _invest(10_000e6);
        oracle.setReverting(address(usde), true);

        vm.expectRevert(bytes("ORACLE_DOWN"));
        strat.positionValue();
    }

    function test_constructorRejectsIntermediateMismatch() public {
        vm.expectRevert(bytes("ASSET_MISMATCH"));
        new CrossAssetERC4626Strategy(
            vaultAddr, address(usdc), address(oracle), address(swapper), address(sUsde), address(usdc)
        );
    }
}

contract BeefyStrategyTest is Test {
    MockERC20 internal usdc;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockBeefyVault internal beefy;
    BeefyStrategy internal strat;

    address internal vaultAddr = address(0xAA17);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);
        beefy = new MockBeefyVault(address(usdc));

        strat = new BeefyStrategy(vaultAddr, address(usdc), address(oracle), address(swapper), address(beefy));

        usdc.mint(vaultAddr, 1_000_000e6);
        vm.startPrank(vaultAddr);
        usdc.approve(address(strat), type(uint256).max);
        beefy.approve(address(strat), type(uint256).max);
        vm.stopPrank();
    }

    function _invest(uint256 amount) internal {
        vm.prank(vaultAddr);
        strat.invest(amount);
    }

    function test_mooSharesEndUpInTheVault() public {
        _invest(10_000e6);

        assertEq(beefy.balanceOf(vaultAddr), 10_000e6);
        assertEq(beefy.balanceOf(address(strat)), 0);
        assertEq(strat.positionValue(), 10_000e6);
    }

    function test_valueTracksPricePerFullShare() public {
        _invest(10_000e6);
        beefy.accrueBps(1_500);

        assertEq(strat.positionValue(), 11_500e6);
    }

    function test_divestPullsSharesFromTheVault() public {
        _invest(10_000e6);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(3_000e6);

        assertEq(withdrawn, 3_000e6);
        assertEq(usdc.balanceOf(vaultAddr) - before, 3_000e6);
    }

    function test_emergencyWithdrawRedeemsAll() public {
        _invest(10_000e6);
        beefy.accrueBps(100);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();

        assertEq(withdrawn, 10_100e6);
        assertEq(beefy.balanceOf(vaultAddr), 0);
    }

    function test_constructorRejectsWantMismatch() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        vm.expectRevert(bytes("WANT_MISMATCH"));
        new BeefyStrategy(vaultAddr, address(dai), address(oracle), address(swapper), address(beefy));
    }
}
