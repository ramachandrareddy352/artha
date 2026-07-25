// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @title  VaultShareToken
 * @notice The transferable ERC-20 a depositor actually holds. One is deployed by
 *         each `Vault` in its constructor; mint/burn are restricted to that vault.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY A REAL ERC-20 AND NOT AN INTERNAL BALANCE MAPPING
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `UserRewardVault.stake(vault, user, amount)` pulls shares with a plain
 *  `safeTransferFrom` — that only works if shares are a real, independently
 *  transferable token the staking contract can be approved for. A standalone
 *  ERC-20 costs one extra deployment per vault and buys full composability.
 *
 *  Decimals are fixed at 18 regardless of the base asset's own decimals — OZ's
 *  ERC20 default, left un-overridden. See LibVaultMath for why this matters for
 *  the inflation defense.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   MINT / BURN ARE VAULT-ONLY
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `vault` is immutable and set once at deployment (the deploying Vault). Facet
 *  logic runs via `delegatecall` through the Vault, so any facet calling
 *  `mint`/`burn`/`spendAllowance` does so with `msg.sender == vault` regardless
 *  of which facet triggered it.
 */
contract VaultShareToken is ERC20 {
    address public immutable vault;

    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);

    modifier onlyVault() {
        require(msg.sender == vault, "NOT_VAULT");
        _;
    }

    constructor(address _vault, string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        require(_vault != address(0), "ZERO_ADDRESS");
        vault = _vault;
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
    ///         Infinite approvals are left untouched, matching OZ's behavior.
    function spendAllowance(address owner, address spender, uint256 amount) external onlyVault {
        _spendAllowance(owner, spender, amount);
    }
}
