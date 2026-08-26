// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultHarness} from "../helpers/VaultHarness.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {ERC4626WrapperStrategy} from "../../src/strategies/common/ERC4626WrapperStrategy.sol";
import {MockERC20, MockOracle, MockSwapper, MockERC4626} from "../mocks/Mocks.sol";

/// Every ordering of a reduced action set, run exhaustively. The point is not that any
/// single sequence is interesting — it is that NO ordering of user, keeper and admin
/// actions can break solvency or the share ledger.
contract PermutationTest is VaultHarness {
    MockERC20 internal usdc;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    MockERC4626 internal venueA;
    MockERC4626 internal venueB;
    ERC4626WrapperStrategy internal sA;
    ERC4626WrapperStrategy internal sB;

    uint256 internal constant ACTIONS = 8;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);

        _deployVault(address(usdc), 1_000, 5_000);

        venueA = new MockERC4626(address(usdc));
        venueB = new MockERC4626(address(usdc));
        sA = new ERC4626WrapperStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(venueA)
        );
        sB = new ERC4626WrapperStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(venueB)
        );

        usdc.mint(alice, 100_000_000e6);
        usdc.mint(bob, 100_000_000e6);
        usdc.mint(carol, 100_000_000e6);

        _addSingleStrategy(address(sA), 9_000, 1_000);
        address[] memory two = new address[](2);
        two[0] = address(sA);
        two[1] = address(sB);
        uint16[] memory w = new uint16[](2);
        w[0] = 4_500;
        w[1] = 4_500;
        _addStrategy(address(sB), two, w, 1_000);

        _deposit(alice, 1_000_000e6);
        _deployIdle();
    }

    function _act(uint256 which) internal {
        if (which == 0) {
            try this.extDeposit(bob, 50_000e6) {} catch {}
        } else if (which == 1) {
            try this.extWithdraw(alice, 30_000e6) {} catch {}
        } else if (which == 2) {
            try this.extRedeem(alice, _shareToken().balanceOf(alice) / 20) {} catch {}
        } else if (which == 3) {
            try this.extDeployIdle() {} catch {}
        } else if (which == 4) {
            try this.extRebalance() {} catch {}
        } else if (which == 5) {
            try this.extHarvestAll() {} catch {}
        } else if (which == 6) {
            try this.extReweight() {} catch {}
        } else {
            try this.extYield() {} catch {}
        }
    }

    function extDeposit(address who, uint256 amount) external {
        _deposit(who, amount);
    }

    function extWithdraw(address who, uint256 amount) external {
        _withdraw(who, amount);
    }

    function extRedeem(address who, uint256 shares) external {
        if (shares == 0) return;
        _redeem(who, shares);
    }

    function extDeployIdle() external {
        _deployIdle();
    }

    function extRebalance() external {
        _rebalance();
    }

    function extHarvestAll() external {
        _harvestAll();
    }

    function extReweight() external {
        address[] memory two = new address[](2);
        two[0] = address(sA);
        two[1] = address(sB);
        uint16[] memory w = new uint16[](2);
        w[0] = 7_000;
        w[1] = 2_000;
        _setTargets(two, w, 1_000);
    }

    function extYield() external {
        venueA.accrueBps(50);
        venueB.accrueBps(40);
    }

    function _claim(address who) internal view returns (uint256) {
        uint256 sh = _shareToken().balanceOf(who);
        return sh == 0 ? 0 : ViewFacet(payable(address(vault))).previewRedeem(sh);
    }

    function _assertHealthy() internal view {
        assertLe(_idleBalance(), usdc.balanceOf(address(vault)));

        uint256 claims = _claim(alice) + _claim(bob) + _claim(carol) + _claim(TREASURY);
        assertLe(claims, _totalAssets() + 4);

        uint256 sum = _shareToken().balanceOf(alice) + _shareToken().balanceOf(bob)
            + _shareToken().balanceOf(carol) + _shareToken().balanceOf(TREASURY);
        assertEq(sum, _shareToken().totalSupply());

        address[] memory strats = _strategyList();
        uint256 weightSum = ViewFacet(payable(address(vault))).vaultConfig().idleTargetBps;
        for (uint256 i; i < strats.length; ++i) {
            weightSum += ViewFacet(payable(address(vault))).strategyWeightBps(strats[i]);
        }
        assertLe(weightSum, 10_000);
    }

    /// All 8^3 = 512 ordered triples of the reduced action set, each in one block.
    function test_INTERLEAVE_everyOrderingOfThreeActionsKeepsTheVaultHealthy() public {
        uint256 snapshot = vm.snapshotState();

        for (uint256 i; i < ACTIONS; ++i) {
            for (uint256 j; j < ACTIONS; ++j) {
                for (uint256 k; k < ACTIONS; ++k) {
                    _act(i);
                    _act(j);
                    _act(k);
                    _assertHealthy();
                    vm.revertToState(snapshot);
                    snapshot = vm.snapshotState();
                }
            }
        }
    }

    /// The same triples, but with a guardian pause landing between the 2nd and 3rd.
    function test_INTERLEAVE_aPauseLandingMidSequenceNeverBreaksSolvency() public {
        uint256 snapshot = vm.snapshotState();

        for (uint256 i; i < ACTIONS; ++i) {
            for (uint256 j; j < ACTIONS; ++j) {
                _act(i);
                _act(j);

                _pause();
                try this.extRedeem(alice, _shareToken().balanceOf(alice) / 50) {} catch {}
                _assertHealthy();
                _unpause();

                _assertHealthy();
                vm.revertToState(snapshot);
                snapshot = vm.snapshotState();
            }
        }
    }

    /// Admin removes a strategy at every possible point in a 2-action sequence.
    function test_INTERLEAVE_removingAStrategyAtAnyPointKeepsTheVaultHealthy() public {
        uint256 snapshot = vm.snapshotState();

        for (uint256 i; i < ACTIONS; ++i) {
            for (uint256 slot; slot < 3; ++slot) {
                if (slot == 0) _removeB();
                _act(i);
                if (slot == 1) _removeB();
                _act((i + 3) % ACTIONS);
                if (slot == 2) _removeB();

                _assertHealthy();
                vm.revertToState(snapshot);
                snapshot = vm.snapshotState();
            }
        }
    }

    function _removeB() internal {
        vm.prank(GOV);
        try AdminFacet(payable(address(vault))).removeStrategy(address(sB), type(uint256).max) {} catch {}
    }

    /// Two users acting in the same block, in both orders, must be equivalent.
    function test_INTERLEAVE_twoUsersInOneBlockAreOrderIndependent() public {
        _deposit(bob, 1_000_000e6);
        _deployIdle();
        venueA.accrueBps(300);
        _harvestAll();

        uint256 snapshot = vm.snapshotState();

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);
        _redeem(alice, _shareToken().balanceOf(alice));
        _redeem(bob, _shareToken().balanceOf(bob));
        uint256 aliceFirstOrder = usdc.balanceOf(alice) - aliceBefore;
        uint256 bobFirstOrder = usdc.balanceOf(bob) - bobBefore;

        vm.revertToState(snapshot);

        aliceBefore = usdc.balanceOf(alice);
        bobBefore = usdc.balanceOf(bob);
        _redeem(bob, _shareToken().balanceOf(bob));
        _redeem(alice, _shareToken().balanceOf(alice));
        uint256 aliceSecondOrder = usdc.balanceOf(alice) - aliceBefore;
        uint256 bobSecondOrder = usdc.balanceOf(bob) - bobBefore;

        assertApproxEqRel(aliceFirstOrder, aliceSecondOrder, 0.0001e18);
        assertApproxEqRel(bobFirstOrder, bobSecondOrder, 0.0001e18);
    }
}
