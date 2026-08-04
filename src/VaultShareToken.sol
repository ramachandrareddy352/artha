// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @title  VaultShareToken
 * @notice The transferable ERC-20 a depositor actually holds. One is deployed by
 *         each `Vault` in its constructor; mint/burn are restricted to that vault.
 *
 *  Decimals are fixed at 18 regardless of the base asset's own decimals
 * 
 *  `i_vault` is immutable and set once at deployment (the deploying Vault). Facet
 *  logic runs via `delegatecall` through the Vault, so any facet calling
 *  `mint`/`burn`/`spendAllowance` does so with `msg.sender == i_vault` regardless
 *  of which facet triggered it.
 */
contract VaultShareToken is ERC20 {
    address public immutable i_vault;

    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);

    modifier onlyVault() {
        require(msg.sender == i_vault, "NOT_VAULT");
        _;
    }

    constructor(address _vault, string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        require(_vault != address(0), "ZERO_ADDRESS");
        i_vault = _vault;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
        emit Minted(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
        emit Burned(from, amount);
    }

    /// @notice Decrement `owner`'s allowance for `spender` by `amount`, letting the
    ///         vault honor the ERC-4626 "withdraw on behalf of an owner via
    ///         allowance" pattern even though `burn` bypasses `transferFrom`.
    ///         Only at emergency time and authorized can call this.
    function spendAllowance(address owner, address spender, uint256 amount) external onlyVault {
        _spendAllowance(owner, spender, amount);
    }
}
