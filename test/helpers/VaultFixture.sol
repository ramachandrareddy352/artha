// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultHarness} from "./VaultHarness.sol";
import {MockERC20, MockOracle, MockSwapper, MockERC4626} from "../mocks/Mocks.sol";
import {MockAavePool, MockAToken, MockAaveRewardsController} from "../mocks/MockVenues.sol";
import {ERC4626WrapperStrategy} from "../../src/strategies/common/ERC4626WrapperStrategy.sol";
import {AaveV3LendStrategy} from "../../src/strategies/common/AaveV3LendStrategy.sol";

abstract contract VaultFixture is VaultHarness {
    MockERC20 internal usdc;
    MockERC20 internal rewardToken;
    MockOracle internal oracle;
    MockSwapper internal swapper;

    MockERC4626 internal venueA;
    MockERC4626 internal venueB;
    ERC4626WrapperStrategy internal stratA;
    ERC4626WrapperStrategy internal stratB;

    MockAavePool internal aavePool;
    MockAToken internal aToken;
    MockAaveRewardsController internal aaveRewards;
    AaveV3LendStrategy internal stratAave;

    function _setUpFixture(uint16 idleTargetBps, uint16 maxDeltaBps) internal {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        rewardToken = new MockERC20("Reward", "RWD", 18);
        oracle = new MockOracle();
        swapper = new MockSwapper(address(oracle), 0);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(rewardToken), 10e8);

        _deployVault(address(usdc), idleTargetBps, maxDeltaBps);

        venueA = new MockERC4626(address(usdc));
        venueB = new MockERC4626(address(usdc));
        stratA = new ERC4626WrapperStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(venueA)
        );
        stratB = new ERC4626WrapperStrategy(
            address(vault), address(usdc), address(oracle), address(swapper), address(venueB)
        );

        aavePool = new MockAavePool();
        aToken = new MockAToken(address(aavePool), address(usdc));
        aavePool.register(address(usdc), address(aToken));
        aaveRewards = new MockAaveRewardsController();
        aaveRewards.addReward(address(rewardToken));

        address[] memory rewards = new address[](1);
        rewards[0] = address(rewardToken);
        stratAave = new AaveV3LendStrategy(
            address(vault),
            address(usdc),
            address(oracle),
            address(swapper),
            address(aavePool),
            address(aToken),
            address(aaveRewards),
            rewards
        );

        _fund(alice, 1_000_000e6);
        _fund(bob, 1_000_000e6);
        _fund(carol, 1_000_000e6);
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
    }

    function _addTwoStrategies(uint16 weightA, uint16 weightB, uint16 idleBps) internal {
        _addSingleStrategy(address(stratA), 10_000 - idleBps, idleBps);

        address[] memory all = new address[](2);
        all[0] = address(stratA);
        all[1] = address(stratB);
        uint16[] memory w = new uint16[](2);
        w[0] = weightA;
        w[1] = weightB;
        _addStrategy(address(stratB), all, w, idleBps);
    }

    function _strategiesArray(address a, address b) internal pure returns (address[] memory all) {
        all = new address[](2);
        all[0] = a;
        all[1] = b;
    }

    function _weightsArray(uint16 a, uint16 b) internal pure returns (uint16[] memory w) {
        w = new uint16[](2);
        w[0] = a;
        w[1] = b;
    }

    function _skip(uint256 delta) internal {
        vm.warp(vm.getBlockTimestamp() + delta);
    }
}
