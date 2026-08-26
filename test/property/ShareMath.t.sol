// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultHarness} from "../helpers/VaultHarness.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {DepositFacet} from "../../src/facets/DepositFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {MockERC20, FeeOnTransferToken} from "../mocks/Mocks.sol";

contract ShareMathPropertyTest is VaultHarness {
    MockERC20 internal token;

    function setUp() public {
        token = new MockERC20("Base", "BASE", 6);
        _deployVault(address(token), 1_000, 10_000);
        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    function _fund(address who) internal {
        token.mint(who, 1_000_000_000e6);
    }

    function _view() internal view returns (ViewFacet) {
        return ViewFacet(payable(address(vault)));
    }

    function _mint(address who, uint256 shares, uint256 maxAssetsIn) internal returns (uint256 assets) {
        vm.startPrank(who);
        token.approve(address(vault), type(uint256).max);
        assets = DepositFacet(payable(address(vault))).mint(shares, who, maxAssetsIn);
        vm.stopPrank();
    }

    function _donate(uint256 amount) internal {
        token.mint(address(vault), amount);
        _sync();
    }

    function _donateFrom(address who, uint256 amount) internal {
        vm.prank(who);
        token.transfer(address(vault), amount);
        _sync();
    }

    // ─────────────────────────── M1: rounding direction ─────────────────────────

    function test_M1_depositRoundsSharesDown() public {
        _deposit(alice, 1_000e6);
        _donate(333e6);

        uint256 previewed = _view().previewDeposit(7);
        uint256 actual = _deposit(bob, 7);
        assertEq(actual, previewed);

        uint256 exact = (uint256(7) * (_shareToken().totalSupply() + 1e6)) / (_totalAssets() + 1);
        assertLe(actual, exact);
    }

    function test_M1_mintRoundsAssetsUp() public {
        _deposit(alice, 1_000e6);
        _donate(333e6);

        uint256 previewed = _view().previewMint(1e12);
        uint256 actual = _mint(bob, 1e12, type(uint256).max);
        assertEq(actual, previewed);
        assertGe(actual, 1);
    }

    function test_M1_withdrawRoundsSharesUp() public {
        _deposit(alice, 1_000e6);
        _donate(333e6);

        uint256 previewed = _view().previewWithdraw(7);
        uint256 burned = _withdraw(alice, 7);
        assertEq(burned, previewed);

        uint256 exact = (uint256(7) * (_shareToken().totalSupply() + 1e6)) / (_totalAssets() + 1);
        assertGe(burned, exact);
    }

    function test_M1_redeemRoundsAssetsDown() public {
        uint256 shares = _deposit(alice, 1_000e6);
        _donate(333e6);

        uint256 previewed = _view().previewRedeem(shares / 3);
        uint256 got = _redeem(alice, shares / 3);
        assertEq(got, previewed);
    }

    // ──────────────────── M2/M3: round trips never profit ───────────────────────

    function test_M2_depositThenRedeemNeverReturnsMore() public {
        _deposit(alice, 500_000e6);

        uint256 before = token.balanceOf(bob);
        uint256 shares = _deposit(bob, 12_345e6);
        _redeem(bob, shares);

        assertLe(token.balanceOf(bob), before);
    }

    function testFuzz_M2_depositThenRedeemNeverReturnsMore(uint96 seed, uint96 amount) public {
        uint256 seeded = bound(seed, 1e6, 100_000_000e6);
        amount = uint96(bound(amount, 1, 100_000_000e6));
        _deposit(alice, seeded);

        uint256 before = token.balanceOf(bob);
        uint256 shares = _deposit(bob, amount);
        if (shares == 0) return;
        _redeem(bob, shares);

        assertLe(token.balanceOf(bob), before);
    }

    function testFuzz_M3_mintThenWithdrawBurnsAtLeastWhatWasMinted(uint96 seed, uint64 shares) public {
        uint256 seeded = bound(seed, 1e6, 100_000_000e6);
        uint256 wanted = bound(shares, 1e6, 1e18);
        _deposit(alice, seeded);

        uint256 assetsPaid = _mint(bob, wanted, type(uint256).max);
        if (assetsPaid == 0) return;

        assertGe(_view().previewWithdraw(assetsPaid), wanted);
    }

    function testFuzz_M3_mintThenRedeemAllNeverReturnsMoreThanPaid(uint96 seed, uint64 shares) public {
        uint256 seeded = bound(seed, 1e6, 100_000_000e6);
        uint256 wanted = bound(shares, 1e6, 1e18);
        _deposit(alice, seeded);

        uint256 before = token.balanceOf(bob);
        uint256 assetsPaid = _mint(bob, wanted, type(uint256).max);
        if (assetsPaid == 0) return;

        _redeem(bob, _shareToken().balanceOf(bob));
        assertLe(token.balanceOf(bob), before);
    }

    function test_M3_doubleRoundingMeansYouCannotWithdrawExactlyWhatYouPaid() public {
        _deposit(alice, 1_000e6);
        _donate(333e6);

        uint256 assetsPaid = _mint(bob, 1e12, type(uint256).max);
        uint256 sharesHeld = _shareToken().balanceOf(bob);

        assertEq(sharesHeld, 1e12);
        assertGt(_view().previewWithdraw(assetsPaid), sharesHeld);

        vm.prank(bob);
        vm.expectRevert();
        WithdrawFacet(payable(address(vault))).withdraw(assetsPaid, bob, bob, type(uint256).max);
    }

    function testFuzz_M4_roundTripAcrossNavAndDonations(uint96 seed, uint96 donation, uint96 amount) public {
        uint256 seeded = bound(seed, 1e6, 10_000_000e6);
        uint256 donated = bound(donation, 0, 10_000_000e6);
        amount = uint96(bound(amount, 1e6, 10_000_000e6));

        _deposit(alice, seeded);
        if (donated != 0) _donate(donated);

        uint256 before = token.balanceOf(bob);
        uint256 shares = _deposit(bob, amount);
        if (shares == 0) return;
        _redeem(bob, shares);

        assertLe(token.balanceOf(bob), before);
    }

    // ───────────────── M5: the first depositor cannot be zeroed ─────────────────

    function test_M5_donationBeforeFirstDepositDoesNotZeroTheDepositor() public {
        _donate(10_000e6);
        assertEq(_shareToken().totalSupply(), 0);
        assertEq(_totalAssets(), 10_000e6);

        uint256 shares = _deposit(alice, 1_000e6);
        assertGt(shares, 0);

        uint256 claim = _view().previewRedeem(shares);
        assertGt(claim, 0);
    }

    function testFuzz_M5_firstDepositorAboveDustAlwaysGetsShares(uint96 donation, uint96 deposited) public {
        uint256 donated = bound(donation, 0, 100_000_000e6);
        uint256 amount = bound(deposited, 1e6, 100_000_000e6);
        vm.assume(amount * 1e6 > donated);

        if (donated != 0) _donate(donated);

        uint256 shares = _deposit(alice, amount);
        assertGt(shares, 0);
        assertGt(_view().previewRedeem(shares), 0);
    }

    function test_M5_aLargeDonationBlocksDustDepositsRatherThanZeroMinting() public {
        _donate(8_000_000e6);

        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("ZERO_SHARES"));
        DepositFacet(payable(address(vault))).deposit(2e6, alice, 0);
        vm.stopPrank();

        uint256 shares = _deposit(alice, 10e6);
        assertGt(shares, 0);
    }

    function test_M5_donationToAnEmptyVaultIsAbsorbedByTheVirtualOffset() public {
        uint256 donorBefore = token.balanceOf(carol);
        _donateFrom(carol, 50_000e6);

        uint256 shares = _deposit(alice, 1_000e6);
        uint256 claim = _view().previewRedeem(shares);

        assertApproxEqRel(claim, 1_000e6, 0.001e18);
        assertLt(token.balanceOf(carol), donorBefore);
    }

    function test_M5_donationToASeededVaultReachesHolders() public {
        _deposit(bob, 100_000e6);
        uint256 claimBefore = _view().previewRedeem(_shareToken().balanceOf(bob));

        _donateFrom(carol, 10_000e6);

        uint256 claimAfter = _view().previewRedeem(_shareToken().balanceOf(bob));
        assertApproxEqRel(claimAfter, claimBefore + 10_000e6, 0.001e18);
    }

    function test_M5_inflationAttackIsNotProfitable() public {
        uint256 attackerBefore = token.balanceOf(alice);

        _deposit(alice, 1);
        _donateFrom(alice, 100_000e6);

        uint256 victimShares = _deposit(bob, 10_000e6);
        assertGt(victimShares, 0);

        _redeem(alice, _shareToken().balanceOf(alice));
        assertLt(token.balanceOf(alice), attackerBefore);
    }

    function test_M5_inflationAttackCostsTheAttackerFarMoreThanItExtracts() public {
        uint256 attackerBefore = token.balanceOf(alice);
        uint256 victimBefore = token.balanceOf(bob);

        _deposit(alice, 1);
        _donateFrom(alice, 100_000e6);

        uint256 victimShares = _deposit(bob, 10_000e6);
        _redeem(bob, victimShares);
        _redeem(alice, _shareToken().balanceOf(alice));

        uint256 victimLoss = victimBefore - token.balanceOf(bob);
        uint256 attackerLoss = attackerBefore - token.balanceOf(alice);

        assertLe(victimLoss, (10_000e6 * 1) / 10_000);
        assertGt(attackerLoss, victimLoss);
    }

    // ──────────────── M6: grinding small operations extracts nothing ────────────

    function test_M6_repeatedDustRoundTripsDrainTheAttackerNotTheVault() public {
        _deposit(bob, 1_000_000e6);
        _donate(7_777e6);

        uint256 before = token.balanceOf(alice);
        for (uint256 i; i < 200; ++i) {
            uint256 shares = _deposit(alice, 1e6);
            if (shares == 0) break;
            _redeem(alice, shares);
        }
        assertLe(token.balanceOf(alice), before);
    }

    function test_M6_repeatedMintRedeemGrindingIsNotProfitable() public {
        _deposit(bob, 1_000_000e6);
        _donate(3_333e6);

        uint256 before = token.balanceOf(alice);
        for (uint256 i; i < 100; ++i) {
            uint256 paid = _mint(alice, 1e12, type(uint256).max);
            if (paid == 0) break;
            _redeem(alice, _shareToken().balanceOf(alice));
        }
        assertLe(token.balanceOf(alice), before);
    }

    // ───────────────────── S1 / D2: solvency and neutrality ─────────────────────

    function test_S1_sumOfClaimsNeverExceedsTotalAssets() public {
        _deposit(alice, 100_000e6);
        _deposit(bob, 50_000e6);
        _deposit(carol, 25_000e6);
        _donate(9_999e6);

        uint256 claims = _view().previewRedeem(_shareToken().balanceOf(alice))
            + _view().previewRedeem(_shareToken().balanceOf(bob)) + _view().previewRedeem(_shareToken().balanceOf(carol));

        assertLe(claims, _totalAssets());
    }

    function testFuzz_S1_solvencyHoldsAcrossArbitraryDeposits(uint96 a, uint96 b, uint96 c, uint96 donation) public {
        _deposit(alice, bound(a, 1e6, 10_000_000e6));
        _deposit(bob, bound(b, 1e6, 10_000_000e6));
        _deposit(carol, bound(c, 1e6, 10_000_000e6));
        uint256 donated = bound(donation, 0, 10_000_000e6);
        if (donated != 0) _donate(donated);

        uint256 claims = _view().previewRedeem(_shareToken().balanceOf(alice))
            + _view().previewRedeem(_shareToken().balanceOf(bob)) + _view().previewRedeem(_shareToken().balanceOf(carol));

        assertLe(claims, _totalAssets());
    }

    function test_D2_depositDoesNotChangeAnotherHoldersClaim() public {
        _deposit(alice, 100_000e6);
        uint256 aliceClaimBefore = _view().previewRedeem(_shareToken().balanceOf(alice));

        _deposit(bob, 500_000e6);
        uint256 aliceClaimAfter = _view().previewRedeem(_shareToken().balanceOf(alice));

        assertApproxEqAbs(aliceClaimAfter, aliceClaimBefore, 1);
    }

    function testFuzz_D2_depositIsNeutralForExistingHolders(uint96 existing, uint96 incoming) public {
        _deposit(alice, bound(existing, 1e6, 10_000_000e6));
        uint256 before = _view().previewRedeem(_shareToken().balanceOf(alice));

        _deposit(bob, bound(incoming, 1e6, 10_000_000e6));
        uint256 afterDeposit = _view().previewRedeem(_shareToken().balanceOf(alice));

        assertApproxEqAbs(afterDeposit, before, 1);
    }

    function test_S6_supplyEqualsSumOfBalances() public {
        _deposit(alice, 100_000e6);
        _deposit(bob, 50_000e6);
        _withdraw(alice, 10_000e6);

        uint256 sum = _shareToken().balanceOf(alice) + _shareToken().balanceOf(bob) + _shareToken().balanceOf(TREASURY);
        assertEq(sum, _shareToken().totalSupply());
    }

    // ─────────────────────── W9: maxWithdraw never over-promises ────────────────

    function test_W9_maxWithdrawIsAlwaysHonoured() public {
        _deposit(alice, 100_000e6);
        _donate(1_234e6);

        uint256 max = _view().maxWithdraw(alice);
        assertGt(max, 0);
        _withdraw(alice, max);
    }

    function testFuzz_W9_maxWithdrawIsAlwaysHonoured(uint96 amount, uint96 donation) public {
        _deposit(alice, bound(amount, 1e6, 10_000_000e6));
        uint256 donated = bound(donation, 0, 10_000_000e6);
        if (donated != 0) _donate(donated);

        uint256 max = _view().maxWithdraw(alice);
        if (max == 0) return;
        _withdraw(alice, max);
    }

    function test_W9_maxRedeemIsAlwaysHonoured() public {
        _deposit(alice, 100_000e6);
        _donate(999e6);

        uint256 maxShares = _view().maxRedeem(alice);
        assertGt(maxShares, 0);
        _redeem(alice, maxShares);
    }
}

