// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultHarness} from "../helpers/VaultHarness.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {StrategyFacet} from "../../src/facets/StrategyFacet.sol";
import {EmergencyFacet} from "../../src/facets/EmergencyFacet.sol";
import {ERC4626WrapperStrategy} from "../../src/strategies/common/ERC4626WrapperStrategy.sol";
import {MockERC20, MockOracle, MockSwapper, MockERC4626} from "../mocks/Mocks.sol";

contract GriefingTest is VaultHarness {
    MockERC20 internal usdc;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockERC4626 internal venueA;
    MockERC4626 internal venueB;
    ERC4626WrapperStrategy internal stratA;
    ERC4626WrapperStrategy internal stratB;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);

        _deployVault(address(usdc), 1_000, 5_000);

        venueA = new MockERC4626(address(usdc));
        venueB = new MockERC4626(address(usdc));
        stratA = new ERC4626WrapperStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(venueA)
        );
        stratB = new ERC4626WrapperStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(venueB)
        );

        usdc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 10_000_000e6);
        usdc.mint(carol, 10_000_000e6);
    }

    function _seed() internal {
        _addSingleStrategy(address(stratA), 9_000, 1_000);

        address[] memory two = new address[](2);
        two[0] = address(stratA);
        two[1] = address(stratB);
        uint16[] memory w = new uint16[](2);
        w[0] = 4_500;
        w[1] = 4_500;
        _addStrategy(address(stratB), two, w, 1_000);

        _deposit(alice, 1_000_000e6);
        _deployIdle();
    }

    // ───────────── T6: what a compromised keeper can actually cost ──────────────

    function test_T6_fiftyRebalancesInARowCostHoldersNothing() public {
        _seed();
        uint256 ppsBefore = _pps();

        for (uint256 i; i < 50; ++i) {
            _rebalance();
        }

        assertEq(_pps(), ppsBefore);
    }

    function test_T6_alternatingReweightAndRebalanceCostsHoldersNothing() public {
        _seed();
        uint256 ppsBefore = _pps();

        address[] memory two = new address[](2);
        two[0] = address(stratA);
        two[1] = address(stratB);

        for (uint256 i; i < 20; ++i) {
            uint16[] memory w = new uint16[](2);
            w[0] = i % 2 == 0 ? 8_000 : 1_000;
            w[1] = i % 2 == 0 ? 1_000 : 8_000;
            _setTargets(two, w, 1_000);
            _rebalance();
        }

        assertEq(_pps(), ppsBefore);
    }

    function test_T6_repeatedHarvestAndTendCostHoldersNothing() public {
        _seed();
        uint256 ppsBefore = _pps();

        for (uint256 i; i < 50; ++i) {
            _harvestAll();
            _tendAll();
        }

        assertEq(_pps(), ppsBefore);
    }

    function test_T6_aKeeperCannotMoveValueToAnyAddressButTheVault() public {
        _seed();
        uint256 keeperBefore = usdc.balanceOf(KEEPER);

        for (uint256 i; i < 10; ++i) {
            _rebalance();
            _harvestAll();
            _deployIdle();
        }

        assertEq(usdc.balanceOf(KEEPER), keeperBefore);
        assertEq(_shareToken().balanceOf(KEEPER), 0);
    }

    // ──────── permissionless spam cannot move state that matters ────────────────

    function test_N2_spammingSettleCannotTripABreakerOrMoveTheAnchor() public {
        _seed();
        (,, uint256 anchorBefore) = _strategyStatus(address(stratA));

        venueA.accrueBps(4_000);
        for (uint256 i; i < 50; ++i) {
            vm.prank(address(uint160(0x1000 + i)));
            StrategyFacet(payable(address(vault))).settle();
        }

        (, bool broken, uint256 anchorAfter) = _strategyStatus(address(stratA));
        assertFalse(broken);
        assertEq(anchorAfter, anchorBefore);
        assertFalse(ViewFacet(payable(address(vault))).vaultConfig().paused);
    }

    function test_N3_walkingAValueUpThroughSettleAloneNeverMovesTheAnchor() public {
        _seed();
        (,, uint256 anchorBefore) = _strategyStatus(address(stratA));

        for (uint256 i; i < 20; ++i) {
            venueA.accrueBps(400);
            _settle();
        }

        (,, uint256 anchorAfter) = _strategyStatus(address(stratA));
        assertEq(anchorAfter, anchorBefore);
    }

    function test_S2_spammingSyncCannotInflateTheLedger() public {
        _seed();
        uint256 idleBefore = _idleBalance();

        for (uint256 i; i < 50; ++i) {
            vm.prank(address(uint160(0x2000 + i)));
            EmergencyFacet(payable(address(vault))).sync();
        }

        assertEq(_idleBalance(), idleBefore);
        assertLe(_idleBalance(), usdc.balanceOf(address(vault)));
    }

    function test_M6_dustDepositSpamDoesNotDegradeTheVault() public {
        _seed();
        uint256 ppsBefore = _pps();

        for (uint256 i; i < 100; ++i) {
            _deposit(carol, 1e6);
        }

        assertApproxEqRel(_pps(), ppsBefore, 0.0001e18);

        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, 100_000e6);
        assertEq(usdc.balanceOf(alice) - before, 100_000e6);
    }

    // ────────────── E6: the emergency exit's unwind escalation ──────────────────

    function test_E6_aTinyEmergencyExitDoesNotUnwindTheWholeVault() public {
        _seed();
        _pause();

        uint256 aBefore = stratA.positionValue();
        uint256 bBefore = stratB.positionValue();
        assertGt(aBefore, 0);
        assertGt(bBefore, 0);

        uint256 oneShare = _shareToken().balanceOf(alice) / 1_000_000;
        _emergencyWithdraw(alice, oneShare);

        assertEq(stratA.positionValue(), aBefore);
        assertEq(stratB.positionValue(), bBefore);
    }

    function test_E6_anEmergencyExitTakesOnlyTheBoundedAmountItNeeds() public {
        _seed();
        _pause();

        uint256 bBefore = stratB.positionValue();
        uint256 shares = _shareToken().balanceOf(alice) / 10;
        _emergencyWithdraw(alice, shares);

        assertEq(stratB.positionValue(), bBefore);
        assertGt(stratA.positionValue(), 0);
    }

    function test_E6_escalationToAFullUnwindOnlyHappensWhenBoundedDivestCannotPay() public {
        _seed();
        venueA.setRevertOnWithdraw(true);
        _pause();

        uint256 shares = _shareToken().balanceOf(alice) / 2;
        uint256 before = usdc.balanceOf(alice);
        _emergencyWithdraw(alice, shares);

        assertGt(usdc.balanceOf(alice) - before, 0);
        assertLe(_idleBalance(), usdc.balanceOf(address(vault)));
    }

    // ───────────── a breaker trip costs the attacker real capital ───────────────

    function test_N3_trippingTheBreakerRequiresARealVenueMove() public {
        _seed();

        venueA.accrueBps(1_000);
        _harvestAll();
        (, bool brokenSmall,) = _strategyStatus(address(stratA));
        assertFalse(brokenSmall);

        venueA.accrueBps(6_000);
        _harvestAll();
        (, bool brokenBig,) = _strategyStatus(address(stratA));
        assertTrue(brokenBig);
    }

    // ──────────── a fully degraded vault still lets holders out ─────────────────

    function test_E4_everyVenueRevertingStillLeavesTheEmergencyExitOpen() public {
        _seed();
        venueA.setRevertOnWithdraw(true);
        venueB.setRevertOnWithdraw(true);
        _pause();

        uint256 before = usdc.balanceOf(alice);
        _emergencyWithdraw(alice, _shareToken().balanceOf(alice) / 2);

        assertGt(usdc.balanceOf(alice) - before, 0);
    }

    function test_A5_governanceRetainsAPathOutOfAFullyStuckVault() public {
        _seed();
        venueA.setRevertOnConvert(true);
        _harvestAll();

        (, bool broken,) = _strategyStatus(address(stratA));
        assertTrue(broken);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).removeStrategy(address(stratA), type(uint256).max);

        assertEq(_strategyList().length, 1);
        assertEq(_strategyList()[0], address(stratB));
    }
}
