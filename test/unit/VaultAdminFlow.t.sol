// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultFixture} from "../helpers/VaultFixture.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {DepositFacet} from "../../src/facets/DepositFacet.sol";
import {IStrategy} from "../../src/strategies/interfaces/IStrategy.sol";
import {ERC4626WrapperStrategy} from "../../src/strategies/common/ERC4626WrapperStrategy.sol";
import {MockERC4626} from "../mocks/Mocks.sol";

contract VaultAdminFlowTest is VaultFixture {
    function setUp() public {
        _setUpFixture(1_000, 5_000);
    }

    function test_addStrategyValidatesVaultAndAsset() public {
        ERC4626WrapperStrategy foreign = new ERC4626WrapperStrategy(
            address(0xBEEF), address(usdc), address(oracle), address(swapper), address(venueA)
        );

        address[] memory all = new address[](1);
        all[0] = address(foreign);
        uint16[] memory w = new uint16[](1);
        w[0] = 9_000;

        vm.prank(GOV);
        vm.expectRevert(bytes("STRATEGY_VAULT_MISMATCH"));
        AdminFacet(payable(address(vault))).addStrategy(address(foreign), all, w, 1_000);
    }

    function test_addStrategyRejectsDuplicates() public {
        _addSingleStrategy(address(stratA), 9_000, 1_000);

        address[] memory all = new address[](1);
        all[0] = address(stratA);
        uint16[] memory w = new uint16[](1);
        w[0] = 9_000;

        vm.prank(GOV);
        vm.expectRevert(bytes("ALREADY_ADDED"));
        AdminFacet(payable(address(vault))).addStrategy(address(stratA), all, w, 1_000);
    }

    function test_weightsMustSumToOneHundredPercent() public {
        _addTwoStrategies(5_000, 4_000, 1_000);

        vm.prank(GOV);
        vm.expectRevert(bytes("WEIGHTS_NOT_100"));
        AdminFacet(payable(address(vault))).setTargets(
            _strategiesArray(address(stratA), address(stratB)), _weightsArray(5_000, 4_000), 500
        );

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setTargets(
            _strategiesArray(address(stratA), address(stratB)), _weightsArray(5_000, 4_500), 500
        );
    }

    function test_setTargetsMustCoverEveryRegisteredStrategy() public {
        _addTwoStrategies(5_000, 4_000, 1_000);

        address[] memory one = new address[](1);
        one[0] = address(stratA);
        uint16[] memory w = new uint16[](1);
        w[0] = 9_000;

        vm.prank(GOV);
        vm.expectRevert(bytes("MUST_COVER_ALL_STRATEGIES"));
        AdminFacet(payable(address(vault))).setTargets(one, w, 1_000);
    }

    function test_addingAThirdStrategyMidLifeKeepsExistingPositions() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        MockERC4626 venueC = new MockERC4626(address(usdc));
        ERC4626WrapperStrategy stratC = new ERC4626WrapperStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(venueC)
        );

        address[] memory all = new address[](3);
        all[0] = address(stratA);
        all[1] = address(stratB);
        all[2] = address(stratC);
        uint16[] memory w = new uint16[](3);
        w[0] = 3_000;
        w[1] = 3_000;
        w[2] = 3_000;
        _addStrategy(address(stratC), all, w, 1_000);

        assertEq(stratA.positionValue(), 50_000e6);
        assertEq(stratB.positionValue(), 40_000e6);
        assertEq(_totalAssets(), 100_000e6);

        _rebalance();

        assertApproxEqAbs(stratA.positionValue(), 30_000e6, 10);
        assertApproxEqAbs(stratC.positionValue(), 30_000e6, 10);
    }

    function test_removeStrategyUnwindsToIdleAndDropsIt() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).removeStrategy(address(stratA), 10);

        assertEq(_strategyList().length, 1);
        assertEq(_strategyList()[0], address(stratB));
        assertApproxEqAbs(_idleBalance(), 60_000e6, 10);
        assertApproxEqAbs(_totalAssets(), 100_000e6, 10);
    }

    function test_removeStrategyCarriesAccruedYield() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        venueA.accrueBps(400);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).removeStrategy(address(stratA), 10);

        assertApproxEqAbs(_idleBalance(), 62_000e6, 10);
        assertApproxEqAbs(_totalAssets(), 102_000e6, 10);
    }

    function test_removeStrategyRefusesToStrandValue() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        venueA.setLiquidityCap(1_000e6);

        vm.prank(GOV);
        vm.expectRevert(bytes("EXCEEDS_MAX"));
        AdminFacet(payable(address(vault))).removeStrategy(address(stratA), 10);

        assertEq(_strategyList().length, 2);
        assertEq(stratA.positionValue(), 50_000e6);
    }

    function test_removeStrategyAcceptsAFullyDrainedPosition() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).removeStrategy(address(stratA), 0);

        assertEq(_strategyList().length, 1);
        assertEq(stratA.positionValue(), 0);
    }

    function test_migrateStrategyMovesEverythingAndKeepsTheWeight() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();
        venueA.accrueBps(200);

        MockERC4626 venueC = new MockERC4626(address(usdc));
        ERC4626WrapperStrategy stratC = new ERC4626WrapperStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(venueC)
        );

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).migrateStrategy(address(stratA), address(stratC));

        assertEq(stratA.positionValue(), 0);
        assertApproxEqAbs(stratC.positionValue(), 51_000e6, 10);
        assertEq(ViewFacet(payable(address(vault))).strategyWeightBps(address(stratC)), 5_000);
        assertApproxEqAbs(_totalAssets(), 101_000e6, 10);
    }

    function test_migrateRejectsAMismatchedTarget() public {
        _addSingleStrategy(address(stratA), 9_000, 1_000);
        ERC4626WrapperStrategy foreign = new ERC4626WrapperStrategy(
            address(0xBEEF), address(usdc), address(oracle), address(swapper), address(venueB)
        );

        vm.prank(GOV);
        vm.expectRevert(bytes("STRATEGY_VAULT_MISMATCH"));
        AdminFacet(payable(address(vault))).migrateStrategy(address(stratA), address(foreign));
    }

    function test_disabledStrategyStopsReceivingCapitalButStillPaysOut() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setStrategyDisabled(address(stratA), true);

        _deposit(bob, 100_000e6);
        _deployIdle();

        assertEq(stratA.positionValue(), 50_000e6);
        assertGt(stratB.positionValue(), 40_000e6);

        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, 60_000e6);
        assertEq(usdc.balanceOf(alice) - before, 60_000e6);
    }

    function test_clearCircuitBreakRequiresAnAnchorInBand() public {
        _addTwoStrategies(5_000, 4_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        venueA.accrueBps(9_000);
        _harvestAll();

        (, bool broken,) = _strategyStatus(address(stratA));
        assertTrue(broken);

        uint256 live = stratA.positionValue();

        vm.prank(GOV);
        vm.expectRevert(bytes("ANCHOR_OUT_OF_BAND"));
        AdminFacet(payable(address(vault))).clearStrategyCircuitBreak(address(stratA), live / 2);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).clearStrategyCircuitBreak(address(stratA), live);

        (, bool stillBroken, uint256 lastValue) = _strategyStatus(address(stratA));
        assertFalse(stillBroken);
        assertEq(lastValue, live);
    }

    function test_execOnStrategyReachesConfigSetters() public {
        _addSingleStrategy(address(stratAave), 9_000, 1_000);

        _exec(address(stratAave), abi.encodeCall(stratAave.setMaxSlippageBps, (250)));
        assertEq(stratAave.maxSlippageBps(), 250);

        _exec(address(stratAave), abi.encodeCall(stratAave.registerReward, (address(rewardToken), 5e18)));
        (,,, uint128 minHarvest,) = stratAave.rewards(address(rewardToken));
        assertEq(minHarvest, 5e18);

        _exec(address(stratAave), abi.encodeCall(stratAave.setRewardRoute, (address(rewardToken), hex"c0ffee")));
        assertEq(stratAave.rewardRoute(address(rewardToken)), hex"c0ffee");
    }

    function test_execOnStrategyBlocksTheMoneyMovers() public {
        _addSingleStrategy(address(stratA), 9_000, 1_000);

        vm.startPrank(GOV);
        vm.expectRevert(bytes("USE_VAULT_FLOW"));
        AdminFacet(payable(address(vault))).execOnStrategy(address(stratA), abi.encodeCall(IStrategy.invest, (1e6)));

        vm.expectRevert(bytes("USE_VAULT_FLOW"));
        AdminFacet(payable(address(vault))).execOnStrategy(address(stratA), abi.encodeCall(IStrategy.divest, (1e6)));

        vm.expectRevert(bytes("USE_VAULT_FLOW"));
        AdminFacet(payable(address(vault))).execOnStrategy(address(stratA), abi.encodeCall(IStrategy.harvest, ()));

        vm.expectRevert(bytes("USE_VAULT_FLOW"));
        AdminFacet(payable(address(vault))).execOnStrategy(address(stratA), abi.encodeCall(IStrategy.tend, ()));

        vm.expectRevert(bytes("USE_VAULT_FLOW"));
        AdminFacet(payable(address(vault))).execOnStrategy(
            address(stratA), abi.encodeCall(IStrategy.emergencyWithdraw, ())
        );
        vm.stopPrank();
    }

    function test_execOnStrategyRejectsUnknownTargetsAndNonGovernance() public {
        _addSingleStrategy(address(stratA), 9_000, 1_000);

        vm.prank(GOV);
        vm.expectRevert(bytes("UNKNOWN_STRATEGY"));
        AdminFacet(payable(address(vault))).execOnStrategy(
            address(stratB), abi.encodeCall(stratB.setMaxSlippageBps, (100))
        );

        vm.prank(alice);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        AdminFacet(payable(address(vault))).execOnStrategy(
            address(stratA), abi.encodeCall(stratA.setMaxSlippageBps, (100))
        );
    }

    function test_execOnStrategyBubblesTheStrategysOwnRevert() public {
        _addSingleStrategy(address(stratA), 9_000, 1_000);

        vm.prank(GOV);
        vm.expectRevert(bytes("SLIPPAGE_TOO_HIGH"));
        AdminFacet(payable(address(vault))).execOnStrategy(
            address(stratA), abi.encodeCall(stratA.setMaxSlippageBps, (9_999))
        );
    }

    function test_capsAreEnforcedOnDeposit() public {
        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setCaps(50_000e6, 0, 0, 1_000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("BELOW_MIN_DEPOSIT"));
        DepositFacet(payable(address(vault))).deposit(999e6, alice, 0);

        vm.expectRevert(bytes("TVL_CAP_EXCEEDED"));
        DepositFacet(payable(address(vault))).deposit(60_000e6, alice, 0);

        DepositFacet(payable(address(vault))).deposit(50_000e6, alice, 0);
        vm.stopPrank();
    }

    function test_idleTargetIsCapped() public {
        vm.prank(GOV);
        vm.expectRevert(bytes("IDLE_TOO_HIGH"));
        AdminFacet(payable(address(vault))).setIdleTargetBps(1_001);
    }

    function test_rolesAreGovernanceControlled() public {
        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setKeeper(alice, true);
        assertTrue(ViewFacet(payable(address(vault))).isKeeper(alice));

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setGuardian(bob, true);
        assertTrue(ViewFacet(payable(address(vault))).isGuardian(bob));

        vm.prank(alice);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        AdminFacet(payable(address(vault))).setKeeper(carol, true);
    }

    function test_governanceTransferMovesEveryAdminRight() public {
        address newGov = address(0x9E);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).transferGovernance(newGov);

        vm.prank(GOV);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        AdminFacet(payable(address(vault))).setKeeper(alice, true);

        vm.prank(newGov);
        AdminFacet(payable(address(vault))).setKeeper(alice, true);
        assertTrue(ViewFacet(payable(address(vault))).isKeeper(alice));
    }
}
