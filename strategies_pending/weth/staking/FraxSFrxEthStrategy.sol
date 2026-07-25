// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CrossAssetERC4626Strategy} from "../../common/CrossAssetERC4626Strategy.sol";

/**
 * @title  FraxSFrxEthStrategy  —  hold sfrxETH from a WETH vault
 * @notice WETH -> frxETH -> sfrxETH (Frax's staked ETH). sfrxETH is an ERC-4626 whose
 *         asset is frxETH, so this is the cross-asset wrapper with a WETH<->frxETH leg.
 *
 *   yield : ETH staking rewards, concentrated into sfrxETH's share price (frxETH
 *           holders who DON'T stake forgo yield, so sfrxETH earns a boosted rate).
 *   risk  : frxETH/ETH peg + the swap round-trip + validator slashing tail. Medium.
 *           Sits in the WETH vault, ideally a higher-risk tier than Aave-WETH.
 */
contract FraxSFrxEthStrategy is CrossAssetERC4626Strategy {
    constructor(
        address _vault,
        address _weth,
        address _oracle,
        address _swapper,
        address _sfrxeth,
        address _frxeth
    ) CrossAssetERC4626Strategy(_vault, _weth, _oracle, _swapper, _sfrxeth, _frxeth) {}
}
