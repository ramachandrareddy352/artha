// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {Vault} from "../../src/Vault.sol";
import {DepositFacet} from "../../src/facets/DepositFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {StrategyFacet} from "../../src/facets/StrategyFacet.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {EmergencyFacet} from "../../src/facets/EmergencyFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {MockERC20, MockERC4626} from "../mocks/Mocks.sol";
import {EvilStrategy} from "../attack/EvilStrategy.sol";

contract Handler is Test {
    Vault public immutable vault;
    MockERC20 public immutable base;
    MockERC4626 public immutable venueA;
    MockERC4626 public immutable venueB;
    address public immutable stratA;
    address public immutable stratB;

    address public immutable gov;
    address public immutable keeper;
    address public immutable guardian;

    address[] public actors;
    address internal currentActor;

    EvilStrategy public evil;
    bool public evilRegistered;

    uint256 public totalDeposited;
    uint256 public totalWithdrawn;
    uint256 public ghostVenueGain;
    uint256 public ghostVenueLoss;
    uint256 public ghostDonated;

    constructor(
        Vault _vault,
        MockERC20 _base,
        MockERC4626 _venueA,
        MockERC4626 _venueB,
        address _stratA,
        address _stratB,
        address _gov,
        address _keeper,
        address _guardian,
        address[] memory _actors
    ) {
        vault = _vault;
        base = _base;
        venueA = _venueA;
        venueB = _venueB;
        stratA = _stratA;
        stratB = _stratB;
        gov = _gov;
        keeper = _keeper;
        guardian = _guardian;
        actors = _actors;
    }

    modifier useActor(uint256 seed) {
        currentActor = actors[seed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function deposit(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        amount = bound(amount, 1e6, 100_000e6);
        base.mint(currentActor, amount);
        base.approve(address(vault), amount);
        try DepositFacet(payable(address(vault))).deposit(amount, currentActor, 0) {
            totalDeposited += amount;
        } catch {}
    }

    function withdraw(uint256 actorSeed, uint256 amount) external useActor(actorSeed) {
        uint256 maxAssets = ViewFacet(payable(address(vault))).maxWithdraw(currentActor);
        if (maxAssets == 0) return;
        amount = bound(amount, 1, maxAssets);

        uint256 before = base.balanceOf(currentActor);
        try WithdrawFacet(payable(address(vault))).withdraw(amount, currentActor, currentActor, type(uint256).max) {
            totalWithdrawn += base.balanceOf(currentActor) - before;
        } catch {}
    }

    function redeem(uint256 actorSeed, uint256 shareSeed) external useActor(actorSeed) {
        uint256 shares = IERC20(vault.shareToken()).balanceOf(currentActor);
        if (shares == 0) return;
        shares = bound(shareSeed, 1, shares);

        uint256 before = base.balanceOf(currentActor);
        try WithdrawFacet(payable(address(vault))).redeem(shares, currentActor, currentActor, 0) {
            totalWithdrawn += base.balanceOf(currentActor) - before;
        } catch {}
    }

    function emergencyExit(uint256 actorSeed, uint256 shareSeed) external useActor(actorSeed) {
        uint256 shares = IERC20(vault.shareToken()).balanceOf(currentActor);
        if (shares == 0) return;
        shares = bound(shareSeed, 1, shares);

        uint256 before = base.balanceOf(currentActor);
        try EmergencyFacet(payable(address(vault))).emergencyWithdraw(shares, currentActor, currentActor) {
            totalWithdrawn += base.balanceOf(currentActor) - before;
        } catch {}
    }

    function deployIdle() external {
        vm.prank(keeper);
        try StrategyFacet(payable(address(vault))).deployIdle() {} catch {}
    }

    function rebalance() external {
        vm.prank(keeper);
        try StrategyFacet(payable(address(vault))).rebalance() {} catch {}
    }

    function harvestAll() external {
        vm.prank(keeper);
        try StrategyFacet(payable(address(vault))).harvestAll() {} catch {}
    }

    function tendAll() external {
        vm.prank(keeper);
        try StrategyFacet(payable(address(vault))).tendAll() {} catch {}
    }

    function settle() external {
        try StrategyFacet(payable(address(vault))).settle() {} catch {}
    }

    function sync() external {
        try EmergencyFacet(payable(address(vault))).sync() {} catch {}
    }

    function venueYield(uint256 which, uint256 bps) external {
        bps = bound(bps, 0, 200);
        MockERC4626 v = which % 2 == 0 ? venueA : venueB;
        uint256 before = v.convertToAssets(v.balanceOf(address(vault)));
        v.accrueBps(bps);
        ghostVenueGain += v.convertToAssets(v.balanceOf(address(vault))) - before;
    }

    function venueLoss(uint256 which, uint256 bps) external {
        bps = bound(bps, 0, 200);
        MockERC4626 v = which % 2 == 0 ? venueA : venueB;
        uint256 before = v.convertToAssets(v.balanceOf(address(vault)));
        v.setRate((v.rate() * (10_000 - bps)) / 10_000);
        ghostVenueLoss += before - v.convertToAssets(v.balanceOf(address(vault)));
    }

    function venueIlliquidity(uint256 which, uint256 cap) external {
        MockERC4626 v = which % 2 == 0 ? venueA : venueB;
        v.setLiquidityCap(bound(cap, 0, type(uint128).max));
    }

    function venueRevert(uint256 which, bool on) external {
        MockERC4626 v = which % 2 == 0 ? venueA : venueB;
        v.setRevertOnWithdraw(on);
    }

    function setEvil(EvilStrategy _evil) external {
        evil = _evil;
    }

    function evilValueMode(uint256 mode) external {
        if (address(evil) == address(0)) return;
        evil.setValueMode(EvilStrategy.ValueMode(bound(mode, 0, 4)));
    }

    function evilMisbehave(uint256 mode) external {
        if (address(evil) == address(0)) return;
        evil.setMisbehaviour(EvilStrategy.Misbehaviour(bound(mode, 0, 4)));
    }

    function addEvilStrategy(uint256 weightSeed) external {
        if (address(evil) == address(0) || evilRegistered) return;

        uint16 wEvil = uint16(bound(weightSeed, 500, 4_000));
        uint16 rest = 9_000 - wEvil;

        address[] memory all = new address[](3);
        all[0] = stratA;
        all[1] = stratB;
        all[2] = address(evil);
        uint16[] memory w = new uint16[](3);
        w[0] = rest / 2;
        w[1] = rest - rest / 2;
        w[2] = wEvil;

        vm.prank(gov);
        try AdminFacet(payable(address(vault))).addStrategy(address(evil), all, w, 1_000) {
            evilRegistered = true;
        } catch {}
    }

    function removeEvilStrategy() external {
        if (!evilRegistered) return;

        vm.prank(gov);
        try AdminFacet(payable(address(vault))).removeStrategy(address(evil), type(uint256).max) {
            evilRegistered = false;
            address[] memory all = new address[](2);
            all[0] = stratA;
            all[1] = stratB;
            uint16[] memory w = new uint16[](2);
            w[0] = 4_500;
            w[1] = 4_500;
            vm.prank(gov);
            try AdminFacet(payable(address(vault))).setTargets(all, w, 1_000) {} catch {}
        } catch {}
    }

    function clearBreaker(uint256 which) external {
        address strat = which % 2 == 0 ? stratA : stratB;
        (,, uint256 lastValue) = ViewFacet(payable(address(vault))).strategyStatus(strat);
        vm.prank(gov);
        try AdminFacet(payable(address(vault))).clearStrategyCircuitBreak(strat, lastValue) {} catch {}
    }

    function reweight(uint256 weightSeed) external {
        uint16 wA = uint16(bound(weightSeed, 0, 9_000));
        uint16 wB = uint16(9_000 - wA);

        address[] memory all = new address[](2);
        all[0] = stratA;
        all[1] = stratB;
        uint16[] memory w = new uint16[](2);
        w[0] = wA;
        w[1] = wB;

        vm.prank(gov);
        try AdminFacet(payable(address(vault))).setTargets(all, w, 1_000) {} catch {}
    }

    function toggleDisabled(uint256 which, bool disabled) external {
        vm.prank(gov);
        try AdminFacet(payable(address(vault))).setStrategyDisabled(which % 2 == 0 ? stratA : stratB, disabled) {}
            catch {}
    }

    function pause() external {
        vm.prank(guardian);
        try EmergencyFacet(payable(address(vault))).pauseVault() {} catch {}
    }

    function unpause() external {
        vm.prank(gov);
        try EmergencyFacet(payable(address(vault))).unpauseVault() {} catch {}
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, 10_000e6);
        base.mint(address(vault), amount);
        ghostDonated += amount;
    }

    function warp(uint256 delta) external {
        vm.warp(vm.getBlockTimestamp() + bound(delta, 1 hours, 30 days));
    }
}
