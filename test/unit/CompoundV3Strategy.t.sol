// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {CompoundV3Strategy} from "../../src/strategies/common/CompoundV3Strategy.sol";
import {MockERC20, MockOracle, MockSwapper} from "../mocks/Mocks.sol";
import {MockComet, MockCometRewards, MockCometRewardsLegacy} from "../mocks/MockVenues.sol";

contract CompoundV3StrategyTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal comp;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockComet internal comet;
    MockCometRewards internal cometRewards;
    CompoundV3Strategy internal strat;

    address internal vaultAddr = address(0xAA17);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        comp = new MockERC20("Compound", "COMP", 18);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(comp), 40e8);

        comet = new MockComet(address(usdc));
        cometRewards = new MockCometRewards(address(comp));

        strat = new CompoundV3Strategy(
            vaultAddr,
            address(usdc),
            address(oracle),
            address(swapper),
            address(comet),
            address(cometRewards),
            address(comp)
        );

        usdc.mint(vaultAddr, 1_000_000e6);
        vm.prank(vaultAddr);
        usdc.approve(address(strat), type(uint256).max);
    }

    function _invest(uint256 amount) internal {
        vm.prank(vaultAddr);
        strat.invest(amount);
    }

    function test_hasNoReceiptTokenForTheVault() public view {
        assertEq(strat.receiptToken(), address(0));
    }

    function test_strategyIsTheRegisteredSupplier() public {
        _invest(10_000e6);

        assertEq(comet.balanceOf(address(strat)), 10_000e6);
        assertEq(comet.balanceOf(vaultAddr), 0);
        assertEq(strat.positionValue(), 10_000e6);
    }

    function test_positionValueFollowsInterest() public {
        _invest(10_000e6);
        comet.accrue(address(strat), 300);

        assertEq(strat.positionValue(), 10_300e6);
    }

    function test_divestReturnsBaseToTheVault() public {
        _invest(10_000e6);
        uint256 before = usdc.balanceOf(vaultAddr);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(2_500e6);

        assertEq(withdrawn, 2_500e6);
        assertEq(usdc.balanceOf(vaultAddr) - before, 2_500e6);
        assertEq(strat.positionValue(), 7_500e6);
    }

    function test_divestCapsAtPosition() public {
        _invest(1_000e6);
        vm.prank(vaultAddr);
        assertEq(strat.divest(9_000e6), 1_000e6);
    }

    function test_emergencyWithdrawUnwindsFully() public {
        _invest(10_000e6);
        comet.accrue(address(strat), 500);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();

        assertEq(withdrawn, 10_500e6);
        assertEq(strat.positionValue(), 0);
    }

    function test_maxWithdrawIsBoundedByMarketLiquidity() public {
        _invest(10_000e6);
        assertEq(strat.maxWithdraw(), 10_000e6);

        comet.drainLiquidity(6_000e6);
        assertEq(strat.maxWithdraw(), 4_000e6);
    }

    function test_divestRevertsWhenMarketIsPaused() public {
        _invest(10_000e6);
        comet.setWithdrawPaused(true);

        vm.prank(vaultAddr);
        vm.expectRevert(bytes("WITHDRAW_PAUSED"));
        strat.divest(1e6);
    }

    function test_pendingCompIsReconstructedFromAccrual() public {
        _invest(10_000e6);
        comet.accrueRewards(address(strat), 1_000_000);

        uint256 compAmount = 1e18;
        uint256 gross = 40e6;
        assertEq(strat.pendingRewardsValue(), (gross * 9_800) / 10_000);
        assertEq(strat.pendingRewardAmount(address(comp)), compAmount);
    }

    function test_harvestClaimsAndSellsComp() public {
        _invest(10_000e6);
        comet.accrueRewards(address(strat), 1_000_000);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 realized = strat.harvest();

        assertEq(realized, 40e6);
        assertEq(usdc.balanceOf(vaultAddr) - before, 40e6);
        assertEq(strat.pendingRewardsValue(), 0);
    }

    function test_alreadyClaimedRewardsAreNotDoubleCounted() public {
        _invest(10_000e6);
        comet.accrueRewards(address(strat), 1_000_000);

        vm.prank(vaultAddr);
        strat.harvest();

        assertEq(strat.pendingRewardAmount(address(comp)), 0);

        comet.accrueRewards(address(strat), 500_000);
        assertEq(strat.pendingRewardAmount(address(comp)), 0.5e18);
    }

    function test_threeFieldRewardConfigIsDecodedNotReverted() public {
        MockCometRewardsLegacy legacy = new MockCometRewardsLegacy(address(comp));
        CompoundV3Strategy legacyStrat = new CompoundV3Strategy(
            vaultAddr, address(usdc), address(oracle), address(swapper), address(comet), address(legacy), address(comp)
        );

        vm.prank(vaultAddr);
        usdc.approve(address(legacyStrat), type(uint256).max);
        vm.prank(vaultAddr);
        legacyStrat.invest(10_000e6);

        comet.accrueRewards(address(legacyStrat), 1_000_000);

        assertEq(legacyStrat.pendingRewardAmount(address(comp)), 1e18);
        assertEq(legacyStrat.pendingRewardsValue(), (40e6 * 9_800) / 10_000);
        assertGt(legacyStrat.positionValue(), 10_000e6);

        vm.prank(vaultAddr);
        assertEq(legacyStrat.harvest(), 40e6);
    }

    function test_unreadableRewardsModuleUnderReportsInsteadOfReverting() public {
        _invest(10_000e6);
        comet.accrueRewards(address(strat), 1_000_000);
        cometRewards.setLegacyLayout(true);

        assertEq(strat.pendingRewardsValue(), 0);
        assertEq(strat.positionValue(), 10_000e6);
    }

    function test_constructorRejectsMismatchedBase() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        vm.expectRevert(bytes("BASE_MISMATCH"));
        new CompoundV3Strategy(
            vaultAddr,
            address(dai),
            address(oracle),
            address(swapper),
            address(comet),
            address(cometRewards),
            address(comp)
        );
    }

    function test_supplyRateIsExposed() public view {
        assertEq(strat.supplyRatePerSecond(), 1e9);
    }

    function testFuzz_roundTripIsLossless(uint96 amount) public {
        amount = uint96(bound(amount, 1e6, 500_000e6));
        _invest(amount);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(amount);

        assertEq(withdrawn, amount);
        assertEq(usdc.balanceOf(vaultAddr) - before, amount);
        assertEq(strat.positionValue(), 0);
    }
}
