// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage, Modifiers} from "../libraries/LibAppStorage.sol";
import {LibVaultMath} from "../libraries/LibVaultMath.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";
import {LibVaultCap} from "../libraries/LibVaultCap.sol";
import {VaultShareToken} from "../VaultShareToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  VaultDepositFacet
 * @notice The only way base token enters a vault. Deposits are Model A — the
 *         depositor's shares are minted IMMEDIATELY, priced against the vault's
 *         current checkpointed NAV, and the deposited base token sits as IDLE
 *         balance until the keeper's next `deployIdle`/`rebalance` call (see
 *         VaultHarvestFacet). There is no pending-deposit batching, no waiting
 *         for end-of-day settlement — deposit and receive shares in one
 *         transaction, exactly like every ERC-4626 vault users already expect.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   BOTH ENTRY POINTS, BOTH WITH SLIPPAGE + DEADLINE PROTECTION
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `deposit(assets, ...)` and `mint(shares, ...)` are the two standard ERC-4626
 *  entry points — specify what you're putting in, or what you want out, the other
 *  side is computed. Both take a slippage bound and a deadline because Model A
 *  prices against a CHECKPOINTED NAV that can move between a user signing a
 *  transaction and it landing on-chain (another deposit, a harvest, a withdrawal
 *  landing first in the same block) — without a bound the user has no protection
 *  against executing at a worse price than they saw when they signed.
 */
contract VaultDepositFacet is Modifiers {
    using SafeERC20 for IERC20;

    event Deposited(
        address indexed vault,
        address indexed payer,
        address indexed receiver,
        uint256 assets,
        uint256 shares,
        uint256 pricePerShare
    );

    /// @notice Deposit an exact amount of base token, receive at least
    ///         `minSharesOut` shares. Shares are minted to `receiver`, who may be
    ///         a different address than the caller (matches the stake-for-another
    ///         pattern already used by UserRewardVault).
    function deposit(address vault, uint256 assets, address receiver, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        onlyRegisteredVault(vault)
        whenVaultNotPaused(vault)
        returns (uint256 shares)
    {
        require(block.timestamp <= deadline, "EXPIRED");
        require(receiver != address(0), "ZERO_ADDRESS");
        require(assets != 0, "ZERO_ASSETS");
        require(assets >= s.minDeposit[vault], "BELOW_MIN_DEPOSIT");

        LibVaultNav.refreshNav(vault);

        shares = LibVaultMath.convertToSharesDown(vault, assets);
        require(shares != 0, "ZERO_SHARES");
        require(shares >= minSharesOut, "SLIPPAGE");

        _checkTvlCap(vault, assets);
        LibVaultCap.checkAndConsumeDeposit(vault, msg.sender, assets);

        _pullAndCredit(vault, assets);
        VaultShareToken(vault).mint(receiver, shares);

        emit Deposited(vault, msg.sender, receiver, assets, shares, LibVaultMath.pricePerShare(vault));
    }

    /// @notice Mint an exact amount of shares, paying at most `maxAssetsIn` base
    ///         token.
    function mint(address vault, uint256 shares, address receiver, uint256 maxAssetsIn, uint256 deadline)
        external
        nonReentrant
        onlyRegisteredVault(vault)
        whenVaultNotPaused(vault)
        returns (uint256 assets)
    {
        require(block.timestamp <= deadline, "EXPIRED");
        require(receiver != address(0), "ZERO_ADDRESS");
        require(shares != 0, "ZERO_SHARES");

        LibVaultNav.refreshNav(vault);

        assets = LibVaultMath.convertToAssetsUp(vault, shares);
        require(assets >= s.minDeposit[vault], "BELOW_MIN_DEPOSIT");
        require(assets <= maxAssetsIn, "SLIPPAGE");

        _checkTvlCap(vault, assets);
        LibVaultCap.checkAndConsumeDeposit(vault, msg.sender, assets);

        _pullAndCredit(vault, assets);
        VaultShareToken(vault).mint(receiver, shares);

        emit Deposited(vault, msg.sender, receiver, assets, shares, LibVaultMath.pricePerShare(vault));
    }

    function _checkTvlCap(address vault, uint256 assets) private view {
        uint256 cap = s.tvlCap[vault];
        if (cap == 0) return;
        require(s.navCheckpoint[vault] + assets <= cap, "TVL_CAP_EXCEEDED");
    }

    /// @dev Pulls base token using a BALANCE-DELTA check, not the requested amount —
    ///      a fee-on-transfer or otherwise non-standard base token would deliver
    ///      less than `assets`, and crediting the ask would let the vault's idle
    ///      accounting drift above what it actually custodies. Same defensive
    ///      pattern already used by UserRewardVault.stake().
    function _pullAndCredit(address vault, uint256 assets) private {
        IERC20 token = IERC20(s.baseAsset[vault]);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = token.balanceOf(address(this)) - before;
        require(received == assets, "TRANSFER_MISMATCH");

        s.idleBalance[vault] += received;
        s.navCheckpoint[vault] += received;
    }
}
