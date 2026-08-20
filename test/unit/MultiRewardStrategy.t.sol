// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {MultiRewardStrategy} from "../../src/strategies/common/MultiRewardStrategy.sol";
import {MockERC20, MockOracle, MockSwapper} from "../mocks/Mocks.sol";

contract RewardHarness is MultiRewardStrategy {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public claimable;
    bool public claimReverts;
    bool public pendingReverts;

    constructor(address _vault, address _asset, address _oracle, address _swapper, address[] memory _rewards)
        MultiRewardStrategy(_vault, _asset, _oracle, _swapper, _rewards)
    {}

    function receiptToken() public pure override returns (address) {
        return address(0);
    }

    function _invest(uint256) internal override {}

    function _divest(uint256) internal override {}

    function _withdrawAll() internal override {}

    function _positionValue() internal pure override returns (uint256) {
        return 1_000e6;
    }

    function setClaimable(address token, uint256 amount) external {
        claimable[token] = amount;
    }

    function setClaimReverts(bool on) external {
        claimReverts = on;
    }

    function setPendingReverts(bool on) external {
        pendingReverts = on;
    }

    function _claimRewards() internal override {
        require(!claimReverts, "CLAIM_FAILED");
        for (uint256 i; i < rewardTokens.length; ++i) {
            address t = rewardTokens[i];
            uint256 amount = claimable[t];
            if (amount == 0) continue;
            claimable[t] = 0;
            MockERC20(t).mint(address(this), amount);
        }
    }

    function _pendingRewardAmount(address token) internal view override returns (uint256) {
        require(!pendingReverts, "PENDING_FAILED");
        return claimable[token];
    }

    function registerRewardExternal(address token, uint128 minHarvest) external {
        _registerReward(token, minHarvest);
    }
}

