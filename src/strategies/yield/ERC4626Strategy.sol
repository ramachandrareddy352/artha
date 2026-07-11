// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseStrategy} from "../BaseStrategy.sol";
import {IERC4626} from "../../interfaces/external/IERC4626.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  ERC4626Strategy  (the generic yield adapter)
 * @notice ONE adapter for ANY ERC-4626 vault. Deposits `underlying` into the 4626
 *         vault and holds the vault shares; value = convertToAssets(sharesHeld).
 *         BaseStrategy layers per-pool shares on top so many Artha pools can share it.
 *
 *  Point `_vault4626` at any of these (asset must equal `_underlying`):
 *    - sUSDe (Ethena, funding-rate yield)     - sUSDS / sDAI (Sky savings rate)
 *    - MetaMorpho vaults (curated Morpho)      - Euler V2 EVK vaults
 *    - Fluid fTokens                           - Yearn V3 vaults
 *    - most other yield-bearing stablecoins
 *
 *  This single file is where most of the protocol's yield-venue breadth comes from
 *  — write once, deploy many instances pointed at different vaults.
 *
 *  `_redeem` is marked virtual so specializations (e.g. RWAStrategy) can add
 *  liquidity guards around it.
 */
contract ERC4626Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IERC4626 public immutable vault4626;

    constructor(address _vault, address _underlying, address _oracle, address _usdc, address _vault4626)
        BaseStrategy(_vault, _underlying, _oracle, _usdc)
    {
        require(_vault4626 != address(0), "ZERO_ADDR");
        require(IERC4626(_vault4626).asset() == _underlying, "ASSET_MISMATCH");
        vault4626 = IERC4626(_vault4626);
    }

    function _supply(uint256 amount) internal override {
        IERC20(underlying).forceApprove(address(vault4626), amount);
        vault4626.deposit(amount, address(this));
    }

    function _redeem(uint256 amount) internal virtual override returns (uint256) {
        // withdraw exactly `amount` assets to this adapter (burns the needed shares)
        vault4626.withdraw(amount, address(this), address(this));
        return amount;
    }

    function _totalUnderlying() internal view override returns (uint256) {
        return vault4626.convertToAssets(vault4626.balanceOf(address(this)));
    }
}