contract FeeOnTransferTest is VaultHarness {
    FeeOnTransferToken internal token;

    function setUp() public {
        token = new FeeOnTransferToken("Fee On Transfer", "FOT", 6, 100);
        _deployVault(address(token), 1_000, 10_000);
        token.mint(alice, 1_000_000e6);
        token.mint(bob, 1_000_000e6);
    }

    function test_D4_aFeeOnTransferBaseTokenIsRefusedRatherThanMisCredited() public {
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("TRANSFER_MISMATCH"));
        DepositFacet(payable(address(vault))).deposit(1_000e6, alice, 0);
        vm.stopPrank();

        assertEq(_idleBalance(), 0);
        assertEq(_shareToken().totalSupply(), 0);
    }

    function test_D4_mintIsRefusedByTheSameCheck() public {
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("TRANSFER_MISMATCH"));
        DepositFacet(payable(address(vault))).mint(1e12, alice, type(uint256).max);
        vm.stopPrank();

        assertEq(_idleBalance(), 0);
    }

    function test_D4_theLedgerNeverExceedsCustodyForAnyTransferFee() public {
        token.setFeeBps(0);
        _deposit(alice, 100_000e6);
        assertEq(_idleBalance(), 100_000e6);
        assertLe(_idleBalance(), token.balanceOf(address(vault)));

        token.setFeeBps(50);
        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("TRANSFER_MISMATCH"));
        DepositFacet(payable(address(vault))).deposit(50_000e6, bob, 0);
        vm.stopPrank();

        assertLe(_idleBalance(), token.balanceOf(address(vault)));
    }

    function testFuzz_D4_noTransferFeeEverInflatesTheLedger(uint16 feeBps, uint96 amount) public {
        uint256 fee = bound(feeBps, 1, 5_000);
        uint256 deposited = bound(amount, 1e6, 500_000e6);
        token.setFeeBps(fee);

        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        try DepositFacet(payable(address(vault))).deposit(deposited, alice, 0) {} catch {}
        vm.stopPrank();

        assertLe(_idleBalance(), token.balanceOf(address(vault)));
    }
}

