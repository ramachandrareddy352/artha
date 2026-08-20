// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {VaultHarness} from "./VaultHarness.sol";
import {Mainnet} from "./Addresses.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {PriceFeed} from "../../src/oracle/PriceFeed.sol";
import {UniswapV3Swapper} from "../../src/strategies/swap/UniswapV3Swapper.sol";
import {IAggregatorV3} from "../../src/oracle/interfaces/IAggregatorV3.sol";

abstract contract ForkBase is VaultHarness {
    PriceFeed internal priceFeed;
    UniswapV3Swapper internal uniSwapper;

    mapping(address => MockAggregator) internal feedOf;

    bool internal forkReady;

    /// Set FORK_BLOCK to pin a block for reproducibility; that needs an ARCHIVE rpc.
    /// Left unset, this forks at the latest block, which ordinary (non-archive) public
    /// endpoints serve — so the suite runs anywhere, at the cost of assertions having
    /// to tolerate whatever the live rates happen to be.
    function _forkOrSkip() internal returns (bool) {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }

        uint256 pinned = vm.envOr("FORK_BLOCK", uint256(0));
        if (pinned == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, pinned);
        }
        forkReady = true;

        priceFeed = new PriceFeed(address(this), address(0xdead));
        uniSwapper = new UniswapV3Swapper(Mainnet.UNISWAP_V3_ROUTER);
        return true;
    }

    function _registerFeed(address token, address realChainlinkFeed) internal {
        (, int256 answer,,,) = IAggregatorV3(realChainlinkFeed).latestRoundData();
        require(answer > 0, "NO_LIVE_PRICE");

        MockAggregator agg = new MockAggregator(answer);
        feedOf[token] = agg;
        priceFeed.setChainlinkConfig(token, address(agg), 7 days);
    }

    function _registerFeedAt(address token, int256 price8dp) internal {
        MockAggregator agg = new MockAggregator(price8dp);
        feedOf[token] = agg;
        priceFeed.setChainlinkConfig(token, address(agg), 7 days);
    }

    function _movePriceBps(address token, int256 bps) internal {
        feedOf[token].moveBps(bps);
    }

    function _skipTime(uint256 delta) internal {
        vm.warp(vm.getBlockTimestamp() + delta);
        vm.roll(block.number + delta / 12);
    }

    /// No totalSupply adjustment: WETH9 derives `totalSupply()` from its ETH balance
    /// rather than storing it, so stdStorage cannot find a slot to adjust. Nothing here
    /// reads a token's total supply, so the plain balance write is enough.
    function _give(address token, address who, uint256 amount) internal {
        deal(token, who, amount);
    }

    function _units(address token, uint256 whole) internal view returns (uint256) {
        return whole * (10 ** IERC20Metadata(token).decimals());
    }
}
