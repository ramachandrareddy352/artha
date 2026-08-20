// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {MockERC20, MockOracle, MockSwapper} from "../mocks/Mocks.sol";

contract CustodyStrategy is BaseStrategy {
    bool private immutable custodies;
    uint256 public rewardToMint;

    constructor(address _vault, address _asset, address _oracle, address _swapper, bool _custodies)
        BaseStrategy(_vault, _asset, _oracle, _swapper)
    {
        custodies = _custodies;
    }

    function _custodiesBase() internal view override returns (bool) {
        return custodies;
    }

    function receiptToken() public pure override returns (address) {
        return address(0);
    }

    function _invest(uint256) internal override {}

    function _divest(uint256) internal override {}

    function _withdrawAll() internal override {}

    function _positionValue() internal view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function _harvestRewards() internal override {
        if (rewardToMint != 0) MockERC20(address(asset)).mint(address(this), rewardToMint);
    }

    function setRewardToMint(uint256 amount) external {
        rewardToMint = amount;
    }

    function tendCount() external pure returns (uint256) {
        return 0;
    }
}

contract TendingStrategy is CustodyStrategy {
    uint256 public tends;

    constructor(address _vault, address _asset, address _oracle, address _swapper)
        CustodyStrategy(_vault, _asset, _oracle, _swapper, true)
    {}

    function _tend() internal override {
        tends++;
    }
}

