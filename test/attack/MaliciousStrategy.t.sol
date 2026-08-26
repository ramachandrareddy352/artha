// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultHarness} from "../helpers/VaultHarness.sol";
import {EvilStrategy} from "./EvilStrategy.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {StrategyFacet} from "../../src/facets/StrategyFacet.sol";
import {ERC4626WrapperStrategy} from "../../src/strategies/common/ERC4626WrapperStrategy.sol";
import {MockERC20, MockOracle, MockSwapper, MockERC4626} from "../mocks/Mocks.sol";

contract MaliciousStrategyTest is VaultHarness {
    MockERC20 internal usdc;
    MockOracle internal oracle;
    MockSwapper internal swapper;

    MockERC4626 internal goodVenue;
    ERC4626WrapperStrategy internal good;
    EvilStrategy internal evil;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);

        _deployVault(address(usdc), 1_000, 5_000);

        goodVenue = new MockERC4626(address(usdc));
        good = new ERC4626WrapperStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(goodVenue)
        );
        evil = new EvilStrategy(address(vault), address(usdc));

        usdc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 10_000_000e6);
    }

    function _addBoth(uint16 goodBps, uint16 evilBps) internal {
        _addSingleStrategy(address(good), 9_000, 1_000);

        address[] memory two = new address[](2);
        two[0] = address(good);
        two[1] = address(evil);
        uint16[] memory w = new uint16[](2);
        w[0] = goodBps;
        w[1] = evilBps;
        _addStrategy(address(evil), two, w, 1_000);
    }

    function _seed(uint256 amount) internal {
        _addBoth(4_500, 4_500);
        _deposit(alice, amount);
        _deployIdle();
    }

    // ═══════════════════ lying about value ═══════════════════

    function test_N1_maxUint256ValuationTripsTheBreakerAndIsNeverPaidOut() public {
        _seed(100_000e6);
        uint256 navBefore = _totalAssets();

        evil.setValueMode(EvilStrategy.ValueMode.Max);
        _harvestAll();

        (, bool broken, uint256 lastValue) = _strategyStatus(address(evil));
        assertTrue(broken);
        assertEq(lastValue, 45_000e6);
        assertEq(_totalAssets(), navBefore);
    }

    function test_N1_doubledValuationTripsTheBreakerBeforeAnyoneCanRedeemAgainstIt() public {
        _seed(100_000e6);
        uint256 claimBefore = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));

        evil.setValueMode(EvilStrategy.ValueMode.Double);
        _harvestAll();

        (, bool broken,) = _strategyStatus(address(evil));
        assertTrue(broken);

        uint256 claimAfter = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));
        assertApproxEqAbs(claimAfter, claimBefore, 2);
    }

    function test_N1_collapsedValuationTripsTheBreakerRatherThanRacingHoldersOut() public {
        _seed(100_000e6);

        evil.setValueMode(EvilStrategy.ValueMode.Zero);
        _harvestAll();

        (, bool broken, uint256 lastValue) = _strategyStatus(address(evil));
        assertTrue(broken);
        assertEq(lastValue, 45_000e6);
        assertTrue(ViewFacet(payable(address(vault))).vaultConfig().paused);
    }

    function test_O4_revertingValuationBreaksTheStrategyAndPausesTheVault() public {
        _seed(100_000e6);

        evil.setValueMode(EvilStrategy.ValueMode.Revert);
        _harvestAll();

        (, bool broken,) = _strategyStatus(address(evil));
        assertTrue(broken);
        assertTrue(ViewFacet(payable(address(vault))).vaultConfig().paused);
    }

    function test_O4_emergencyExitStillWorksWhenTheEvilStrategyCannotBePriced() public {
        _seed(100_000e6);

        evil.setValueMode(EvilStrategy.ValueMode.Revert);
        _harvestAll();

        uint256 before = usdc.balanceOf(alice);
        _emergencyWithdraw(alice, _shareToken().balanceOf(alice));

        assertGt(usdc.balanceOf(alice) - before, 50_000e6);
    }

    function test_N1_gasBombInValuationCannotStallTheVault() public {
        _seed(100_000e6);

        evil.setValueMode(EvilStrategy.ValueMode.GasBomb);
        _harvestAll();

        (, bool broken,) = _strategyStatus(address(evil));
        assertTrue(broken);
    }

    // ═══════════════════ refusing to give money back ═══════════════════

    function test_W3_evilStrategyRevertingOnDivestCannotBlockAWithdrawal() public {
        _seed(100_000e6);
        evil.setMisbehaviour(EvilStrategy.Misbehaviour.RevertOnDivest);

        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, 50_000e6);

        assertEq(usdc.balanceOf(alice) - before, 50_000e6);
    }

    function test_T3_divestThatPaysNothingCreditsNothing() public {
        _seed(100_000e6);
        evil.setMisbehaviour(EvilStrategy.Misbehaviour.DivestWithoutPaying);

        uint256 idleBefore = _idleBalance();
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));

        vm.prank(alice);
        try WithdrawFacet(payable(address(vault))).withdraw(60_000e6, alice, alice, type(uint256).max) {} catch {}

        assertLe(_idleBalance(), usdc.balanceOf(address(vault)));
        assertLe(usdc.balanceOf(address(vault)), vaultBalBefore + idleBefore);
    }

    function test_T3_divestThatUnderpaysCreditsOnlyWhatArrived() public {
        _seed(100_000e6);
        evil.setMisbehaviour(EvilStrategy.Misbehaviour.DivestUnderpay);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(KEEPER);
        try StrategyFacet(payable(address(vault))).rebalance() {} catch {}

        assertLe(_idleBalance(), usdc.balanceOf(address(vault)));
        assertGe(usdc.balanceOf(address(vault)), vaultBefore);
    }

    function test_E4_emergencyExitSurvivesAStrategyThatRefusesToUnwind() public {
        _seed(100_000e6);
        evil.setMisbehaviour(EvilStrategy.Misbehaviour.RevertOnEmergency);
        _pause();

        uint256 before = usdc.balanceOf(alice);
        _emergencyWithdraw(alice, _shareToken().balanceOf(alice));

        assertGt(usdc.balanceOf(alice) - before, 0);
    }

    function test_A5_governanceCanStillRetireAnUnwindableStrategy() public {
        _seed(100_000e6);
        evil.setValueMode(EvilStrategy.ValueMode.Revert);
        _harvestAll();

        (, bool broken,) = _strategyStatus(address(evil));
        assertTrue(broken);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).removeStrategy(address(evil), type(uint256).max);

        assertEq(_strategyList().length, 1);
        assertEq(_strategyList()[0], address(good));
    }

    // ═══════════════════ reentrancy ═══════════════════

    function test_R_reentrantDepositDuringInvestIsBlocked() public {
        _addBoth(4_500, 4_500);
        _deposit(alice, 100_000e6);

        evil.setMisbehaviour(EvilStrategy.Misbehaviour.ReenterDepositOnInvest);
        usdc.mint(address(evil), 10_000e6);
        vm.prank(address(evil));
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(KEEPER);
        vm.expectRevert();
        StrategyFacet(payable(address(vault))).deployIdle();
    }

    function test_R_reentrantWithdrawDuringDivestIsBlocked() public {
        _seed(100_000e6);
        evil.setMisbehaviour(EvilStrategy.Misbehaviour.ReenterWithdrawOnDivest);

        uint256 supplyBefore = _shareToken().totalSupply();

        vm.prank(alice);
        try WithdrawFacet(payable(address(vault))).withdraw(60_000e6, alice, alice, type(uint256).max) {} catch {}

        assertLe(_shareToken().totalSupply(), supplyBefore);
        assertLe(_idleBalance(), usdc.balanceOf(address(vault)));
    }

    function test_R_reentrantHarvestDuringHarvestIsBlocked() public {
        _seed(100_000e6);
        evil.setMisbehaviour(EvilStrategy.Misbehaviour.ReenterHarvestOnHarvest);

        vm.prank(KEEPER);
        vm.expectRevert();
        StrategyFacet(payable(address(vault))).harvest(address(evil));
    }

    // ═══════════════════ the receipt-allowance surface ═══════════════════

    function test_A5_aStrategyClaimingAnotherStrategysReceiptIsRejectedAtRegistration() public {
        _addSingleStrategy(address(good), 9_000, 1_000);

        evil.setFakeReceipt(address(goodVenue));

        address[] memory two = new address[](2);
        two[0] = address(good);
        two[1] = address(evil);
        uint16[] memory w = new uint16[](2);
        w[0] = 4_500;
        w[1] = 4_500;

        vm.prank(GOV);
        vm.expectRevert(bytes("RECEIPT_COLLISION"));
        AdminFacet(payable(address(vault))).addStrategy(address(evil), two, w, 1_000);

        assertEq(_strategyList().length, 1);
    }

    function test_A5_aStrategyClaimingTheBaseAssetAsReceiptIsRejected() public {
        evil.setFakeReceipt(address(usdc));

        address[] memory one = new address[](1);
        one[0] = address(evil);
        uint16[] memory w = new uint16[](1);
        w[0] = 9_000;

        vm.prank(GOV);
        vm.expectRevert(bytes("RECEIPT_IS_BASE_ASSET"));
        AdminFacet(payable(address(vault))).addStrategy(address(evil), one, w, 1_000);
    }

    function test_A5_aStrategyClaimingTheShareTokenAsReceiptIsRejected() public {
        evil.setFakeReceipt(address(_shareToken()));

        address[] memory one = new address[](1);
        one[0] = address(evil);
        uint16[] memory w = new uint16[](1);
        w[0] = 9_000;

        vm.prank(GOV);
        vm.expectRevert(bytes("RECEIPT_IS_SHARE_TOKEN"));
        AdminFacet(payable(address(vault))).addStrategy(address(evil), one, w, 1_000);
    }

    function test_A5_twoHonestStrategiesOverTheSameVenueAreRejected() public {
        _addSingleStrategy(address(good), 9_000, 1_000);

        ERC4626WrapperStrategy twin = new ERC4626WrapperStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(goodVenue)
        );

        address[] memory two = new address[](2);
        two[0] = address(good);
        two[1] = address(twin);
        uint16[] memory w = new uint16[](2);
        w[0] = 4_500;
        w[1] = 4_500;

        vm.prank(GOV);
        vm.expectRevert(bytes("RECEIPT_COLLISION"));
        AdminFacet(payable(address(vault))).addStrategy(address(twin), two, w, 1_000);
    }

    function test_A5_internalLedgerStrategiesMayCoexist() public {
        EvilStrategy second = new EvilStrategy(address(vault), address(usdc));

        _addSingleStrategy(address(evil), 9_000, 1_000);

        address[] memory two = new address[](2);
        two[0] = address(evil);
        two[1] = address(second);
        uint16[] memory w = new uint16[](2);
        w[0] = 4_500;
        w[1] = 4_500;
        _addStrategy(address(second), two, w, 1_000);

        assertEq(_strategyList().length, 2);
    }

    function test_A5_migrationToTheSameVenueIsStillAllowed() public {
        _addSingleStrategy(address(good), 9_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        ERC4626WrapperStrategy replacement = new ERC4626WrapperStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(goodVenue)
        );

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).migrateStrategy(address(good), address(replacement));

        assertEq(_strategyList()[0], address(replacement));
        assertApproxEqAbs(replacement.positionValue(), 90_000e6, 10);
    }

    function test_N1_freshlyAddedStrategyReportingHugeValueCannotBrickTheVault() public {
        _addSingleStrategy(address(good), 9_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        evil.setValueMode(EvilStrategy.ValueMode.Max);

        address[] memory two = new address[](2);
        two[0] = address(good);
        two[1] = address(evil);
        uint16[] memory w = new uint16[](2);
        w[0] = 4_500;
        w[1] = 4_500;
        _addStrategy(address(evil), two, w, 1_000);

        _settle();
        assertLe(_totalAssets(), 1e30);

        _harvestAll();
        (, bool broken,) = _strategyStatus(address(evil));
        assertTrue(broken);
        _unpause();

        uint256 before = usdc.balanceOf(alice);
        _withdraw(alice, 10_000e6);
        assertEq(usdc.balanceOf(alice) - before, 10_000e6);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).removeStrategy(address(evil), type(uint256).max);
        assertEq(_strategyList().length, 1);
    }

    function test_N1_anUnfundedStrategyCannotPoisonNavWithAModestLie() public {
        _addSingleStrategy(address(good), 9_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        uint256 navBefore = _totalAssets();
        uint256 claimBefore = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));

        // Well under the 2^128 ceiling, so ONLY the never-funded rule can catch it.
        evil.setValueMode(EvilStrategy.ValueMode.Honest);
        evil.setBookedValue(500_000e6);

        address[] memory two = new address[](2);
        two[0] = address(good);
        two[1] = address(evil);
        uint16[] memory w = new uint16[](2);
        w[0] = 4_500;
        w[1] = 4_500;
        _addStrategy(address(evil), two, w, 1_000);

        _settle();
        assertApproxEqAbs(_totalAssets(), navBefore, 4);
        assertApproxEqAbs(
            ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice)), claimBefore, 4
        );

        _harvestAll();
        (, bool broken,) = _strategyStatus(address(evil));
        assertTrue(broken);
    }

    function test_N1_anUnfundedStrategyReportingValueIsTreatedAsSuspicious() public {
        _addSingleStrategy(address(good), 9_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();

        evil.setValueMode(EvilStrategy.ValueMode.Honest);

        address[] memory two = new address[](2);
        two[0] = address(good);
        two[1] = address(evil);
        uint16[] memory w = new uint16[](2);
        w[0] = 4_500;
        w[1] = 4_500;
        _addStrategy(address(evil), two, w, 1_000);

        (, bool brokenBefore,) = _strategyStatus(address(evil));
        assertFalse(brokenBefore);

        uint256 navBefore = _totalAssets();
        _deployIdle();
        assertApproxEqAbs(_totalAssets(), navBefore, 10);
        (, bool brokenAfter,) = _strategyStatus(address(evil));
        assertFalse(brokenAfter);
    }

    function test_A5_receiptAllowanceIsZeroOutsideACall() public {
        MockERC4626 evilVenue = new MockERC4626(address(usdc));
        evil.setFakeReceipt(address(evilVenue));
        _seed(100_000e6);

        _withdraw(alice, 20_000e6);

        assertEq(goodVenue.allowance(address(vault), address(evil)), 0);
        assertEq(goodVenue.allowance(address(vault), address(good)), 0);
        assertEq(evilVenue.allowance(address(vault), address(evil)), 0);
    }

    // ═══════════════════ the blast-radius bound ═══════════════════

    function test_BLASTRADIUS_evilStrategyCannotExceedItsOwnAllocation() public {
        _seed(100_000e6);

        uint256 evilAllocation = 45_000e6;
        uint256 goodPosition = good.positionValue();
        uint256 idle = _idleBalance();

        evil.setValueMode(EvilStrategy.ValueMode.Max);
        evil.setMisbehaviour(EvilStrategy.Misbehaviour.RevertOnDivest);
        _harvestAll();

        assertEq(good.positionValue(), goodPosition);
        assertEq(_idleBalance(), idle);
        assertEq(usdc.balanceOf(address(evil)), evilAllocation);
        assertEq(goodVenue.balanceOf(address(evil)), 0);
    }

    function test_BLASTRADIUS_honestHoldersStillRecoverEverythingElse() public {
        _seed(100_000e6);

        evil.setValueMode(EvilStrategy.ValueMode.Revert);
        evil.setMisbehaviour(EvilStrategy.Misbehaviour.RevertOnEmergency);
        _harvestAll();

        uint256 before = usdc.balanceOf(alice);
        _emergencyWithdraw(alice, _shareToken().balanceOf(alice));
        uint256 recovered = usdc.balanceOf(alice) - before;

        assertGe(recovered, 54_000e6);
    }

    function test_S2_ledgerNeverClaimsMoreCustodyThanExistsUnderAttack() public {
        _seed(100_000e6);

        evil.setValueMode(EvilStrategy.ValueMode.Max);
        _harvestAll();
        assertLe(_idleBalance(), usdc.balanceOf(address(vault)));

        evil.setMisbehaviour(EvilStrategy.Misbehaviour.DivestWithoutPaying);
        vm.prank(alice);
        try WithdrawFacet(payable(address(vault))).withdraw(10_000e6, alice, alice, type(uint256).max) {} catch {}

        assertLe(_idleBalance(), usdc.balanceOf(address(vault)));
    }
}
