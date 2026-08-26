// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultHarness} from "../helpers/VaultHarness.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {ERC4626WrapperStrategy} from "../../src/strategies/common/ERC4626WrapperStrategy.sol";
import {MockERC20, MockOracle, MockSwapper, MockERC4626} from "../mocks/Mocks.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract WithdrawalQueueTest is VaultHarness {
    MockERC20 internal usdc;
    MockOracle internal oracle;
    MockSwapper internal swapper;

    MockERC4626 internal venue0;
    MockERC4626 internal venue1;
    MockERC4626 internal venue2;
    ERC4626WrapperStrategy internal s0;
    ERC4626WrapperStrategy internal s1;
    ERC4626WrapperStrategy internal s2;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);

        _deployVault(address(usdc), 1_000, 10_000);

        venue0 = new MockERC4626(address(usdc));
        venue1 = new MockERC4626(address(usdc));
        venue2 = new MockERC4626(address(usdc));
        s0 = _newStrategy(venue0);
        s1 = _newStrategy(venue1);
        s2 = _newStrategy(venue2);

        usdc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 10_000_000e6);
        usdc.mint(carol, 10_000_000e6);
    }

    function _newStrategy(MockERC4626 v) internal returns (ERC4626WrapperStrategy) {
        return new ERC4626WrapperStrategy(address(vault), address(usdc), address(oracle), address(swapper), address(v));
    }

    function _addThree(uint16 w0, uint16 w1, uint16 w2, uint16 idleBps) internal {
        _addSingleStrategy(address(s0), 10_000 - idleBps, idleBps);

        address[] memory two = new address[](2);
        two[0] = address(s0);
        two[1] = address(s1);
        uint16[] memory tw = new uint16[](2);
        tw[0] = w0;
        tw[1] = 10_000 - idleBps - w0;
        _addStrategy(address(s1), two, tw, idleBps);

        address[] memory three = new address[](3);
        three[0] = address(s0);
        three[1] = address(s1);
        three[2] = address(s2);
        uint16[] memory thw = new uint16[](3);
        thw[0] = w0;
        thw[1] = w1;
        thw[2] = w2;
        _addStrategy(address(s2), three, thw, idleBps);
    }

    function _seed(uint256 amount) internal {
        _addThree(3_000, 3_000, 3_000, 1_000);
        _deposit(alice, amount);
        _deployIdle();
    }

    // ───────────────────────── W1: idle first, then priority ────────────────────

    function test_W1_idleAloneCoversTheWithdrawalAndNoStrategyIsTouched() public {
        _seed(100_000e6);

        uint256 p0 = s0.positionValue();
        uint256 p1 = s1.positionValue();
        uint256 p2 = s2.positionValue();
        assertEq(_idleBalance(), 10_000e6);

        _withdraw(alice, 9_000e6);

        assertEq(s0.positionValue(), p0);
        assertEq(s1.positionValue(), p1);
        assertEq(s2.positionValue(), p2);
        assertEq(_idleBalance(), 1_000e6);
    }

    function test_W1_shortfallComesFromIndexZeroFirst() public {
        _seed(100_000e6);

        uint256 p1 = s1.positionValue();
        uint256 p2 = s2.positionValue();

        _withdraw(alice, 20_000e6);

        assertEq(_idleBalance(), 0);
        assertEq(s0.positionValue(), 20_000e6);
        assertEq(s1.positionValue(), p1);
        assertEq(s2.positionValue(), p2);
    }

    function test_W1_spillsToIndexOneThenIndexTwoInOrder() public {
        _seed(100_000e6);

        _withdraw(alice, 50_000e6);

        assertEq(_idleBalance(), 0);
        assertEq(s0.positionValue(), 0);
        assertEq(s1.positionValue(), 20_000e6);
        assertEq(s2.positionValue(), 30_000e6);
    }

    function test_W1_drainsEverythingInOrderWhenAskedForAll() public {
        _seed(100_000e6);

        _withdraw(alice, 100_000e6);

        assertEq(_idleBalance(), 0);
        assertEq(s0.positionValue(), 0);
        assertEq(s1.positionValue(), 0);
        assertEq(s2.positionValue(), 0);
    }

    // ───────────────────── W4: the queue never over-divests ─────────────────────

    function test_W4_queueStopsAsSoonAsTheAmountIsCovered() public {
        _seed(100_000e6);

        _withdraw(alice, 39_000e6);

        assertEq(s0.positionValue(), 1_000e6);
        assertEq(s1.positionValue(), 30_000e6);
        assertEq(s2.positionValue(), 30_000e6);
        assertEq(_idleBalance(), 0);
    }

    function testFuzz_W4_queueNeverLeavesMoreIdleThanNecessary(uint96 amount) public {
        _seed(100_000e6);
        uint256 requested = bound(amount, 1e6, 99_000e6);

        _withdraw(alice, requested);

        assertLe(_idleBalance(), 30_000e6);
    }

    // ─────────────────── W2/W3: broken and reverting strategies ─────────────────

    function test_W2_brokenStrategyIsSkippedEntirely() public {
        _seed(100_000e6);

        venue0.accrueBps(15_000);
        _harvestAll();
        (, bool broken,) = _strategyStatus(address(s0));
        assertTrue(broken);
        _unpause();

        uint256 p0 = s0.positionValue();
        _withdraw(alice, 40_000e6);

        assertEq(s0.positionValue(), p0);
        assertEq(s1.positionValue(), 0);
        assertEq(s2.positionValue(), 30_000e6);
    }

    function test_W3_revertingVenueContributesZeroAndDoesNotBlockTheWithdrawal() public {
        _seed(100_000e6);
        venue0.setRevertOnWithdraw(true);

        uint256 p0 = s0.positionValue();
        _withdraw(alice, 40_000e6);

        assertEq(s0.positionValue(), p0);
        assertEq(s1.positionValue(), 0);
        assertEq(s2.positionValue(), 30_000e6);
    }

    function test_W3_partiallyLiquidVenueGivesWhatItCanAndTheRestSpills() public {
        _seed(100_000e6);
        venue0.setLiquidityCap(5_000e6);

        _withdraw(alice, 40_000e6);

        assertEq(s0.positionValue(), 25_000e6);
        assertEq(s1.positionValue(), 5_000e6);
        assertEq(s2.positionValue(), 30_000e6);
    }

    // ─────────────────── W5: all or nothing, never a partial burn ───────────────

    function test_W5_totalIlliquidityRevertsAndBurnsNothing() public {
        _seed(100_000e6);
        venue0.setRevertOnWithdraw(true);
        venue1.setRevertOnWithdraw(true);
        venue2.setRevertOnWithdraw(true);

        uint256 sharesBefore = _shareToken().balanceOf(alice);
        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(bytes("INSUFFICIENT_LIQUIDITY"));
        WithdrawFacet(payable(address(vault))).withdraw(50_000e6, alice, alice, type(uint256).max);

        assertEq(_shareToken().balanceOf(alice), sharesBefore);
        assertEq(usdc.balanceOf(alice), balBefore);
        assertEq(_idleBalance(), 10_000e6);
    }

    function test_W5_partialLiquidityStillRevertsRatherThanPayingPartially() public {
        _seed(100_000e6);
        venue0.setLiquidityCap(1_000e6);
        venue1.setRevertOnWithdraw(true);
        venue2.setRevertOnWithdraw(true);

        uint256 sharesBefore = _shareToken().balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(bytes("INSUFFICIENT_LIQUIDITY"));
        WithdrawFacet(payable(address(vault))).withdraw(50_000e6, alice, alice, type(uint256).max);

        assertEq(_shareToken().balanceOf(alice), sharesBefore);
    }

    function test_W5_exactlyTheAvailableAmountSucceeds() public {
        _seed(100_000e6);
        venue1.setRevertOnWithdraw(true);
        venue2.setRevertOnWithdraw(true);

        uint256 available = _idleBalance() + s0.positionValue();
        _withdraw(alice, available);

        assertEq(_idleBalance(), 0);
        assertEq(s0.positionValue(), 0);
    }

    // ──────────────── W1: ordering survives lifecycle operations ────────────────

    function test_W1_orderIsPreservedAfterRemovingTheMiddleStrategy() public {
        _seed(100_000e6);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).removeStrategy(address(s1), 10);

        address[] memory list = _strategyList();
        assertEq(list.length, 2);
        assertEq(list[0], address(s0));
        assertEq(list[1], address(s2));

        assertEq(_idleBalance(), 40_000e6);

        _withdraw(alice, 70_000e6);
        assertEq(s0.positionValue(), 0);
        assertEq(s2.positionValue(), 30_000e6);

        _withdraw(alice, 30_000e6);
        assertEq(s2.positionValue(), 0);
    }

    function test_W1_migratedStrategyMovesToTheBackOfTheQueue() public {
        _seed(100_000e6);

        MockERC4626 venue3 = new MockERC4626(address(usdc));
        ERC4626WrapperStrategy s3 = _newStrategy(venue3);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).migrateStrategy(address(s0), address(s3));

        address[] memory list = _strategyList();
        assertEq(list[0], address(s1));
        assertEq(list[1], address(s2));
        assertEq(list[2], address(s3));

        uint256 p3 = s3.positionValue();
        _withdraw(alice, 40_000e6);

        assertEq(s1.positionValue(), 0);
        assertEq(s3.positionValue(), p3);
    }

    // ───────────────────── W6: ledger stays consistent ──────────────────────────

    function test_W6_idleAndCheckpointFallByExactlyTheAmountPaid() public {
        _seed(100_000e6);

        uint256 navBefore = _totalAssets();
        _withdraw(alice, 25_000e6);

        assertEq(_totalAssets(), navBefore - 25_000e6);

        _settle();
        assertEq(_totalAssets(), navBefore - 25_000e6);
    }

    function testFuzz_W6_navMatchesLiveHoldingsAfterAnyWithdrawal(uint96 amount) public {
        _seed(100_000e6);
        uint256 requested = bound(amount, 1e6, 99_000e6);

        _withdraw(alice, requested);
        _settle();

        uint256 live = _idleBalance() + s0.positionValue() + s1.positionValue() + s2.positionValue();
        assertApproxEqAbs(_totalAssets(), live, 2);
    }

    // ───────────────────── W7: no ordering advantage between users ──────────────

    function test_W7_twoUsersWithdrawingInOneBlockAreTreatedIdentically() public {
        _addThree(3_000, 3_000, 3_000, 1_000);
        _deposit(alice, 100_000e6);
        _deposit(bob, 100_000e6);
        _deployIdle();
        venue0.accrueBps(100);
        _settle();

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        uint256 aliceShares = _shareToken().balanceOf(alice);
        uint256 bobShares = _shareToken().balanceOf(bob);
        assertEq(aliceShares, bobShares);

        _redeem(alice, aliceShares);
        _redeem(bob, bobShares);

        uint256 aliceGot = usdc.balanceOf(alice) - aliceBefore;
        uint256 bobGot = usdc.balanceOf(bob) - bobBefore;
        assertApproxEqRel(aliceGot, bobGot, 0.0001e18);
    }

    // ───────────────────── W8: the allowance path ───────────────────────────────

    function test_W8_allowancePathBurnsFromOwnerAndPaysReceiver() public {
        _seed(100_000e6);

        address share = address(_shareToken());
        vm.prank(alice);
        IERC20Like(share).approve(bob, type(uint256).max);

        uint256 ownerSharesBefore = _shareToken().balanceOf(alice);
        uint256 receiverBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        uint256 burned = WithdrawFacet(payable(address(vault))).withdraw(10_000e6, bob, alice, type(uint256).max);

        assertEq(_shareToken().balanceOf(alice), ownerSharesBefore - burned);
        assertEq(usdc.balanceOf(bob) - receiverBefore, 10_000e6);
    }

    function test_W8_allowanceIsSpentExactlyOnce() public {
        _seed(100_000e6);

        uint256 burnedPreview = ViewFacet(payable(address(vault))).previewWithdraw(10_000e6);
        address share = address(_shareToken());
        vm.prank(alice);
        IERC20Like(share).approve(bob, burnedPreview);

        vm.prank(bob);
        WithdrawFacet(payable(address(vault))).withdraw(10_000e6, bob, alice, type(uint256).max);

        assertEq(_shareToken().allowance(alice, bob), 0);

        vm.prank(bob);
        vm.expectRevert();
        WithdrawFacet(payable(address(vault))).withdraw(1e6, bob, alice, type(uint256).max);
    }

    function test_W8_withdrawalWithoutAllowanceReverts() public {
        _seed(100_000e6);

        vm.prank(bob);
        vm.expectRevert();
        WithdrawFacet(payable(address(vault))).withdraw(1_000e6, bob, alice, type(uint256).max);
    }

    // ───────────────── D3: the per-block withdraw cap, and who it binds ─────────

    function test_D3_withdrawCapBindsASingleWithdrawer() public {
        _seed(100_000e6);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setCaps(0, 0, 20_000e6, 0);

        _withdraw(alice, 20_000e6);

        vm.prank(alice);
        vm.expectRevert(bytes("WITHDRAW_CAP_EXCEEDED"));
        WithdrawFacet(payable(address(vault))).withdraw(1e6, alice, alice, type(uint256).max);
    }

    function test_D3_withdrawCapResetsNextBlock() public {
        _seed(100_000e6);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setCaps(0, 0, 20_000e6, 0);

        _withdraw(alice, 20_000e6);
        vm.roll(block.number + 1);
        _withdraw(alice, 20_000e6);
    }

    function test_D3_withdrawCapIsGlobalPerBlockNotPerCaller() public {
        _seed(100_000e6);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setCaps(0, 0, 20_000e6, 0);

        address share = address(_shareToken());
        vm.startPrank(alice);
        IERC20Like(share).approve(bob, type(uint256).max);
        IERC20Like(share).approve(carol, type(uint256).max);
        vm.stopPrank();

        vm.prank(alice);
        WithdrawFacet(payable(address(vault))).withdraw(20_000e6, alice, alice, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(bytes("WITHDRAW_CAP_EXCEEDED"));
        WithdrawFacet(payable(address(vault))).withdraw(1e6, bob, alice, type(uint256).max);

        vm.prank(carol);
        vm.expectRevert(bytes("WITHDRAW_CAP_EXCEEDED"));
        WithdrawFacet(payable(address(vault))).withdraw(1e6, carol, alice, type(uint256).max);
    }

    function test_D3_anExemptCallerSkipsTheCapEvenForANonExemptOwner() public {
        _seed(100_000e6);

        vm.startPrank(GOV);
        AdminFacet(payable(address(vault))).setCaps(0, 0, 20_000e6, 0);
        AdminFacet(payable(address(vault))).setCapExempt(bob, true);
        vm.stopPrank();

        address share = address(_shareToken());
        vm.prank(alice);
        IERC20Like(share).approve(bob, type(uint256).max);

        vm.prank(alice);
        WithdrawFacet(payable(address(vault))).withdraw(20_000e6, alice, alice, type(uint256).max);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        WithdrawFacet(payable(address(vault))).withdraw(30_000e6, bob, alice, type(uint256).max);

        assertEq(usdc.balanceOf(bob) - bobBefore, 30_000e6);
    }

    // ────────────── W10: harvest before pricing, and withdraw vs redeem ─────────

    function test_W10_withdrawerIsPricedAfterPendingYieldIsRealized() public {
        _seed(100_000e6);
        venue0.accrueBps(500);

        uint256 sharesBefore = _shareToken().balanceOf(alice);
        uint256 burned = _withdraw(alice, 50_000e6);

        uint256 impliedPps = (50_000e6 * 1e18) / burned;
        uint256 naivePps = (100_000e6 * 1e18) / sharesBefore;
        assertGt(impliedPps, naivePps);
    }

    function test_W10_withdrawAndRedeemPriceIdenticallyForEquivalentRequests() public {
        _addThree(3_000, 3_000, 3_000, 1_000);
        _deposit(alice, 100_000e6);
        _deposit(bob, 100_000e6);
        _deployIdle();
        venue0.accrueBps(300);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 aliceShares = _shareToken().balanceOf(alice);
        _redeem(alice, aliceShares);
        uint256 aliceGot = usdc.balanceOf(alice) - aliceBefore;

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 bobBurned = _withdraw(bob, aliceGot);

        assertApproxEqRel(bobBurned, aliceShares, 0.001e18);
        assertEq(usdc.balanceOf(bob) - bobBefore, aliceGot);
    }

    // ───────────────────── W9: maxWithdraw is honest with strategies ────────────

    function test_W9_maxWithdrawReflectsIlliquidVenues() public {
        _seed(100_000e6);
        venue0.setLiquidityCap(0);
        venue1.setLiquidityCap(0);
        venue2.setLiquidityCap(0);

        uint256 liquidity = ViewFacet(payable(address(vault))).availableLiquidity();
        assertEq(liquidity, _idleBalance());

        _withdraw(alice, liquidity);
    }
}
