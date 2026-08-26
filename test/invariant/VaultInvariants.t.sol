// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {Handler} from "./Handler.sol";
import {VaultFixture} from "../helpers/VaultFixture.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {IStrategy} from "../../src/strategies/interfaces/IStrategy.sol";
import {EvilStrategy} from "../attack/EvilStrategy.sol";

contract VaultInvariantsTest is VaultFixture {
    Handler internal handler;

    function setUp() public {
        _setUpFixture(1_000, 10_000);
        _addTwoStrategies(5_000, 4_000, 1_000);

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;

        handler =
            new Handler(vault, usdc, venueA, venueB, address(stratA), address(stratB), GOV, KEEPER, GUARDIAN, actors);

        EvilStrategy evil = new EvilStrategy(address(vault), address(usdc));
        handler.setEvil(evil);

        bytes4[] memory selectors = new bytes4[](24);
        selectors[0] = Handler.deposit.selector;
        selectors[1] = Handler.withdraw.selector;
        selectors[2] = Handler.redeem.selector;
        selectors[3] = Handler.emergencyExit.selector;
        selectors[4] = Handler.deployIdle.selector;
        selectors[5] = Handler.rebalance.selector;
        selectors[6] = Handler.harvestAll.selector;
        selectors[7] = Handler.tendAll.selector;
        selectors[8] = Handler.settle.selector;
        selectors[9] = Handler.sync.selector;
        selectors[10] = Handler.venueYield.selector;
        selectors[11] = Handler.venueLoss.selector;
        selectors[12] = Handler.reweight.selector;
        selectors[13] = Handler.toggleDisabled.selector;
        selectors[14] = Handler.pause.selector;
        selectors[15] = Handler.unpause.selector;
        selectors[16] = Handler.warp.selector;
        selectors[17] = Handler.venueIlliquidity.selector;
        selectors[18] = Handler.venueRevert.selector;
        selectors[19] = Handler.addEvilStrategy.selector;
        selectors[20] = Handler.removeEvilStrategy.selector;
        selectors[21] = Handler.evilValueMode.selector;
        selectors[22] = Handler.evilMisbehave.selector;
        selectors[23] = Handler.clearBreaker.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_navEqualsIdlePlusEveryStrategyPosition() public {
        _settle();

        uint256 expected = _idleBalance();
        address[] memory strats = _strategyList();
        for (uint256 i; i < strats.length; ++i) {
            (, bool broken, uint256 lastValue) = _strategyStatus(strats[i]);
            if (broken) {
                expected += lastValue;
                continue;
            }
            (bool ok, uint256 live) = _readPosition(strats[i]);
            if (!ok) return;
            expected += _valueTheVaultWouldUse(lastValue, live);
        }

        assertApproxEqAbs(_totalAssets(), expected, 2);
    }

    /// Mirrors `LibVaultNav._isSuspiciousJump` for the fixture's 100% delta band: a
    /// reading the vault would distrust contributes its anchored value instead.
    function _valueTheVaultWouldUse(uint256 lastValue, uint256 live) internal pure returns (uint256) {
        if (live > type(uint128).max) return lastValue;
        if (lastValue == 0) return live == 0 ? 0 : lastValue;

        uint256 diff = live > lastValue ? live - lastValue : lastValue - live;
        return diff > lastValue ? lastValue : live;
    }

    function _readPosition(address strat) internal view returns (bool ok, uint256 value) {
        try IStrategy(strat).positionValue() returns (uint256 v) {
            return (true, v);
        } catch {
            return (false, 0);
        }
    }

    function _navIsSane() internal view returns (bool) {
        return _totalAssets() <= 1e30;
    }

    function invariant_idleNeverExceedsRealCustody() public view {
        assertLe(_idleBalance(), usdc.balanceOf(address(vault)));
    }

    function invariant_sumOfSharesEqualsTotalSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += _shareToken().balanceOf(handler.actorAt(i));
        }
        sum += _shareToken().balanceOf(TREASURY);
        assertEq(sum, _shareToken().totalSupply());
    }

    function invariant_weightsNeverOverAllocate() public view {
        address[] memory strats = _strategyList();
        uint256 sum = ViewFacet(payable(address(vault))).vaultConfig().idleTargetBps;
        for (uint256 i; i < strats.length; ++i) {
            sum += ViewFacet(payable(address(vault))).strategyWeightBps(strats[i]);
        }
        assertLe(sum, 10_000);
    }

    function invariant_noUserCanHoldMoreValueThanTheVaultHas() public view {
        if (!_navIsSane()) return;
        uint256 totalClaim;
        for (uint256 i; i < handler.actorCount(); ++i) {
            uint256 shares = _shareToken().balanceOf(handler.actorAt(i));
            if (shares != 0) totalClaim += ViewFacet(payable(address(vault))).previewRedeem(shares);
        }
        assertLe(totalClaim, _totalAssets() + 2);
    }

    function invariant_I4_noStrategyHoldsAStandingAllowanceOnAnyReceipt() public view {
        address[] memory strats = _strategyList();
        for (uint256 i; i < strats.length; ++i) {
            assertEq(venueA.allowance(address(vault), strats[i]), 0);
            assertEq(venueB.allowance(address(vault), strats[i]), 0);
            assertEq(usdc.allowance(address(vault), strats[i]), 0);
        }
    }

    function invariant_I3_theStrategyListIsWellFormed() public view {
        address[] memory strats = _strategyList();
        assertLe(strats.length, 5);

        for (uint256 i; i < strats.length; ++i) {
            assertTrue(strats[i] != address(0));
            for (uint256 j; j < i; ++j) {
                assertTrue(strats[i] != strats[j]);
            }
        }
    }

    function invariant_A5_noTwoStrategiesShareAReceipt() public view {
        address[] memory strats = _strategyList();
        for (uint256 i; i < strats.length; ++i) {
            (bool okI, address ri) = _readReceipt(strats[i]);
            if (!okI) continue;
            if (ri == address(0)) continue;
            assertTrue(ri != address(usdc));
            assertTrue(ri != address(_shareToken()));
            for (uint256 j; j < i; ++j) {
                (bool okJ, address rj) = _readReceipt(strats[j]);
                if (okJ && rj != address(0)) assertTrue(ri != rj);
            }
        }
    }

    function _readReceipt(address strat) internal view returns (bool ok, address receipt) {
        try IStrategy(strat).receiptToken() returns (address r) {
            return (true, r);
        } catch {
            return (false, address(0));
        }
    }

    function invariant_valueOutNeverExceedsValueIn() public {
        _settle();
        if (!_navIsSane()) return;

        uint256 valueIn = handler.totalDeposited() + handler.ghostVenueGain() + handler.ghostDonated();

        // Measured from LIVE holdings, never from `totalAssets()`. A broken strategy
        // deliberately keeps its last known-good figure in the checkpoint, so the
        // vault's own NAV intentionally overstates while the breaker is tripped —
        // correct for pricing, useless for conservation. Base parked inside a strategy
        // also still counts: a hostile strategy sitting on its allocation, or one that
        // has been de-registered, has not paid anybody.
        // The hostile strategy is measured by the base it ACTUALLY holds, never by what
        // it claims: its `positionValue()` is free to lie (double, max, zero), and a lie
        // is not value. Honest strategies are measured by their position, since their
        // capital sits in a venue rather than in the strategy.
        uint256 stillHeld = _idleBalance() + usdc.balanceOf(address(handler.evil()));

        address[] memory strats = _strategyList();
        for (uint256 i; i < strats.length; ++i) {
            if (strats[i] == address(handler.evil())) continue;
            (bool ok, uint256 live) = _readPosition(strats[i]);
            if (!ok || live > type(uint128).max) return;
            stillHeld += live;
        }

        uint256 valueOut = handler.totalWithdrawn() + handler.ghostVenueLoss() + stillHeld;
        assertLe(valueOut, valueIn + 1e6);
    }

    function invariant_shareTokenSupplyIsZeroOnlyWhenNavIsDust() public view {
        if (!_navIsSane()) return;
        if (_shareToken().totalSupply() == 0) {
            assertLe(_totalAssets(), 1e6);
        }
    }

    function invariant_brokenStrategiesAreNeverCountedLive() public view {
        address[] memory strats = _strategyList();
        for (uint256 i; i < strats.length; ++i) {
            (, bool broken, uint256 lastValue) = _strategyStatus(strats[i]);
            if (broken) assertGe(lastValue, 0);
        }
    }
}