contract ShareMathDecimalsTest is VaultHarness {
    function _setUpWithDecimals(uint8 decimals) internal returns (MockERC20 t) {
        t = new MockERC20("Base", "BASE", decimals);
        _deployVault(address(t), 1_000, 10_000);
        t.mint(alice, 1_000_000 * (10 ** decimals));
        t.mint(bob, 1_000_000 * (10 ** decimals));
    }

    function test_M4_eightDecimalBaseRoundTripsSafely() public {
        MockERC20 t = _setUpWithDecimals(8);
        uint256 one = 1e8;

        uint256 before = t.balanceOf(bob);
        _deposit(alice, 1_000 * one);
        uint256 shares = _deposit(bob, 3 * one);
        _redeem(bob, shares);

        assertLe(t.balanceOf(bob), before);
    }

    function test_M4_eighteenDecimalBaseRoundTripsSafely() public {
        MockERC20 t = _setUpWithDecimals(18);
        uint256 one = 1e18;

        uint256 before = t.balanceOf(bob);
        _deposit(alice, 1_000 * one);
        uint256 shares = _deposit(bob, 3 * one);
        _redeem(bob, shares);

        assertLe(t.balanceOf(bob), before);
    }

    function test_M4_twoDecimalBaseRoundTripsSafely() public {
        MockERC20 t = _setUpWithDecimals(2);
        uint256 one = 1e2;

        uint256 before = t.balanceOf(bob);
        _deposit(alice, 1_000 * one);
        uint256 shares = _deposit(bob, 3 * one);
        _redeem(bob, shares);

        assertLe(t.balanceOf(bob), before);
    }

    function testFuzz_M4_roundTripSafeAtEveryDecimals(uint8 decimals, uint96 amount) public {
        decimals = uint8(bound(decimals, 2, 18));
        MockERC20 t = _setUpWithDecimals(decimals);

        uint256 unit = 10 ** decimals;
        uint256 seeded = 1_000 * unit;
        uint256 deposited = bound(amount, 1, 1_000 * unit);

        _deposit(alice, seeded);

        uint256 before = t.balanceOf(bob);
        uint256 shares = _deposit(bob, deposited);
        if (shares == 0) return;
        _redeem(bob, shares);

        assertLe(t.balanceOf(bob), before);
    }
}
