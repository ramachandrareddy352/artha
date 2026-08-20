// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {HoldStrategy} from "./HoldStrategy.sol";

/// @notice Pendle's PT/asset TWAP oracle. Returns the PT's value in units of the
///         market's underlying asset, 1e18-scaled, pulling toward par (1e18) as
///         maturity approaches.
interface IPendlePtOracle {
    function getPtToAssetRate(address market, uint32 twapDuration) external view returns (uint256 ptToAssetRate);
}

interface IPendlePrincipalToken {
    function isExpired() external view returns (bool);
    function expiry() external view returns (uint256);
}

/**
 * @title  PendlePtStrategy — buy a fixed rate at a discount and hold it to maturity
 * @notice Holds a Pendle Principal Token. A PT trades BELOW the asset it redeems for,
 *         and that discount is the yield: it closes deterministically as maturity
 *         approaches, whatever happens to the underlying's variable rate. This is the
 *         only strategy family here whose return is FIXED at the moment of entry.
 *
 *         Mechanically it is a `HoldStrategy` — buy one token, hold it in the vault,
 *         sell it later — with one difference that earns it its own file: the held
 *         token is not valued by a market price but by Pendle's TWAP rate, which
 *         encodes the pull-to-par.
 *
 *   invest   : swapper.swap(base -> PT) on a Pendle route; PT custodied by the VAULT.
 *   value    : PT * getPtToAssetRate(market, twap) -> underlying -> base (oracle).
 *   divest   : pull PT from the vault, sell it back through the swapper.
 *   harvest  : NO-OP. Accretion is in the PT's price, not in a claimable token.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ⚠ VERIFY THE ROUTE, AND TEST THE MATURITY PATH
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Pendle's router ABI is intricate and version-specific, so entry and exit are kept
 *  opaque here: both go through the generic swapper with a route built off-chain. That
 *  keeps this contract stable across Pendle versions, but it puts the burden on the
 *  route. AFTER maturity the sell route must encode the 1:1 REDEEM (no slippage, no
 *  AMM); before it, the AMM sale. Rolling the route at expiry is an operational duty —
 *  a matured PT left on an AMM route is selling a par asset into whatever liquidity
 *  remains.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   RISK
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Exiting EARLY is at market: if rates rise after entry, the PT trades below its
 *  pull-to-par line and the vault realizes less than `positionValue` implies. This
 *  suits capital that can sit to expiry — keep the weight small enough that the
 *  withdrawal queue is never forced through it.
 */
contract PendlePtStrategy is HoldStrategy {
    /// @notice The Pendle market whose TWAP prices this PT.
    address public immutable market;
    IPendlePtOracle public immutable ptOracle;
    /// @notice The asset the PT redeems for at maturity (which the oracle prices).
    address public immutable underlying;
    uint8 public immutable underlyingDecimals;

    uint32 public twapDuration;

    event TwapDurationSet(uint32 secs);

    constructor(
        address _vault,
        address _asset,
        address _oracle,
        address _swapper,
        address _pt,
        address _market,
        address _ptOracle,
        address _underlying,
        uint32 _twapDuration
    ) HoldStrategy(_vault, _asset, _oracle, _swapper, _pt) {
        require(_market != address(0) && _ptOracle != address(0) && _underlying != address(0), "ZERO_ADDR");
        require(_twapDuration >= 900, "TWAP_TOO_SHORT");
        market = _market;
        ptOracle = IPendlePtOracle(_ptOracle);
        underlying = _underlying;
        underlyingDecimals = IERC20Metadata(_underlying).decimals();
        twapDuration = _twapDuration;
    }

    /// @notice The PT — held by the vault, like every other receipt.
    function pt() external view returns (address) {
        return address(held);
    }

    // ─────────────────────────────── valuation ──────────────────────────────────

    /// @inheritdoc HoldStrategy
    function _heldToBase(uint256 ptAmount) internal view override returns (uint256) {
        if (ptAmount == 0) return 0;
        uint256 rate = ptOracle.getPtToAssetRate(market, twapDuration);
        require(rate != 0, "NO_RATE");
        uint256 underlyingAmount = Math.mulDiv(ptAmount, rate, 1e18);
        return _convert(underlying, underlyingDecimals, underlyingAmount, address(asset), assetDecimals);
    }

    /// @inheritdoc HoldStrategy
    function _baseToHeld(uint256 baseAmount) internal view override returns (uint256) {
        if (baseAmount == 0) return 0;
        uint256 rate = ptOracle.getPtToAssetRate(market, twapDuration);
        require(rate != 0, "NO_RATE");
        uint256 underlyingAmount = _convert(address(asset), assetDecimals, baseAmount, underlying, underlyingDecimals);
        return Math.mulDiv(underlyingAmount, 1e18, rate);
    }

    /// @notice A longer window costs freshness and buys manipulation resistance. The
    ///         900s floor is enforced here and in the constructor.
    function setTwapDuration(uint32 secs) external onlyVault {
        require(secs >= 900, "TWAP_TOO_SHORT");
        twapDuration = secs;
        emit TwapDurationSet(secs);
    }

    /// @notice Has this PT matured? Once true, the sell route must be the redeem path.
    function isExpired() external view returns (bool) {
        return IPendlePrincipalToken(address(held)).isExpired();
    }

    function expiry() external view returns (uint256) {
        return IPendlePrincipalToken(address(held)).expiry();
    }
}
