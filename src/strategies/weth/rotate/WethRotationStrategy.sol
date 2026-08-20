// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RotationStrategy} from "../../common/RotationStrategy.sol";

/**
 * @title  WethRotationStrategy — accumulate ETH by trading the ETH/stable pair
 * @notice The `WbtcRotationStrategy` pattern on a WETH-denominated vault: sell WETH
 *         into strength, buy it back after a drawdown, and keep the extra ETH. The
 *         vault accounts in WETH, so ETH-per-share is the score.
 *
 *         Read `p` as the stablecoin priced in WETH, so "p falls" means ETH got more
 *         expensive — `enterQuoteDropBps` is the take-profit band and
 *         `exitQuoteGainBps` is the buy-back band, exactly as in the WBTC file.
 *
 *   Why it fits ETH particularly well: unlike BTC, a WETH vault has a genuinely good
 *   passive alternative in `LidoWstEthStrategy` (~3-4% in ETH terms, no trading, no
 *   timing). So this strategy has a real hurdle to clear and should be sized as the
 *   satellite next to staking, not as the core. Its edge is in ranges; staking's edge
 *   is that it never has to be right about anything.
 *
 *   ETH is also more volatile than BTC, which cuts both ways: wider realized ranges
 *   mean more round trips, and sharper trends mean the stop-loss leg matters more.
 *   Set `exitStopLossBps` deliberately.
 *
 *   Both hard requirements from `WbtcRotationStrategy` apply unchanged: widen the
 *   vault's `strategyMaxDeltaBps`, and keep `tend()` on a keeper schedule.
 *
 *   No native ETH is involved on any path — the strategy trades WETH as a plain ERC-20.
 */
contract WethRotationStrategy is RotationStrategy {
    constructor(
        address _vault,
        address _weth,
        address _oracle,
        address _swapper,
        address _stable, // quote: USDC / USDT / DAI
        address _wethPark, // optional 4626 over WETH to earn while holding ETH
        address _stablePark, // optional 4626 over the stable to earn while waiting
        Params memory _params
    ) RotationStrategy(_vault, _weth, _oracle, _swapper, _stable, _wethPark, _stablePark, _params) {}
}