contract MultiRewardStrategyTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal crv;
    MockERC20 internal cvx;
    MockERC20 internal exotic;
    MockOracle internal oracle;
    MockSwapper internal swapper;
    RewardHarness internal strat;

    address internal vaultAddr = address(0xAA17);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        crv = new MockERC20("Curve", "CRV", 18);
        cvx = new MockERC20("Convex", "CVX", 18);
        exotic = new MockERC20("Exotic", "XOT", 8);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);

        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(crv), 50e8);
        oracle.setPrice(address(cvx), 200e8);

        address[] memory rewards = new address[](2);
        rewards[0] = address(crv);
        rewards[1] = address(cvx);
        strat = new RewardHarness(vaultAddr, address(usdc), address(oracle), address(swapper), rewards);
    }

    function test_constructorRegistersRewards() public view {
        assertEq(strat.rewardTokensLength(), 2);
        assertEq(strat.rewardTokens(0), address(crv));
        (bool registered, bool enabled, uint8 decimals,,) = strat.rewards(address(crv));
        assertTrue(registered);
        assertTrue(enabled);
        assertEq(decimals, 18);
    }

    function test_pendingRewardsValueAppliesHaircut() public {
        strat.setClaimable(address(crv), 10e18);

        uint256 gross = 10 * 50e6;
        uint256 expected = (gross * 9_800) / 10_000;
        assertEq(strat.pendingRewardsValue(), expected);
    }

    function test_positionValueIncludesPendingRewards() public {
        strat.setClaimable(address(crv), 10e18);
        assertEq(strat.positionValue(), 1_000e6 + strat.pendingRewardsValue());
    }

    function test_pendingCountsUnsoldBalanceAlreadyHeld() public {
        crv.mint(address(strat), 4e18);
        strat.setClaimable(address(crv), 6e18);

        uint256 gross = 10 * 50e6;
        assertEq(strat.pendingRewardsValue(), (gross * 9_800) / 10_000);
    }

    function test_harvestSellsEveryRewardIntoBase() public {
        strat.setClaimable(address(crv), 10e18);
        strat.setClaimable(address(cvx), 2e18);

        vm.prank(vaultAddr);
        uint256 realized = strat.harvest();

        assertEq(realized, 10 * 50e6 + 2 * 200e6);
        assertEq(usdc.balanceOf(vaultAddr), realized);
        assertEq(crv.balanceOf(address(strat)), 0);
    }

    function test_unpricedRewardIsSkippedNotSold() public {
        strat.registerRewardExternal(address(exotic), 0);
        strat.setClaimable(address(exotic), 5e8);

        vm.prank(vaultAddr);
        uint256 realized = strat.harvest();

        assertEq(realized, 0);
        assertEq(exotic.balanceOf(address(strat)), 5e8);
    }

    function test_unpricedRewardDoesNotBreakValuation() public {
        strat.registerRewardExternal(address(exotic), 0);
        strat.setClaimable(address(exotic), 5e8);
        strat.setClaimable(address(crv), 10e18);

        uint256 value = strat.pendingRewardsValue();
        assertEq(value, (10 * 50e6 * 9_800) / 10_000);
    }

    function test_brokenSwapSkipsOneRewardAndKeepsTheRest() public {
        strat.setClaimable(address(crv), 10e18);
        strat.setClaimable(address(cvx), 2e18);
        swapper.setBroken(true);

        vm.prank(vaultAddr);
        uint256 realized = strat.harvest();

        assertEq(realized, 0);
        assertEq(crv.balanceOf(address(strat)), 10e18);
        assertEq(cvx.balanceOf(address(strat)), 2e18);
    }

    function test_dustFloorBlocksSellingAndValuation() public {
        vm.prank(vaultAddr);
        strat.setRewardMinHarvest(address(crv), 20e18);
        strat.setClaimable(address(crv), 10e18);

        assertEq(strat.pendingRewardsValue(), 0);

        vm.prank(vaultAddr);
        uint256 realized = strat.harvest();
        assertEq(realized, 0);
        assertEq(crv.balanceOf(address(strat)), 10e18);
    }

    function test_dustFloorLetsThroughAmountsAtTheFloor() public {
        vm.prank(vaultAddr);
        strat.setRewardMinHarvest(address(crv), 10e18);
        strat.setClaimable(address(crv), 10e18);

        vm.prank(vaultAddr);
        assertEq(strat.harvest(), 10 * 50e6);
    }

    function test_disabledRewardIsNeitherSoldNorValued() public {
        strat.setClaimable(address(crv), 10e18);
        vm.prank(vaultAddr);
        strat.setRewardEnabled(address(crv), false);

        assertEq(strat.pendingRewardsValue(), 0);
        vm.prank(vaultAddr);
        assertEq(strat.harvest(), 0);
    }

    function test_revertingPendingViewDoesNotBreakValuation() public {
        strat.setClaimable(address(crv), 10e18);
        strat.setPendingReverts(true);

        assertEq(strat.pendingRewardsValue(), 0);
        assertEq(strat.positionValue(), 1_000e6);
    }

    function test_revertingClaimDoesNotBreakHarvest() public {
        crv.mint(address(strat), 3e18);
        strat.setClaimable(address(cvx), 10e18);
        strat.setClaimReverts(true);

        vm.prank(vaultAddr);
        uint256 realized = strat.harvest();

        assertEq(realized, 3 * 50e6);
        assertEq(crv.balanceOf(address(strat)), 0);
        assertEq(cvx.balanceOf(address(strat)), 0);
    }

    function test_claimRewardsIsSelfOnly() public {
        vm.expectRevert(bytes("ONLY_SELF"));
        strat.claimRewards();

        vm.prank(vaultAddr);
        vm.expectRevert(bytes("ONLY_SELF"));
        strat.claimRewards();
    }

    function test_rewardThatIsTheBaseTokenIsNotSwapped() public {
        strat.registerRewardExternal(address(usdc), 0);
        strat.setClaimable(address(usdc), 100e6);

        vm.prank(vaultAddr);
        uint256 realized = strat.harvest();

        assertEq(realized, 100e6);
        assertEq(usdc.balanceOf(address(swapper)), 0);
    }

    function test_registryIsIdempotentAndBounded() public {
        vm.prank(vaultAddr);
        strat.registerReward(address(crv), 5e18);
        assertEq(strat.rewardTokensLength(), 2);

        (,,, uint128 minHarvest,) = strat.rewards(address(crv));
        assertEq(minHarvest, 5e18);

        for (uint256 i; i < 6; ++i) {
            MockERC20 t = new MockERC20("T", "T", 18);
            vm.prank(vaultAddr);
            strat.registerReward(address(t), 0);
        }
        assertEq(strat.rewardTokensLength(), 8);

        MockERC20 overflowToken = new MockERC20("T", "T", 18);
        vm.prank(vaultAddr);
        vm.expectRevert(bytes("TOO_MANY_REWARDS"));
        strat.registerReward(address(overflowToken), 0);
    }

    function test_registryIsVaultOnly() public {
        vm.expectRevert(bytes("NOT_VAULT"));
        strat.registerReward(address(exotic), 0);
        vm.expectRevert(bytes("NOT_VAULT"));
        strat.setRewardEnabled(address(crv), false);
        vm.expectRevert(bytes("NOT_VAULT"));
        strat.setRewardRoute(address(crv), hex"1234");
        vm.expectRevert(bytes("NOT_VAULT"));
        strat.setRewardMinHarvest(address(crv), 1);
    }

    function test_unknownRewardCannotBeConfigured() public {
        vm.prank(vaultAddr);
        vm.expectRevert(bytes("UNKNOWN_REWARD"));
        strat.setRewardEnabled(address(exotic), true);
    }

    function test_routeRoundTrips() public {
        vm.prank(vaultAddr);
        strat.setRewardRoute(address(crv), hex"deadbeef");
        assertEq(strat.rewardRoute(address(crv)), hex"deadbeef");
    }

    function testFuzz_valuationScalesLinearlyWithAmount(uint96 amount) public {
        amount = uint96(bound(amount, 1e15, 1_000_000e18));
        strat.setClaimable(address(crv), amount);

        uint256 value = strat.pendingRewardsValue();
        uint256 expected = (uint256(amount) * 50e8 * 1e6) / (1e8 * 1e18);
        expected = (expected * 9_800) / 10_000;
        assertEq(value, expected);
    }

    function testFuzz_harvestNeverKeepsSellableRewardBehind(uint96 crvAmount, uint96 cvxAmount) public {
        crvAmount = uint96(bound(crvAmount, 1e15, 1_000e18));
        cvxAmount = uint96(bound(cvxAmount, 1e15, 1_000e18));
        strat.setClaimable(address(crv), crvAmount);
        strat.setClaimable(address(cvx), cvxAmount);

        vm.prank(vaultAddr);
        strat.harvest();

        assertEq(crv.balanceOf(address(strat)), 0);
        assertEq(cvx.balanceOf(address(strat)), 0);
    }
}
