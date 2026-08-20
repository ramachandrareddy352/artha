// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title IStrategy — stateless executor surface
 * @notice The surface the Vault sees. A strategy CUSTODIES NOTHING: every DeFi
 *         receipt (aToken, ERC-4626 share, LP/gauge position, venue-internal
 *         ledger balance) is credited to the VAULT, and every redemption returns
 *         base token to the VAULT. The strategy only executes venue interactions
 *         on the vault's behalf; only the vault may call the state-changers.
 *
 *  INVEST   : the vault approves `assets` of base to the strategy; the strategy
 *             pulls it and deposits into the venue with the receipt credited to
 *             the vault (onBehalfOf / supplyTo / receiver = vault).
 *  DIVEST   : the vault grants the strategy access to the needed receipt (ERC-20
 *             approval, or an operator allowance for internal-ledger venues); the
 *             strategy redeems and sends the freed base token to the vault.
 *  HARVEST  : the strategy claims rewards, swaps to base, and sends base to the vault.
 *  POSITION : `positionValue()` reads the VAULT's own holdings at the venue, in base.
 */
interface IStrategy {
    /// @notice The base token this strategy accepts and reports in (e.g. USDC).
    function asset() external view returns (IERC20);

    /// @notice The vault this strategy serves — the only allowed caller.
    function vault() external view returns (address);

    /// @notice The receipt token the VAULT holds for this strategy (aToken,
    ///         4626 share, LP token...). `address(0)` for internal-ledger venues
    ///         (e.g. Compound V3) where the position is not a transferable token.
    function receiptToken() external view returns (address);

    /// @notice Current worth of the VAULT's position at this venue, in base token.
    ///         Includes principal, accrued interest, and (haircut-adjusted) the
    ///         value of any not-yet-claimed reward tokens.
    function positionValue() external view returns (uint256);

    /// @notice How much base could be divested right now, bounded by venue liquidity.
    function maxWithdraw() external view returns (uint256);

    /// @notice The (haircut) base value of rewards accrued at the venue but NOT yet
    ///         claimed. Already included in `positionValue()`; exposed separately so a
    ///         keeper can decide whether a harvest is worth its gas. Venues whose
    ///         pending rewards cannot be read in a view report 0 — under-reporting is
    ///         always safe, over-reporting is not.
    function pendingRewardsValue() external view returns (uint256);

    /// @notice Pull `assets` of base (pre-approved by the vault) and deploy it,
    ///         crediting the venue receipt to the vault. Vault-only.
    function invest(uint256 assets) external;

    /// @notice Free up to `assets` of base and send it to the vault. Returns the
    ///         amount actually delivered (may be less on slippage/venue limits).
    ///         The vault must have granted receipt access first. Vault-only.
    function divest(uint256 assets) external returns (uint256 withdrawn);

    /// @notice Claim rewards, swap to base, send base to the vault. Returns the
    ///         base realized. Vault-only.
    function harvest() external returns (uint256 harvested);

    /// @notice Position MAINTENANCE — adjust what the position is made of without
    ///         moving base in or out of the vault. This is where a rotation strategy
    ///         swaps between its two legs, and where any strategy re-parks capital.
    ///         A no-op for strategies with nothing to maintain. Vault-only.
    ///
    ///         Split from `harvest()` deliberately: harvest REALIZES value back to the
    ///         vault and is priced by the base delta it delivers, while tend changes
    ///         nothing about how much the vault holds — only where it sits. Merging
    ///         them would make a rotation's slippage look like negative harvest.
    function tend() external;

    /// @notice Unwind the entire position to base and send it to the vault,
    ///         skipping reward accounting. The escape hatch. Vault-only.
    function emergencyWithdraw() external returns (uint256 withdrawn);
}
