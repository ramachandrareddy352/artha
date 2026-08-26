// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultHarness} from "../helpers/VaultHarness.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {ERC4626WrapperStrategy} from "../../src/strategies/common/ERC4626WrapperStrategy.sol";
import {MockERC20, MockOracle, MockSwapper, MockERC4626} from "../mocks/Mocks.sol";

contract PerformanceFeeTest is VaultHarness {
    MockERC20 internal usdc;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockERC4626 internal venue;
    ERC4626WrapperStrategy internal strat;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);

        _deployVault(address(usdc), 1_000, 10_000);
        venue = new MockERC4626(address(usdc));
        strat =
            new ERC4626WrapperStrategy(address(vault), address(usdc), address(oracle), address(swapper), address(venue));

        usdc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 10_000_000e6);
    }

    function _setFee(uint16 bps) internal {
        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setPerformanceFee(bps);
    }

    function _seed(uint256 amount) internal {
        _addSingleStrategy(address(strat), 9_000, 1_000);
        _deposit(alice, amount);
        _deployIdle();
    }

    function _treasuryShares() internal view returns (uint256) {
        return _shareToken().balanceOf(TREASURY);
    }

    function _hwm() internal view returns (uint256) {
        return ViewFacet(payable(address(vault))).vaultConfig().highWaterMarkPps;
    }

    // ───────────────────────── N6: charged once per peak ────────────────────────

    function test_N6_feeIsMintedOnNewProfitOnly() public {
        _setFee(2_000);
        _seed(100_000e6);
        assertEq(_treasuryShares(), 0);

        venue.accrueBps(1_000);
        _harvestAll();

        assertGt(_treasuryShares(), 0);
    }

    function test_N6_noFeeWithoutProfit() public {
        _setFee(2_000);
        _seed(100_000e6);

        _harvestAll();
        _harvestAll();
        _settle();

        assertEq(_treasuryShares(), 0);
    }

    function test_N6_dipAndRecoverToTheSamePeakIsNotChargedTwice() public {
        _setFee(2_000);
        _seed(100_000e6);

        venue.accrueBps(1_000);
        _harvestAll();
        uint256 feeAfterFirstPeak = _treasuryShares();
        uint256 markAfterFirstPeak = _hwm();
        assertGt(feeAfterFirstPeak, 0);

        venue.setRate(1.0e18);
        _harvestAll();
        assertEq(_treasuryShares(), feeAfterFirstPeak);

        venue.setRate(1.1e18);
        _harvestAll();

        assertEq(_treasuryShares(), feeAfterFirstPeak);
        assertEq(_hwm(), markAfterFirstPeak);
    }

    function test_N6_onlyTheIncrementAboveTheOldPeakIsCharged() public {
        _setFee(2_000);
        _seed(100_000e6);

        venue.accrueBps(1_000);
        _harvestAll();
        uint256 firstFee = _treasuryShares();

        venue.accrueBps(1_000);
        _harvestAll();
        uint256 secondFee = _treasuryShares() - firstFee;

        assertGt(secondFee, 0);
        assertApproxEqRel(secondFee, firstFee, 0.2e18);
    }

    function test_N6_markStillRatchetsWhenTheFeeIsZero() public {
        _setFee(0);
        _seed(100_000e6);

        uint256 markBefore = _hwm();
        venue.accrueBps(2_000);
        _harvestAll();

        assertGt(_hwm(), markBefore);
        assertEq(_treasuryShares(), 0);

        _setFee(2_000);
        _harvestAll();
        assertEq(_treasuryShares(), 0);
    }

    // ───────────────────── N7: dilution never robs a holder ─────────────────────

    function test_N7_feeDilutionNeverReducesAHoldersClaimBelowTheirPreProfitClaim() public {
        _setFee(2_000);
        _seed(100_000e6);

        uint256 claimBefore = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));

        venue.accrueBps(1_000);
        _harvestAll();

        uint256 claimAfter = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));
        assertGt(claimAfter, claimBefore);
    }

    function test_N7_holderKeepsRoughlyTheirShareOfProfitAfterTheFee() public {
        _setFee(2_000);
        _seed(100_000e6);

        uint256 claimBefore = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));

        venue.accrueBps(1_000);
        _harvestAll();

        uint256 claimAfter = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));
        uint256 grossProfit = 9_000e6;
        uint256 userProfit = claimAfter - claimBefore;

        assertApproxEqRel(userProfit, (grossProfit * 8_000) / 10_000, 0.05e18);
    }

    function testFuzz_N7_feeNeverTakesMoreThanItsBpsOfProfit(uint16 feeBps, uint16 yieldBps) public {
        uint256 fee = bound(feeBps, 0, 3_000);
        uint256 yield_ = bound(yieldBps, 1, 2_000);

        _setFee(uint16(fee));
        _seed(100_000e6);

        uint256 claimBefore = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));
        uint256 navBefore = _totalAssets();

        venue.accrueBps(yield_);
        _harvestAll();

        uint256 claimAfter = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice));
        assertGe(claimAfter, claimBefore);

        uint256 navAfter = _totalAssets();
        assertGe(navAfter, navBefore);
        uint256 grossProfit = navAfter - navBefore;

        uint256 treasuryClaim =
            _treasuryShares() == 0 ? 0 : ViewFacet(payable(address(vault))).previewRedeem(_treasuryShares());

        assertLe(treasuryClaim, (grossProfit * fee) / 10_000 + 1e6);
    }

    // ───────────────── N8: plain flows never crystallize a fee ──────────────────

    function test_N8_depositsAloneNeverMintAFee() public {
        _setFee(2_000);
        _seed(100_000e6);

        for (uint256 i; i < 20; ++i) {
            _deposit(bob, 1_000e6);
        }

        assertEq(_treasuryShares(), 0);
    }

    function test_N8_withdrawalsAloneNeverMintAFee() public {
        _setFee(2_000);
        _seed(100_000e6);

        for (uint256 i; i < 10; ++i) {
            _withdraw(alice, 1_000e6);
        }

        assertEq(_treasuryShares(), 0);
    }

    function test_N8_aDepositAfterProfitDoesNotChargeTheNewDepositor() public {
        _setFee(2_000);
        _seed(100_000e6);

        venue.accrueBps(1_000);
        _harvestAll();
        uint256 feeAfterProfit = _treasuryShares();

        uint256 bobShares = _deposit(bob, 50_000e6);
        assertEq(_treasuryShares(), feeAfterProfit);

        uint256 bobClaim = ViewFacet(payable(address(vault))).previewRedeem(bobShares);
        assertApproxEqRel(bobClaim, 50_000e6, 0.001e18);
    }

    // ────────────────── N9: an unset treasury defers, never bricks ──────────────

    function test_N9_theSetterRefusesToUnsetTheTreasury() public {
        vm.prank(GOV);
        vm.expectRevert(bytes("ZERO_ADDRESS"));
        AdminFacet(payable(address(vault))).setTreasury(address(0));
    }

    function test_N9_unsetTreasuryDefersTheFeeWithoutBrickingAnything() public {
        _deployVaultWithTreasury(address(usdc), 1_000, 10_000, address(0));
        venue = new MockERC4626(address(usdc));
        strat =
            new ERC4626WrapperStrategy(address(vault), address(usdc), address(oracle), address(swapper), address(venue));
        _setFee(2_000);

        _seed(100_000e6);
        venue.accrueBps(1_000);

        _harvestAll();
        _deposit(bob, 10_000e6);
        _withdraw(alice, 10_000e6);

        assertEq(_treasuryShares(), 0);
        assertGt(_hwm(), 0);
    }

    function test_N9_settingTheTreasuryLaterDoesNotRetroactivelyCharge() public {
        _deployVaultWithTreasury(address(usdc), 1_000, 10_000, address(0));
        venue = new MockERC4626(address(usdc));
        strat =
            new ERC4626WrapperStrategy(address(vault), address(usdc), address(oracle), address(swapper), address(venue));
        _setFee(2_000);

        _seed(100_000e6);
        venue.accrueBps(1_000);
        _harvestAll();

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setTreasury(TREASURY);
        _harvestAll();

        assertEq(_treasuryShares(), 0);
    }

    // ─────────────────────────── bounds and access ──────────────────────────────

    function test_A1_feeIsCappedAndGovernanceOnly() public {
        vm.prank(GOV);
        vm.expectRevert(bytes("FEE_TOO_HIGH"));
        AdminFacet(payable(address(vault))).setPerformanceFee(3_001);

        _setFee(3_000);

        vm.prank(alice);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        AdminFacet(payable(address(vault))).setPerformanceFee(100);
    }

    function test_N6_raisingTheFeeDoesNotChargeOnAlreadyMarkedProfit() public {
        _setFee(0);
        _seed(100_000e6);

        venue.accrueBps(2_000);
        _harvestAll();
        assertEq(_treasuryShares(), 0);

        _setFee(3_000);
        _harvestAll();
        assertEq(_treasuryShares(), 0);

        venue.accrueBps(500);
        _harvestAll();
        assertGt(_treasuryShares(), 0);
    }

    function test_S1_solvencyHoldsAfterFeeMinting() public {
        _setFee(2_000);
        _seed(100_000e6);

        venue.accrueBps(1_500);
        _harvestAll();

        uint256 claims = ViewFacet(payable(address(vault))).previewRedeem(_shareToken().balanceOf(alice))
            + ViewFacet(payable(address(vault))).previewRedeem(_treasuryShares());

        assertLe(claims, _totalAssets());
    }
}
