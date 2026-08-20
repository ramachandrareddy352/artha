// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AaveV3LendStrategy} from "../../common/AaveV3LendStrategy.sol";

/**
 * @title  AaveV3WethStrategy — supply WETH to Aave V3
 * @notice The WETH vault's baseline: the safest ETH-denominated yield on-chain, with
 *         no staking, no validator exposure and no peg. WETH goes in, aWETH comes back
 *         to the vault — this strategy never touches native ETH.
 *
 *   yield : ETH borrower interest. Structurally LOWER than staking (~3-4%), because
 *           ETH borrow demand is mostly leverage demand and comes and goes. Pair it
 *           with `LidoWstEthStrategy` rather than choosing between them: this leg is
 *           the liquid, peg-free one that the withdrawal queue can always drain first.
 */
contract AaveV3WethStrategy is AaveV3LendStrategy {
    constructor(
        address _vault,
        address _weth,
        address _oracle,
        address _swapper,
        address _pool,
        address _aWeth,
        address _rewardsController,
        address[] memory _rewardTokens
    ) AaveV3LendStrategy(_vault, _weth, _oracle, _swapper, _pool, _aWeth, _rewardsController, _rewardTokens) {}
}
