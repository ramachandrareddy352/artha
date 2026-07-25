// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626WrapperStrategy} from "../../common/ERC4626WrapperStrategy.sol";

/**
 * @title  EulerV2UsdcStrategy  —  supply USDC to a Euler V2 (EVK) vault
 * @notice Euler V2's EVK vaults are ERC-4626 with asset() == the supplied token, so
 *         the universal wrapper covers them exactly. Deploy pointed at the chosen
 *         USDC EVK vault.
 *
 *   yield : borrower interest, isolated per Euler vault. Euler V2 is modular and
 *           permissionless, so pick the specific vault as a governance decision and
 *           vet its collateral/oracle configuration — that is where the risk lives.
 *   note  : any Euler reward token (rEUL, etc.) is distributed separately and is not
 *           auto-claimed here — treat as out of scope, like Morpho's merkle rewards.
 */
contract EulerV2UsdcStrategy is ERC4626WrapperStrategy {
    constructor(address _vault, address _usdc, address _oracle, address _swapper, address _eulerVault)
        ERC4626WrapperStrategy(_vault, _usdc, _oracle, _swapper, _eulerVault)
    {}
}
