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
 *         Both `deposit` and `mint` take a slippage bound and a deadline.
 */
contract DepositFacet is VaultModifiers {
    using SafeERC20 for IERC20;

    event Deposited(address indexed payer, address indexed receiver, uint256 assets, uint256 shares, uint256 pricePerShare);

    function deposit(uint256 assets, address receiver, uint256 minSharesOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(block.timestamp <= deadline, "EXPIRED");
        require(receiver != address(0), "ZERO_ADDRESS");
        require(assets != 0, "ZERO_ASSETS");
        require(assets >= s.minDeposit, "BELOW_MIN_DEPOSIT");

        LibVaultNav.refreshNav();

        shares = LibVaultMath.convertToSharesDown(assets);
        require(shares != 0, "ZERO_SHARES");
        require(shares >= minSharesOut, "SLIPPAGE");

        _checkTvlCap(s, assets);
        LibVaultCap.checkAndConsumeDeposit(msg.sender, assets);

        _pullAndCredit(s, assets);
        VaultShareToken(s.shareToken).mint(receiver, shares);

        emit Deposited(msg.sender, receiver, assets, shares, LibVaultMath.pricePerShare());
    }

    function mint(uint256 shares, address receiver, uint256 maxAssetsIn, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(block.timestamp <= deadline, "EXPIRED");
        require(receiver != address(0), "ZERO_ADDRESS");
        require(shares != 0, "ZERO_SHARES");

        LibVaultNav.refreshNav();

        assets = LibVaultMath.convertToAssetsUp(shares);
        require(assets >= s.minDeposit, "BELOW_MIN_DEPOSIT");
        require(assets <= maxAssetsIn, "SLIPPAGE");

        _checkTvlCap(s, assets);
        LibVaultCap.checkAndConsumeDeposit(msg.sender, assets);

        _pullAndCredit(s, assets);
        VaultShareToken(s.shareToken).mint(receiver, shares);

        emit Deposited(msg.sender, receiver, assets, shares, LibVaultMath.pricePerShare());
    }

    function _checkTvlCap(VaultStorage.Layout storage s, uint256 assets) private view {
        uint256 cap = s.tvlCap;
        if (cap == 0) return;
        require(s.navCheckpoint + assets <= cap, "TVL_CAP_EXCEEDED");
    }

    /// @dev BALANCE-DELTA check: a fee-on-transfer base token would deliver less
    ///      than `assets`, and crediting the ask would let idle drift above real
    ///      custody. Reject any mismatch.
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