contract BaseStrategyTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal stray;
    MockOracle internal oracle;
    MockSwapper internal swapper;

    address internal vaultAddr = address(0xAA17);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        stray = new MockERC20("Stray", "STRAY", 18);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);
    }

    function _newStrategy(bool custodies) internal returns (CustodyStrategy s) {
        s = new CustodyStrategy(vaultAddr, address(usdc), address(oracle), address(swapper), custodies);
        usdc.mint(vaultAddr, 1_000_000e6);
        vm.prank(vaultAddr);
        usdc.approve(address(s), type(uint256).max);
    }

    function test_nonCustodyStrategySweepsDustBackToVault() public {
        CustodyStrategy s = _newStrategy(false);
        uint256 before = usdc.balanceOf(vaultAddr);

        vm.prank(vaultAddr);
        s.invest(1_000e6);

        assertEq(usdc.balanceOf(address(s)), 0);
        assertEq(usdc.balanceOf(vaultAddr), before);
    }

    function test_custodyStrategyKeepsPositionOnInvest() public {
        CustodyStrategy s = _newStrategy(true);

        vm.prank(vaultAddr);
        s.invest(1_000e6);

        assertEq(usdc.balanceOf(address(s)), 1_000e6);
        assertEq(s.positionValue(), 1_000e6);
    }

    function test_custodyStrategySettlesDivestOnBalanceNotDelta() public {
        CustodyStrategy s = _newStrategy(true);
        vm.prank(vaultAddr);
        s.invest(1_000e6);

        uint256 vaultBefore = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = s.divest(400e6);

        assertEq(withdrawn, 400e6);
        assertEq(usdc.balanceOf(vaultAddr) - vaultBefore, 400e6);
        assertEq(s.positionValue(), 600e6);
    }

    function test_custodyDivestCapsAtAvailableBalance() public {
        CustodyStrategy s = _newStrategy(true);
        vm.prank(vaultAddr);
        s.invest(100e6);

        vm.prank(vaultAddr);
        uint256 withdrawn = s.divest(500e6);

        assertEq(withdrawn, 100e6);
        assertEq(s.positionValue(), 0);
    }

    function test_custodyEmergencyWithdrawReturnsEverything() public {
        CustodyStrategy s = _newStrategy(true);
        vm.prank(vaultAddr);
        s.invest(1_000e6);

        uint256 vaultBefore = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 withdrawn = s.emergencyWithdraw();

        assertEq(withdrawn, 1_000e6);
        assertEq(usdc.balanceOf(vaultAddr) - vaultBefore, 1_000e6);
        assertEq(usdc.balanceOf(address(s)), 0);
    }

    function test_harvestUsesDeltaEvenWhenCustodyingBase() public {
        CustodyStrategy s = _newStrategy(true);
        vm.prank(vaultAddr);
        s.invest(1_000e6);
        s.setRewardToMint(37e6);

        uint256 vaultBefore = usdc.balanceOf(vaultAddr);
        vm.prank(vaultAddr);
        uint256 realized = s.harvest();

        assertEq(realized, 37e6);
        assertEq(usdc.balanceOf(vaultAddr) - vaultBefore, 37e6);
        assertEq(s.positionValue(), 1_000e6);
    }

    function test_onlyVaultGuards() public {
        CustodyStrategy s = _newStrategy(true);

        vm.expectRevert(bytes("NOT_VAULT"));
        s.invest(1e6);
        vm.expectRevert(bytes("NOT_VAULT"));
        s.divest(1e6);
        vm.expectRevert(bytes("NOT_VAULT"));
        s.harvest();
        vm.expectRevert(bytes("NOT_VAULT"));
        s.tend();
        vm.expectRevert(bytes("NOT_VAULT"));
        s.emergencyWithdraw();
        vm.expectRevert(bytes("NOT_VAULT"));
        s.setMaxSlippageBps(50);
        vm.expectRevert(bytes("NOT_VAULT"));
        s.rescue(address(stray));
    }

    function test_investRejectsZero() public {
        CustodyStrategy s = _newStrategy(true);
        vm.prank(vaultAddr);
        vm.expectRevert(bytes("ZERO"));
        s.invest(0);
    }

    function test_divestRejectsZero() public {
        CustodyStrategy s = _newStrategy(true);
        vm.prank(vaultAddr);
        vm.expectRevert(bytes("ZERO"));
        s.divest(0);
    }

    function test_rescueSendsStrayTokenToVault() public {
        CustodyStrategy s = _newStrategy(true);
        stray.mint(address(s), 5e18);

        vm.prank(vaultAddr);
        uint256 amount = s.rescue(address(stray));

        assertEq(amount, 5e18);
        assertEq(stray.balanceOf(vaultAddr), 5e18);
        assertEq(stray.balanceOf(address(s)), 0);
    }

    function test_rescueRefusesProtectedBaseWhenCustodying() public {
        CustodyStrategy s = _newStrategy(true);
        vm.prank(vaultAddr);
        s.invest(1_000e6);

        vm.prank(vaultAddr);
        vm.expectRevert(bytes("PROTECTED_TOKEN"));
        s.rescue(address(usdc));
    }

    function test_rescueAllowsBaseWhenNotCustodying() public {
        CustodyStrategy s = _newStrategy(false);
        usdc.mint(address(s), 12e6);

        vm.prank(vaultAddr);
        uint256 amount = s.rescue(address(usdc));

        assertEq(amount, 12e6);
    }

    function test_maxSlippageIsCapped() public {
        CustodyStrategy s = _newStrategy(true);
        vm.prank(vaultAddr);
        vm.expectRevert(bytes("SLIPPAGE_TOO_HIGH"));
        s.setMaxSlippageBps(501);

        vm.prank(vaultAddr);
        s.setMaxSlippageBps(500);
        assertEq(s.maxSlippageBps(), 500);
    }

    function test_tendIsCalledThroughTheVault() public {
        TendingStrategy s = new TendingStrategy(vaultAddr, address(usdc), address(oracle), address(swapper));

        vm.prank(vaultAddr);
        s.tend();
        vm.prank(vaultAddr);
        s.tend();

        assertEq(s.tends(), 2);
    }

    function test_pendingRewardsValueDefaultsToZero() public {
        CustodyStrategy s = _newStrategy(true);
        assertEq(s.pendingRewardsValue(), 0);
    }

    function testFuzz_custodyDivestNeverExceedsRequest(uint96 deposited, uint96 requested) public {
        vm.assume(deposited > 0 && deposited < 1_000_000e6);
        CustodyStrategy s = _newStrategy(true);

        vm.prank(vaultAddr);
        s.invest(deposited);

        vm.assume(requested > 0);
        vm.prank(vaultAddr);
        uint256 withdrawn = s.divest(requested);

        assertLe(withdrawn, requested);
        assertLe(withdrawn, deposited);
    }
}
