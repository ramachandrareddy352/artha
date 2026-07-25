// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {BaseStrategy} from "../BaseStrategy.sol";

/// @notice Beefy "mooVault" surface. NOT ERC-4626 — its own deposit/withdraw shape,
///         priced by getPricePerFullShare (1e18). mooShares are themselves an ERC-20.
interface IBeefyVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 shares) external;
    function balanceOf(address account) external view returns (uint256);
    function getPricePerFullShare() external view returns (uint256); // 1e18 want per share
    function want() external view returns (address); // the underlying token
}

/**
 * @title  BeefyStrategy — wrap a Beefy auto-compounding vault (executor model)
 * @notice Beefy vaults compound their farm internally, so this is a Shape-2 holding.
 *         mooShares ARE a transferable ERC-20, so they are custodied in the ARTHA
 *         VAULT (deposit mints them to this strategy, which forwards them to the
 *         vault; divest pulls them back via the vault's transient allowance).
 *
 *   invest   : beefy.deposit(amount) -> mooShares to strategy -> transfer to VAULT
 *   value    : mooShares(VAULT) * getPricePerFullShare() / 1e18   (want == base)
 *   divest   : pull mooShares from VAULT, beefy.withdraw(shares) -> want to strategy
 *   harvest  : NO-OP — Beefy compounds internally; yield is pps rising.
 */
contract BeefyStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IBeefyVault public immutable beefy;
    IERC20 private immutable moo; // the mooShares token (== address(beefy))

    constructor(address _vault, address _asset, address _oracle, address _swapper, address _beefy)
        BaseStrategy(_vault, _asset, _oracle, _swapper)
    {
        require(_beefy != address(0), "ZERO_ADDR");
        require(IBeefyVault(_beefy).want() == _asset, "WANT_MISMATCH");
        beefy = IBeefyVault(_beefy);
        moo = IERC20(_beefy);
    }

    function receiptToken() public view override returns (address) {
        return address(beefy);
    }

    function _invest(uint256 amount) internal override {
        asset.forceApprove(address(beefy), amount);
        uint256 before = moo.balanceOf(address(this));
        beefy.deposit(amount);
        uint256 minted = moo.balanceOf(address(this)) - before;
        if (minted != 0) moo.safeTransfer(vault, minted); // mooShares custodied by the vault
    }

    function _divest(uint256 amount) internal override {
        uint256 pps = beefy.getPricePerFullShare();
        uint256 sharesNeeded = Math.mulDiv(amount, 1e18, pps);
        uint256 held = moo.balanceOf(vault);
        if (sharesNeeded > held) sharesNeeded = held;
        if (sharesNeeded == 0) return;
        moo.safeTransferFrom(vault, address(this), sharesNeeded); // granted allowance
        beefy.withdraw(sharesNeeded); // want to this strategy (forwarded to vault by base)
    }

    function _withdrawAll() internal override {
        uint256 held = moo.balanceOf(vault);
        if (held == 0) return;
        moo.safeTransferFrom(vault, address(this), held);
        beefy.withdraw(held);
    }

    function _positionValue() internal view override returns (uint256) {
        return Math.mulDiv(moo.balanceOf(vault), beefy.getPricePerFullShare(), 1e18);
    }
}
