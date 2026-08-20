// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultStorage, VaultModifiers} from "../libraries/VaultStorage.sol";
import {LibVaultMath} from "../libraries/LibVaultMath.sol";
import {LibVaultNav} from "../libraries/LibVaultNav.sol";
import {LibVaultCap} from "../libraries/LibVaultCap.sol";
import {VaultShareToken} from "../VaultShareToken.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  DepositFacet
 * @notice The only way base token enters the vault. Model A — shares are minted
 *         IMMEDIATELY, priced against the checkpointed NAV, and the deposited
 *         base sits as IDLE until the keeper's next `deployIdle`/`rebalance`.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   FLAT NATIVE-ETH ENTRY FEE
 *  ═══════════════════════════════════════════════════════════════════════════
 *  Both entry points are `payable` and require EXACTLY `entryFeeWei` of native
 *  ETH (0 when the toll is disabled). The ETH is pooled as protocol-owned funds
 *  (`collectedEthFees`) and is withdrawable only by governance — it never touches
 *  a user's base-asset principal. `msg.value` survives the Vault's fallback
 *  `delegatecall`, and the ETH lands in the Vault (the custodian) automatically.
 */
contract DepositFacet is VaultModifiers {
    using SafeERC20 for IERC20;

    event Deposited(
        address indexed payer, address indexed receiver, uint256 assets, uint256 shares, uint256 pricePerShare
    );
    event EntryFeeCollected(address indexed payer, uint256 amount);

    function deposit(uint256 assets, address receiver, uint256 minSharesOut)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(receiver != address(0), "ZERO_ADDRESS");
        require(assets != 0, "ZERO_ASSETS");
        require(assets >= s.minDeposit, "BELOW_MIN_DEPOSIT");

        _collectEntryFee(s);
        LibVaultNav.refreshNav();
        // `whenNotPaused` ran before the body, but refreshNav can trip a strategy's
        // circuit breaker and auto-pause mid-call. Re-check, so nobody is ever priced
        // against a NAV the vault just declared untrustworthy.
        require(!s.paused, "PAUSED");

        shares = LibVaultMath.convertToSharesDown(assets);
        require(shares != 0, "ZERO_SHARES");
        require(shares >= minSharesOut, "SLIPPAGE");

        _checkTvlCap(s, assets);
        LibVaultCap.checkAndConsumeDeposit(msg.sender, assets);

        _pullAndCredit(s, assets);
        VaultShareToken(s.shareToken).mint(receiver, shares);

        emit Deposited(msg.sender, receiver, assets, shares, LibVaultMath.pricePerShare());
    }

    function mint(uint256 shares, address receiver, uint256 maxAssetsIn)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(receiver != address(0), "ZERO_ADDRESS");
        require(shares != 0, "ZERO_SHARES");

        _collectEntryFee(s);
        LibVaultNav.refreshNav();
        require(!s.paused, "PAUSED"); // see deposit(): refreshNav may auto-pause mid-call

        assets = LibVaultMath.convertToAssetsUp(shares);
        require(assets >= s.minDeposit, "BELOW_MIN_DEPOSIT");
        require(assets <= maxAssetsIn, "SLIPPAGE");

        _checkTvlCap(s, assets);
        LibVaultCap.checkAndConsumeDeposit(msg.sender, assets);

        _pullAndCredit(s, assets);
        VaultShareToken(s.shareToken).mint(receiver, shares);

        emit Deposited(msg.sender, receiver, assets, shares, LibVaultMath.pricePerShare());
    }

    /// @dev Flat native-ETH toll — must be EXACTLY `entryFeeWei`. When the toll is
    ///      disabled (0), `msg.value` must be 0 too. Pooled as protocol-owned ETH.
    function _collectEntryFee(VaultStorage.Layout storage s) private {
        require(msg.value == s.entryFeeWei, "BAD_ETH_FEE");
        if (msg.value != 0) {
            s.collectedEthFees += uint128(msg.value); // msg.value <= MAX_ENTRY_FEE_WEI, fits uint128
            emit EntryFeeCollected(msg.sender, msg.value);
        }
    }

    function _checkTvlCap(VaultStorage.Layout storage s, uint256 assets) private view {
        uint256 cap = s.tvlCap;
        if (cap == 0) return;
        require(s.navCheckpoint + assets <= cap, "TVL_CAP_EXCEEDED");
    }

    /// @dev BALANCE-DELTA check on the ERC-20 base only (native ETH fees never touch
    ///      this): a fee-on-transfer base token would deliver less than `assets`,
    ///      and crediting the ask would let idle drift above real custody.
    function _pullAndCredit(VaultStorage.Layout storage s, uint256 assets) private {
        IERC20 token = IERC20(s.baseAsset);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), assets);
        uint256 received = token.balanceOf(address(this)) - before;
        require(received == assets, "TRANSFER_MISMATCH");

        s.idleBalance += received;
        s.navCheckpoint += received;
    }
}
