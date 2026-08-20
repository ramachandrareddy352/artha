// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LiquidStakingStrategy} from "../../common/LiquidStakingStrategy.sol";
import {IERC4626} from "../../interfaces/IERC4626.sol";

/**
 * @title  FraxSFrxEthStrategy — Frax staking, held as sfrxETH
 * @notice sfrxETH is an ERC-4626 over frxETH, so its "native rate" is simply
 *         `convertToAssets` — the same lower-of-native-and-market treatment as every
 *         other liquid-staking leg, reading a 4626 instead of a bespoke getter.
 *
 *         Note this holds sfrxETH by BUYING it, rather than depositing WETH into the
 *         4626: the vault's base is WETH and sfrxETH's asset is frxETH, so entry would
 *         need a WETH->frxETH leg either way. Going straight to sfrxETH on a deep pool
 *         is one swap instead of two, and never touches native ETH.
 *
 *   yield : Frax concentrates ALL of frxETH's staking rewards into sfrxETH holders
 *           (unstaked frxETH earns nothing), so the sfrxETH rate typically runs above
 *           stETH's. Smaller validator set and thinner liquidity are the price.
 *   harvest : NO-OP — the 4626 rate rising is the yield.
 */
contract FraxSFrxEthStrategy is LiquidStakingStrategy {
    constructor(address _vault, address _weth, address _oracle, address _swapper, address _sfrxEth)
        LiquidStakingStrategy(_vault, _weth, _oracle, _swapper, _sfrxEth)
    {}

    /// @dev sfrxETH -> frxETH, taken as 1:1 with WETH. All three are 18-decimal.
    function _nativeToBase(uint256 sfrxAmount) internal view override returns (uint256) {
        return IERC4626(address(held)).convertToAssets(sfrxAmount);
    }

    function _nativeToHeld(uint256 wethAmount) internal view override returns (uint256) {
        uint256 oneShare = IERC4626(address(held)).convertToAssets(1e18);
        require(oneShare != 0, "NO_RATE");
        return (wethAmount * 1e18) / oneShare;
    }
}
