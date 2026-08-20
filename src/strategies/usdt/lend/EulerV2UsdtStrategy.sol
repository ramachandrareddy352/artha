// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  EulerV2UsdtStrategy — supply USDT to a Euler V2 (EVK) vault
 * @notice Euler V2's EVK vaults are ERC-4626 with `asset() == USDT`, so the universal
 *         wrapper covers them exactly. Point it at the chosen USDT vault.
 *
 *   risk : Euler V2 is modular and permissionless — anyone can deploy a vault. The
 *          risk is entirely in the specific vault's collateral and oracle
 *          configuration, so vet it and treat the choice as governance.
 */
contract EulerV2UsdtStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _usdt, address _oracle, address _swapper, address _eulerVault)
        ERC4626WrapperStrategy(_vault, _usdt, _oracle, _swapper, _eulerVault)
    {}
}
