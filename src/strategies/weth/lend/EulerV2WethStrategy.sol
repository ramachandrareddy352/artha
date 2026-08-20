// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  EulerV2WethStrategy — supply WETH to a Euler V2 (EVK) vault
 * @notice EVK vaults are ERC-4626 with `asset() == WETH`, so the universal wrapper
 *         covers them. Euler's WETH vaults are mostly borrowed against LST collateral
 *         by loopers, which is where the rate comes from. Vet the specific vault's
 *         collateral and oracle configuration as a governance decision.
 */
contract EulerV2WethStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _weth, address _oracle, address _swapper, address _eulerVault)
        ERC4626WrapperStrategy(_vault, _weth, _oracle, _swapper, _eulerVault)
    {}
}
