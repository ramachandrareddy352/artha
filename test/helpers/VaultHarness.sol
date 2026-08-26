// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {Vault} from "../../src/Vault.sol";
import {DepositFacet} from "../../src/facets/DepositFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {StrategyFacet} from "../../src/facets/StrategyFacet.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {EmergencyFacet} from "../../src/facets/EmergencyFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";

abstract contract VaultHarness is Test {
    using SafeERC20 for IERC20;

    address internal constant GOV = address(0x600);
    address internal constant KEEPER = address(0x6EE9E4);
    address internal constant GUARDIAN = address(0x6A11);
    address internal constant TREASURY = address(0x77EA);

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    Vault internal vault;
    IERC20 internal base;

    function _deployVault(address baseAsset, uint16 idleTargetBps, uint16 maxDeltaBps) internal {
        _deployVaultWithTreasury(baseAsset, idleTargetBps, maxDeltaBps, TREASURY);
    }

    function _deployVaultWithTreasury(address baseAsset, uint16 idleTargetBps, uint16 maxDeltaBps, address treasury_)
        internal
    {
        Vault.Facets memory f = Vault.Facets({
            deposit: address(new DepositFacet()),
            withdraw: address(new WithdrawFacet()),
            strategy: address(new StrategyFacet()),
            admin: address(new AdminFacet()),
            emergency: address(new EmergencyFacet()),
            view_: address(new ViewFacet())
        });

        Vault.InitConfig memory c = Vault.InitConfig({
            baseAsset: baseAsset,
            governance: GOV,
            treasury: treasury_,
            keeper: KEEPER,
            guardian: GUARDIAN,
            idleTargetBps: idleTargetBps,
            performanceFeeBps: 0,
            strategyMaxDeltaBps: maxDeltaBps,
            harvestMaxImpactBps: 5_000,
            entryFeeWei: 0,
            minDeposit: 0,
            tvlCap: 0,
            depositCapPerBlock: 0,
            withdrawCapPerBlock: 0,
            name: "Artha Vault Share",
            symbol: "avSHARE"
        });

        vault = new Vault(c, f);
        base = IERC20(baseAsset);
    }

    function _shareToken() internal view returns (IERC20) {
        return IERC20(vault.shareToken());
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(who);
        base.forceApprove(address(vault), assets);
        shares = DepositFacet(payable(address(vault))).deposit(assets, who, 0);
        vm.stopPrank();
    }

    function _withdraw(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = WithdrawFacet(payable(address(vault))).withdraw(assets, who, who, type(uint256).max);
    }

    function _redeem(address who, uint256 shares) internal returns (uint256 assets) {
        vm.prank(who);
        assets = WithdrawFacet(payable(address(vault))).redeem(shares, who, who, 0);
    }

    function _emergencyWithdraw(address who, uint256 shares) internal returns (uint256 assets) {
        vm.prank(who);
        assets = EmergencyFacet(payable(address(vault))).emergencyWithdraw(shares, who, who);
    }

    function _addStrategy(address strategy, address[] memory all, uint16[] memory weights, uint16 idleBps) internal {
        vm.prank(GOV);
        AdminFacet(payable(address(vault))).addStrategy(strategy, all, weights, idleBps);
    }

    function _addSingleStrategy(address strategy, uint16 weightBps, uint16 idleBps) internal {
        address[] memory all = new address[](1);
        all[0] = strategy;
        uint16[] memory w = new uint16[](1);
        w[0] = weightBps;
        _addStrategy(strategy, all, w, idleBps);
    }

    function _setTargets(address[] memory all, uint16[] memory weights, uint16 idleBps) internal {
        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setTargets(all, weights, idleBps);
    }

    function _exec(address strategy, bytes memory data) internal returns (bytes memory) {
        vm.prank(GOV);
        return AdminFacet(payable(address(vault))).execOnStrategy(strategy, data);
    }

    function _deployIdle() internal {
        vm.prank(KEEPER);
        StrategyFacet(payable(address(vault))).deployIdle();
    }

    function _rebalance() internal {
        vm.prank(KEEPER);
        StrategyFacet(payable(address(vault))).rebalance();
    }

    function _harvest(address strategy) internal returns (uint256) {
        vm.prank(KEEPER);
        return StrategyFacet(payable(address(vault))).harvest(strategy);
    }

    function _harvestAll() internal {
        vm.prank(KEEPER);
        StrategyFacet(payable(address(vault))).harvestAll();
    }

    function _tend(address strategy) internal {
        vm.prank(KEEPER);
        StrategyFacet(payable(address(vault))).tend(strategy);
    }

    function _tendAll() internal {
        vm.prank(KEEPER);
        StrategyFacet(payable(address(vault))).tendAll();
    }

    function _settle() internal {
        StrategyFacet(payable(address(vault))).settle();
    }

    function _sync() internal returns (uint256) {
        return EmergencyFacet(payable(address(vault))).sync();
    }

    function _pause() internal {
        vm.prank(GUARDIAN);
        EmergencyFacet(payable(address(vault))).pauseVault();
    }

    function _unpause() internal {
        vm.prank(GOV);
        EmergencyFacet(payable(address(vault))).unpauseVault();
    }

    function _totalAssets() internal view returns (uint256) {
        return ViewFacet(payable(address(vault))).totalAssets();
    }

    function _pps() internal view returns (uint256) {
        return ViewFacet(payable(address(vault))).pricePerShare();
    }

    function _strategyList() internal view returns (address[] memory) {
        return ViewFacet(payable(address(vault))).strategyList();
    }

    function _strategyStatus(address s) internal view returns (bool disabled, bool broken, uint256 lastValue) {
        return ViewFacet(payable(address(vault))).strategyStatus(s);
    }

    function _idleBalance() internal view returns (uint256) {
        return ViewFacet(payable(address(vault))).vaultConfig().idleBalance;
    }
}
