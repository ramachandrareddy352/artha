// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultHarness} from "../helpers/VaultHarness.sol";
import {ReentrantToken, ReentrancyAttacker} from "./ReentrantToken.sol";
import {DepositFacet} from "../../src/facets/DepositFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {ERC4626WrapperStrategy} from "../../src/strategies/common/ERC4626WrapperStrategy.sol";
import {MockOracle, MockSwapper, MockERC4626} from "../mocks/Mocks.sol";

contract ReentrancyTest is VaultHarness {
    ReentrantToken internal token;
    ReentrancyAttacker internal attacker;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockERC4626 internal venue;
    ERC4626WrapperStrategy internal strat;

    function setUp() public {
        token = new ReentrantToken("Reentrant USD", "rUSD", 6);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(token), 1e8);

        _deployVault(address(token), 1_000, 10_000);

        venue = new MockERC4626(address(token));
        strat = new ERC4626WrapperStrategy(
            address(vault), address(token), address(oracle), address(swapper), address(venue)
        );

        attacker = new ReentrancyAttacker(address(vault), address(token));
        token.setHook(address(attacker));

        token.mint(alice, 10_000_000e6);
        token.mint(bob, 10_000_000e6);
        token.mint(address(attacker), 1_000_000e6);

        vm.prank(address(attacker));
        token.approve(address(vault), type(uint256).max);
    }

    function _seed() internal {
        _addSingleStrategy(address(strat), 9_000, 1_000);
        _deposit(alice, 100_000e6);
        _deployIdle();
    }

    function _arm(ReentrancyAttacker.Target t) internal {
        attacker.setTarget(t);
        token.setHookEnabled(true);
    }

    function _disarm() internal {
        token.setHookEnabled(false);
    }

    function _supplyAndCustodyAreCoherent() internal view {
        assertLe(_idleBalance(), token.balanceOf(address(vault)));

        uint256 claims;
        address[3] memory holders = [alice, bob, address(attacker)];
        for (uint256 i; i < holders.length; ++i) {
            uint256 sh = _shareToken().balanceOf(holders[i]);
            if (sh != 0) claims += ViewFacet(payable(address(vault))).previewRedeem(sh);
        }
        assertLe(claims, _totalAssets() + 2);
    }

    // ───────────────── deposit re-entered from the pull transfer ────────────────

    function test_R_reentrantDepositDuringADepositIsBlocked() public {
        _seed();
        _arm(ReentrancyAttacker.Target.Deposit);

        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        DepositFacet(payable(address(vault))).deposit(10_000e6, bob, 0);
        vm.stopPrank();

        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        _disarm();
        _supplyAndCustodyAreCoherent();
    }

    function test_R_reentrantWithdrawDuringADepositIsBlocked() public {
        _seed();
        _arm(ReentrancyAttacker.Target.Withdraw);

        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        DepositFacet(payable(address(vault))).deposit(10_000e6, bob, 0);
        vm.stopPrank();

        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        _disarm();
        _supplyAndCustodyAreCoherent();
    }

    // ──────────────── withdraw re-entered from the payout transfer ──────────────

    function test_R_reentrantWithdrawDuringAWithdrawIsBlocked() public {
        _seed();
        _arm(ReentrancyAttacker.Target.Withdraw);

        _withdraw(alice, 5_000e6);

        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        _disarm();
        _supplyAndCustodyAreCoherent();
    }

    function test_R_reentrantRedeemDuringAWithdrawIsBlocked() public {
        _seed();
        _arm(ReentrancyAttacker.Target.Redeem);

        _withdraw(alice, 5_000e6);

        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        _disarm();
        _supplyAndCustodyAreCoherent();
    }

    function test_R_reentrantDepositDuringAWithdrawIsBlocked() public {
        _seed();
        _arm(ReentrancyAttacker.Target.Deposit);

        _withdraw(alice, 5_000e6);

        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        _disarm();
        _supplyAndCustodyAreCoherent();
    }

    // ─────────────── permissionless views re-entered mid-flight ─────────────────

    function test_R_reentrantSyncDuringAWithdrawIsBlocked() public {
        _seed();
        _arm(ReentrancyAttacker.Target.Sync);

        _withdraw(alice, 5_000e6);

        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        _disarm();
        _supplyAndCustodyAreCoherent();
    }

    function test_R_reentrantSettleDuringAWithdrawIsBlocked() public {
        _seed();
        _arm(ReentrancyAttacker.Target.Settle);

        _withdraw(alice, 5_000e6);

        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        _disarm();
        _supplyAndCustodyAreCoherent();
    }

    // ───────────── emergency exit re-entered from its own payout ────────────────

    function test_R_reentrantEmergencyWithdrawDuringAnEmergencyWithdrawIsBlocked() public {
        _seed();
        _pause();
        _arm(ReentrancyAttacker.Target.EmergencyWithdraw);

        _emergencyWithdraw(alice, _shareToken().balanceOf(alice) / 2);

        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        _disarm();
        _supplyAndCustodyAreCoherent();
    }

    // ───────────── the strategy boundary: invest and divest transfers ───────────

    function test_R_reentrancyDuringDeployIdleIsBlocked() public {
        _addSingleStrategy(address(strat), 9_000, 1_000);
        _deposit(alice, 100_000e6);

        _arm(ReentrancyAttacker.Target.Deposit);
        _deployIdle();

        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        _disarm();
        _supplyAndCustodyAreCoherent();
    }

    function test_R_reentrancyDuringRebalanceIsBlocked() public {
        _seed();
        _arm(ReentrancyAttacker.Target.Withdraw);

        _rebalance();

        _disarm();
        _supplyAndCustodyAreCoherent();
    }

    // ─────────── a reentrant token cannot mint value out of the vault ───────────

    function test_S2_noReentryPathInflatesTheLedgerAboveCustody() public {
        _seed();

        ReentrancyAttacker.Target[6] memory targets = [
            ReentrancyAttacker.Target.Deposit,
            ReentrancyAttacker.Target.Withdraw,
            ReentrancyAttacker.Target.Redeem,
            ReentrancyAttacker.Target.EmergencyWithdraw,
            ReentrancyAttacker.Target.Sync,
            ReentrancyAttacker.Target.Settle
        ];

        for (uint256 i; i < targets.length; ++i) {
            _arm(targets[i]);
            vm.prank(alice);
            try WithdrawFacet(payable(address(vault))).withdraw(1_000e6, alice, alice, type(uint256).max) {} catch {}
            _disarm();
            _supplyAndCustodyAreCoherent();
        }

        assertEq(_shareToken().balanceOf(address(attacker)), 0);
    }
}
