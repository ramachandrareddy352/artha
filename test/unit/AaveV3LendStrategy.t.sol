// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {AaveV3LendStrategy} from "../../src/strategies/common/AaveV3LendStrategy.sol";
import {MockERC20, MockOracle, MockSwapper} from "../mocks/Mocks.sol";
import {MockAavePool, MockAToken, MockAaveRewardsController} from "../mocks/MockVenues.sol";

contract AaveV3LendStrategyTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal rewardToken;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockAavePool internal pool;
    MockAToken internal aToken;
    MockAaveRewardsController internal controller;
    AaveV3LendStrategy internal strat;

    address internal vaultAddr = address(0xAA17);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        rewardToken = new MockERC20("Reward", "RWD", 18);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(rewardToken), 10e8);

        pool = new MockAavePool();
        aToken = new MockAToken(address(pool), address(usdc));
        pool.register(address(usdc), address(aToken));

        controller = new MockAaveRewardsController();
        controller.addReward(address(rewardToken));

        address[] memory rewards = new address[](1);
        rewards[0] = address(rewardToken);
        strat = new AaveV3LendStrategy(
            vaultAddr,
            address(usdc),
            address(oracle),
            address(swapper),
            address(pool),
            address(aToken),
            address(controller),
            rewards
        );

        usdc.mint(vaultAddr, 1_000_000e6);
        vm.startPrank(vaultAddr);
        usdc.approve(address(strat), type(uint256).max);
        aToken.approve(address(strat), type(uint256).max);
        vm.stopPrank();
    }

    function _invest(uint256 amount) internal {
        vm.prank(vaultAddr);
        strat.invest(amount);
    }

    function test_receiptIsTheAToken() public view {
        assertEq(strat.receiptToken(), address(aToken));
    }

    function test_investCreditsATokenToTheVaultNotTheStrategy() public {
        _invest(10_000e6);

        assertEq(aToken.balanceOf(vaultAddr), 10_000e6);
        assertEq(aToken.balanceOf(address(strat)), 0);
        assertEq(usdc.balanceOf(address(strat)), 0);
        assertEq(strat.positionValue(), 10_000e6);
    }

    function test_positionValueFollowsRebasingInterest() public {
        _invest(10_000e6);
        aToken.accrue(vaultAddr, 500);

        assertEq(strat.positionValue(), 10_500e6);
    }

    function test_divestReturnsRequestedAmountToVault() public {
        _invest(10_000e6);
        uint256 before = usdc.balanceOf(vaultAddr);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(4_000e6);

        assertEq(withdrawn, 4_000e6);
        assertEq(usdc.balanceOf(vaultAddr) - before, 4_000e6);
        assertEq(strat.positionValue(), 6_000e6);
    }

    function test_divestCapsAtPosition() public {
        _invest(1_000e6);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(50_000e6);

        assertEq(withdrawn, 1_000e6);
        assertEq(strat.positionValue(), 0);
    }

    function test_divestOfNothingIsANoop() public {
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(1_000e6);
        assertEq(withdrawn, 0);
    }

    function test_emergencyWithdrawUnwindsEverythingIncludingInterest() public {
        _invest(10_000e6);
        aToken.accrue(vaultAddr, 1_000);
        usdc.mint(address(aToken), 1_000e6);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.emergencyWithdraw();

        assertEq(withdrawn, 11_000e6);
        assertEq(usdc.balanceOf(vaultAddr) - before, 11_000e6);
        assertEq(strat.positionValue(), 0);
    }

    function test_maxWithdrawIsBoundedByReserveLiquidity() public {
        _invest(10_000e6);
        assertEq(strat.maxWithdraw(), 10_000e6);

        pool.drainLiquidity(address(usdc), 7_000e6);
        assertEq(strat.maxWithdraw(), 3_000e6);
    }

    function test_divestRevertsWhenReserveIsPaused() public {
        _invest(10_000e6);
        pool.setPaused(true);

        vm.prank(vaultAddr);
        vm.expectRevert(bytes("RESERVE_PAUSED"));
        strat.divest(1_000e6);
    }

    function test_rewardsAreIgnoredUntilWeAreTheRegisteredClaimer() public {
        _invest(10_000e6);
        controller.accrue(vaultAddr, address(rewardToken), 100e18);

        assertEq(strat.pendingRewardsValue(), 0);

        vm.prank(vaultAddr);
        uint256 realized = strat.harvest();
        assertEq(realized, 0);
    }

    function test_rewardsCountAndSellOnceWeAreTheClaimer() public {
        _invest(10_000e6);
        controller.setClaimer(vaultAddr, address(strat));
        controller.accrue(vaultAddr, address(rewardToken), 100e18);

        uint256 gross = 100 * 10e6;
        assertEq(strat.pendingRewardsValue(), (gross * 9_800) / 10_000);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 realized = strat.harvest();

        assertEq(realized, gross);
        assertEq(usdc.balanceOf(vaultAddr) - before, gross);
        assertEq(strat.pendingRewardsValue(), 0);
    }

    function test_allUnclaimedRewardsView() public {
        controller.setClaimer(vaultAddr, address(strat));
        controller.accrue(vaultAddr, address(rewardToken), 7e18);

        (address[] memory list, uint256[] memory amounts) = strat.allUnclaimedRewards();
        assertEq(list.length, 1);
        assertEq(list[0], address(rewardToken));
        assertEq(amounts[0], 7e18);
    }

    function test_controllerCanBeUnset() public {
        vm.prank(vaultAddr);
        strat.setRewardsController(address(0));

        assertEq(strat.pendingRewardsValue(), 0);
        vm.prank(vaultAddr);
        assertEq(strat.harvest(), 0);

        (address[] memory list,) = strat.allUnclaimedRewards();
        assertEq(list.length, 0);
    }

    function test_supplyRateIsExposed() public view {
        assertEq(strat.supplyRateRay(), 3e25);
    }

    function test_configIsVaultOnly() public {
        vm.expectRevert(bytes("NOT_VAULT"));
        strat.setRewardsController(address(1));
    }

    function testFuzz_investThenFullDivestIsLossless(uint96 amount) public {
        amount = uint96(bound(amount, 1e6, 500_000e6));
        _invest(amount);

        uint256 before = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(amount);

        assertEq(withdrawn, amount);
        assertEq(usdc.balanceOf(vaultAddr) - before, amount);
        assertEq(strat.positionValue(), 0);
    }

    function testFuzz_divestNeverExceedsRequestOrPosition(uint96 deposited, uint96 requested) public {
        deposited = uint96(bound(deposited, 1e6, 500_000e6));
        requested = uint96(bound(requested, 1, 1_000_000e6));
        _invest(deposited);

        vm.prank(vaultAddr);
        uint256 withdrawn = strat.divest(requested);

        assertLe(withdrawn, requested);
        assertLe(withdrawn, deposited);
    }
}
