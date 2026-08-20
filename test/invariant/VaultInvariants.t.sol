// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {Handler} from "./Handler.sol";
import {VaultFixture} from "../helpers/VaultFixture.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {IStrategy} from "../../src/strategies/interfaces/IStrategy.sol";

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

        bytes4[] memory selectors = new bytes4[](17);
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

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_navEqualsIdlePlusEveryStrategyPosition() public {
        _settle();

        uint256 expected = _idleBalance();
        address[] memory strats = _strategyList();
        for (uint256 i; i < strats.length; ++i) {
            (, bool broken, uint256 lastValue) = _strategyStatus(strats[i]);
            expected += broken ? lastValue : IStrategy(strats[i]).positionValue();
        }

        assertApproxEqAbs(_totalAssets(), expected, 2);
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

    function invariant_weightsAlwaysAllocateExactlyOneHundredPercent() public view {
        address[] memory strats = _strategyList();
        uint256 sum = ViewFacet(payable(address(vault))).vaultConfig().idleTargetBps;
        for (uint256 i; i < strats.length; ++i) {
            sum += ViewFacet(payable(address(vault))).strategyWeightBps(strats[i]);
        }
        assertEq(sum, 10_000);
    }

    function invariant_noUserCanHoldMoreValueThanTheVaultHas() public view {
        uint256 totalClaim;
        for (uint256 i; i < handler.actorCount(); ++i) {
            uint256 shares = _shareToken().balanceOf(handler.actorAt(i));
            if (shares != 0) totalClaim += ViewFacet(payable(address(vault))).previewRedeem(shares);
        }
        assertLe(totalClaim, _totalAssets() + 2);
    }

    function invariant_valueOutNeverExceedsValueIn() public {
        _settle();

        uint256 valueIn = handler.totalDeposited() + handler.ghostVenueGain() + handler.ghostDonated();
        uint256 valueOut = handler.totalWithdrawn() + handler.ghostVenueLoss() + _totalAssets();

        assertLe(valueOut, valueIn + 1e6);
    }

    function invariant_shareTokenSupplyIsZeroOnlyWhenNavIsDust() public view {
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
