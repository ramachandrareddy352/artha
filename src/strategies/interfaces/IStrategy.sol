// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title IStrategy
 * @notice The surface the vault (Diamond) sees. Every strategy — no matter how many
 *         external protocols it composes internally — presents exactly this, and only
 *         the vault may call the state-changing functions.
 *
 *  The vault never learns which venue a strategy uses. It moves base token in with
 *  `deposit`, pulls it back with `withdraw`, reads the position's worth in base token
 *  with `totalAssets`, and periodically calls `harvest`. That is the entire contract.
 */
interface IStrategy {
    /// @notice The base token this strategy accepts and reports in (e.g. USDC).
    /// @dev    Typed as IERC20 (an address at the ABI level) so the vault can act on
    ///         it directly and so BaseStrategy's public `asset` getter satisfies this.
    function asset() external view returns (IERC20);

    /// @notice The only address allowed to deposit/withdraw/harvest.
    function vault() external view returns (address);

    /// @notice Current worth of the whole position, denominated in `asset`.
    ///         Includes principal, accrued interest, and (haircut-adjusted) the value
    ///         of any not-yet-claimed reward tokens.
    function totalAssets() external view returns (uint256);

    /// @notice How much `asset` could be withdrawn right now, bounded by venue liquidity.
    function maxWithdraw() external view returns (uint256);

    /// @notice Pull `assets` of base token from the vault and deploy it. Vault-only.
    function deposit(uint256 assets) external;

    /// @notice Free up to `assets` of base token and send it to the vault. Returns the
    ///         amount actually delivered (may be less on slippage/venue limits). Vault-only.
    function withdraw(uint256 assets) external returns (uint256 withdrawn);

    /// @notice Claim reward tokens, swap them to base, and reinvest. Vault-only —
    ///         gated so nobody can force tiny, gas/slippage-negative harvests.
    ///         Returns the base-token amount realized this harvest.
    function harvest() external returns (uint256 harvested);

    /// @notice Unwind the entire position to base token and return it to the vault,
    ///         skipping reward accounting. The escape hatch. Vault-only.
    function emergencyWithdraw() external returns (uint256 withdrawn);
}
