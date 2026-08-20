// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  EulerV2DaiStrategy — supply DAI to a Euler V2 (EVK) vault
 * @notice EVK vaults are ERC-4626 with `asset() == DAI`, so the universal wrapper
 *         covers them. Euler V2 is permissionless, so the risk is entirely in the
 *         chosen vault's collateral and oracle configuration — vet it as governance.
 */
contract EulerV2DaiStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _dai, address _oracle, address _swapper, address _eulerVault)
        ERC4626WrapperStrategy(_vault, _dai, _oracle, _swapper, _eulerVault)
    {}
}
