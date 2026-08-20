// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  EulerV2WbtcStrategy — supply WBTC to a Euler V2 (EVK) vault
 * @notice ERC-4626 over WBTC. Like the Morpho leg, an isolated vault can beat Aave's
 *         shared reserve for WBTC by targeting the few markets where BTC is genuinely
 *         borrowed — though the absolute rate stays low (see `AaveV3WbtcStrategy`).
 *         Vet the vault's collateral and oracle configuration as governance.
 */
contract EulerV2WbtcStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _wbtc, address _oracle, address _swapper, address _eulerVault)
        ERC4626WrapperStrategy(_vault, _wbtc, _oracle, _swapper, _eulerVault)
    {}
}
