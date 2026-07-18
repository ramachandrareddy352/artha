// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {BaseStrategy} from "../BaseStrategy.sol";

/// @notice Pendle PT/asset TWAP oracle. Returns PT value in asset terms, 1e18-scaled,
///         pulling toward 1e18 (par) as maturity approaches.
interface IPendlePtOracle {
    function getPtToAssetRate(address market, uint32 twapDuration) external view returns (uint256 ptToAssetRate);
}

/// @notice Minimal Pendle SY/PT redeem-after-maturity path.
interface IPendlePrincipalToken {
    function isExpired() external view returns (bool);
    function expiry() external view returns (uint256);
}

/**
 * @title  PendlePtStrategy  —  Shape-4 fixed rate (discount to par)
 * @notice Buys a Pendle Principal Token (PT) at a discount and holds it to maturity,
 *         where it redeems 1:1 for the underlying. The discount you buy at IS the
 *         locked-in fixed yield.
 *
 *  ⚠ ABI CAUTION: Pendle's router and market ABIs are intricate and version-specific.
 *  Entry/exit here are routed through the generic SWAPPER (base <-> PT via a Pendle
 *  route encoded off-chain), and post-maturity redemption is left as an integration
 *  point. VERIFY every Pendle interface against the live deployment before use, and
 *  test the maturity-redeem path specifically — it is the one that must never fail.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   LIFECYCLE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   invest   : swapper.swap(base -> PT) via a Pendle route. Buys PT below par.
 *   value    : PT held * getPtToAssetRate(market, twap) -> asset units, then oracle-
 *              converted to base. The rate rises toward par (1e18) as expiry nears, so
 *              value accretes smoothly — no reward token, no harvest.
 *   withdraw : BEFORE maturity  -> sell PT on the Pendle AMM via the swapper (slippage).
 *              AFTER  maturity  -> redeem PT 1:1 for the underlying (no slippage).
 *   harvest  : NO-OP. Fixed-rate accretion is in the PT price, not a claimable token.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   RISK
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Exiting BEFORE maturity is at the market price, which can be below the pull-to-par
 *  value during rate moves — so this suits capital that can hold to expiry. The TWAP
 *  oracle is what makes valuation trustless; use a non-trivial `twapDuration`.
 */
contract PendlePtStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable pt; // the Principal Token (base of value)
    address public immutable market; // the Pendle market for the PT/asset TWAP
    IPendlePtOracle public immutable ptOracle;
    address public immutable underlying; // the PT's underlying asset (for oracle conversion)
    uint8 public immutable underlyingDecimals;
    uint32 public twapDuration;

    bytes public buyRoute; // base -> PT
    bytes public sellRoute; // PT -> base (pre-maturity)

    event RoutesSet();
    event TwapDurationSet(uint32 seconds_);

    constructor(
        address _vault,
        address _asset, // base token
        address _oracle,
        address _swapper,
        address _pt,
        address _market,
        address _ptOracle,
        address _underlying,
        uint8 _underlyingDecimals,
        uint32 _twapDuration
    ) BaseStrategy(_vault, _asset, _oracle, _swapper) {
        require(_pt != address(0) && _market != address(0) && _ptOracle != address(0), "ZERO_ADDR");
        pt = IERC20(_pt);
        market = _market;
        ptOracle = IPendlePtOracle(_ptOracle);
        underlying = _underlying;
        underlyingDecimals = _underlyingDecimals;
        twapDuration = _twapDuration;
    }

    function _invest(uint256 amount) internal override {
        // Buy PT with base via a Pendle route. minOut floored at the current PT value.
        uint256 expectedPt = _baseToPt(amount);
        uint256 minOut = (expectedPt * (10_000 - maxSlippageBps)) / 10_000;
        asset.forceApprove(address(swapper), amount);
        swapper.swap(address(asset), address(pt), amount, minOut, buyRoute);
    }

    function _divest(uint256 amount) internal override returns (uint256 freed) {
        uint256 ptNeeded = _baseToPt(amount);
        uint256 held = pt.balanceOf(address(this));
        if (ptNeeded > held) ptNeeded = held;
        if (ptNeeded == 0) return 0;

        // Pre-maturity: sell on the AMM. Post-maturity, the sell route should instead
        // encode the 1:1 redeem call — both go through the swapper as opaque routes.
        uint256 minOut = (_ptToBase(ptNeeded) * (10_000 - maxSlippageBps)) / 10_000;
        pt.forceApprove(address(swapper), ptNeeded);
        uint256 before = asset.balanceOf(address(this));
        swapper.swap(address(pt), address(asset), ptNeeded, minOut, sellRoute);
        freed = asset.balanceOf(address(this)) - before;
    }

    function _positionValue() internal view override returns (uint256) {
        return _ptToBase(pt.balanceOf(address(this)));
    }

    // ─────────────────────────── PT valuation ───────────────────────────────────

    /// @dev PT amount -> base units: PT -> underlying (via Pendle TWAP) -> base (oracle).
    function _ptToBase(uint256 ptAmount) internal view returns (uint256) {
        if (ptAmount == 0) return 0;
        uint256 rate = ptOracle.getPtToAssetRate(market, twapDuration); // 1e18, PT->asset
        uint256 underlyingAmt = Math.mulDiv(ptAmount, rate, 1e18); // in underlying (PT decimals == underlying? assume 18)

        uint256 pU = oracle.getPrice(underlying);
        uint256 pBase = oracle.getPrice(address(asset));
        require(pU != 0 && pBase != 0, "NO_PRICE");
        return Math.mulDiv(underlyingAmt, pU * (10 ** assetDecimals), pBase * (10 ** underlyingDecimals));
    }

    function _baseToPt(uint256 baseAmount) internal view returns (uint256) {
        if (baseAmount == 0) return 0;
        uint256 rate = ptOracle.getPtToAssetRate(market, twapDuration);
        require(rate != 0, "NO_RATE");
        uint256 pU = oracle.getPrice(underlying);
        uint256 pBase = oracle.getPrice(address(asset));
        require(pU != 0 && pBase != 0, "NO_PRICE");
        // base -> underlying -> PT
        uint256 underlyingAmt =
            Math.mulDiv(baseAmount, pBase * (10 ** underlyingDecimals), pU * (10 ** assetDecimals));
        return Math.mulDiv(underlyingAmt, 1e18, rate);
    }

    // ─────────────────────────────── admin ──────────────────────────────────────

    function setRoutes(bytes calldata _buyRoute, bytes calldata _sellRoute) external onlyVault {
        buyRoute = _buyRoute;
        sellRoute = _sellRoute;
        emit RoutesSet();
    }

    function setTwapDuration(uint32 _seconds) external onlyVault {
        require(_seconds >= 300, "TWAP_TOO_SHORT");
        twapDuration = _seconds;
        emit TwapDurationSet(_seconds);
    }

    function isExpired() external view returns (bool) {
        return IPendlePrincipalToken(address(pt)).isExpired();
    }
}
