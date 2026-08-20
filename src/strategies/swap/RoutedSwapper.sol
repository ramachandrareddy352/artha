// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapper} from "../interfaces/ISwapper.sol";

/**
 * @title  RoutedSwapper — one swapper address, a governed route per pair
 * @notice An `ISwapper` that owns no venue logic of its own. It holds a governance-set
 *         table of `(tokenIn, tokenOut) -> (venue swapper, route bytes)` and forwards
 *         each swap to the venue that is actually best for that pair — Curve for
 *         stable legs, Uniswap V3 for volatile reward tokens, an aggregator where
 *         off-chain routing wins.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY THIS EXISTS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Without it, every strategy carries its own copy of the routing decision: a swapper
 *  address fixed at construction and a `bytes route` per token, set one call at a time
 *  by governance. Twenty strategies selling CRV means twenty places to update when the
 *  best CRV venue moves, and any one of them left stale sells through thin liquidity —
 *  bounded by its oracle floor, but bounded is not the same as good.
 *
 *  Point every strategy's `swapper` here instead and the routing table becomes ONE
 *  governed object. Strategies keep passing their own `data`; this contract IGNORES it
 *  when a route is registered, which is what lets an existing strategy be re-routed
 *  without touching the strategy at all.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHAT THIS DOES NOT CHANGE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `minOut` still comes from the CALLER's oracle and is enforced here on the measured
 *  balance delta, exactly as in every venue swapper. Governance can choose where a
 *  trade goes; it cannot choose what price the caller is willing to accept. A
 *  compromised route can therefore waste gas and fail trades, but cannot execute one
 *  below the strategy's own floor.
 *
 *  There is no fallback: an unregistered pair REVERTS rather than guessing a venue.
 *  Reward-selling in `MultiRewardStrategy` already treats a failed swap as "skip this
 *  token and report it", so an unconfigured pair degrades to a visible no-op instead
 *  of a bad trade.
 */
contract RoutedSwapper is ISwapper {
    using SafeERC20 for IERC20;

    struct Route {
        address venue; // an ISwapper: CurveSwapper, UniswapV3Swapper, AggregatorSwapper...
        bytes data; // that venue's route encoding for this exact pair
    }

    address public governance;
    mapping(bytes32 pair => Route) private _routes;

    event GovernanceTransferred(address indexed from, address indexed to);
    event RouteSet(address indexed tokenIn, address indexed tokenOut, address venue);
    event RouteRemoved(address indexed tokenIn, address indexed tokenOut);

    modifier onlyGovernance() {
        require(msg.sender == governance, "NOT_GOVERNANCE");
        _;
    }

    constructor(address _governance) {
        require(_governance != address(0), "ZERO_ADDR");
        governance = _governance;
    }

    // ──────────────────────────────── swapping ──────────────────────────────────

    /// @inheritdoc ISwapper
    /// @dev `data` from the caller is deliberately unused — the registered route wins.
    ///      See the header: that is what makes re-routing possible without redeploying
    ///      or reconfiguring a single strategy.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata)
        external
        override
        returns (uint256 amountOut)
    {
        Route storage r = _routes[_key(tokenIn, tokenOut)];
        require(r.venue != address(0), "NO_ROUTE");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(r.venue, amountIn);

        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        ISwapper(r.venue).swap(tokenIn, tokenOut, amountIn, minOut, r.data);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - before;

        // Measured, not claimed — the venue's return value is never the authority.
        require(amountOut >= minOut, "MIN_OUT");
        IERC20(tokenIn).forceApprove(r.venue, 0);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    // ──────────────────────────────── the table ─────────────────────────────────

    function setRoute(address tokenIn, address tokenOut, address venue, bytes calldata data) external onlyGovernance {
        require(tokenIn != address(0) && tokenOut != address(0) && tokenIn != tokenOut, "BAD_PAIR");
        require(venue != address(0), "ZERO_VENUE");
        _routes[_key(tokenIn, tokenOut)] = Route({venue: venue, data: data});
        emit RouteSet(tokenIn, tokenOut, venue);
    }

    function removeRoute(address tokenIn, address tokenOut) external onlyGovernance {
        delete _routes[_key(tokenIn, tokenOut)];
        emit RouteRemoved(tokenIn, tokenOut);
    }

    function transferGovernance(address to) external onlyGovernance {
        require(to != address(0), "ZERO_ADDR");
        emit GovernanceTransferred(governance, to);
        governance = to;
    }

    /// @notice The registered route for a pair. `venue == address(0)` means none.
    function routeFor(address tokenIn, address tokenOut) external view returns (address venue, bytes memory data) {
        Route storage r = _routes[_key(tokenIn, tokenOut)];
        return (r.venue, r.data);
    }

    /// @dev Directional: A->B and B->A are separate entries, because the best venue and
    ///      the correct encoding for a leg are not symmetric in general.
    function _key(address tokenIn, address tokenOut) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }
}
