// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @title  VaultShareToken
 * @notice The transferable ERC-20 a depositor actually holds. One is deployed per
 *         vault by `VaultAdminFacet.createVault`; its own address IS that vault's
 *         identity everywhere else in the protocol (AppStorage's vault-keyed
 *         mappings, `ReferralVault.registerVault`, `UserRewardVault.registerVault`).
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY A REAL ERC-20 AND NOT AN INTERNAL BALANCE MAPPING
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `UserRewardVault.stake(vault, user, amount)` pulls shares with a plain
 *  `safeTransferFrom` — that only works if shares are a real, independently
 *  transferable token the staking contract can be approved for. An internal
 *  balance mapping inside the Diamond's own storage (the old design's approach)
 *  cannot be staked, composed with, or held by any contract that doesn't know
 *  about the Diamond's internals. A standalone ERC-20 costs one extra deployment
 *  per vault and buys full composability for free.
 *
 *  Decimals are fixed at 18 regardless of the base asset's own decimals (6 for
 *  USDC, 8 for WBTC, 18 for WETH, ...) — OZ's ERC20 default, left un-overridden.
 *  See LibVaultMath's header for why this matters for the inflation defense.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   MINT / BURN ARE DIAMOND-ONLY
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `diamond` is immutable and set once at deployment. Every facet's logic runs via
 *  `delegatecall` through the Diamond, so any facet calling `mint`/`burn` on this
 *  token does so with `msg.sender == diamond` regardless of which specific facet
 *  triggered it — the same property that makes `onlyVault` correct on every
 *  strategy contract (see BaseStrategy's header) makes `onlyDiamond` correct here.
 */
contract VaultShareToken is ERC20 {
    address public immutable diamond;

    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);

    modifier onlyDiamond() {
        require(msg.sender == diamond, "NOT_DIAMOND");
        _;
    }

    constructor(address _diamond, string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        require(_diamond != address(0), "ZERO_ADDRESS");
        diamond = _diamond;
    }

    function mint(address to, uint256 amount) external onlyDiamond {
        _mint(to, amount);
        emit Minted(to, amount);
    }

    function burn(address from, uint256 amount) external onlyDiamond {
        _burn(from, amount);
        emit Burned(from, amount);
    }

    /// @notice Decrement `owner`'s allowance for `spender` by `amount`, the same
    ///         way a plain `transferFrom` would. Lets the Diamond honor the
    ///         standard ERC-4626 "withdraw on behalf of an owner via allowance"
    ///         pattern even though `burn` itself bypasses `transferFrom` entirely
    ///         (burn only ever moves supply, never a balance between two holders).
    ///         Infinite approvals are left untouched, matching OZ's own
    ///         `_spendAllowance` behavior.
    function spendAllowance(address owner, address spender, uint256 amount) external onlyDiamond {
        _spendAllowance(owner, spender, amount);
    }
}
