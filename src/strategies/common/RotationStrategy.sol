// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {BaseStrategy} from "../BaseStrategy.sol";
import {IERC4626} from "../interfaces/IERC4626.sol";

/**
 * @title  RotationStrategy — sell the asset that ran, hold the one that didn't
 * @notice The "swap and hold the other coin" strategy: a two-legged position that
 *         rotates between the vault's BASE token and one QUOTE token on oracle-priced
 *         bands, so that every completed round trip ends with MORE BASE TOKEN than it
 *         started with. Both legs can sit in a yield venue while they wait, so the
 *         strategy is never idle just because it is out of the market.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE CANONICAL EXAMPLE (a WBTC vault that takes profit into USDC)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   base = WBTC (what the vault accounts in), quote = USDC.
 *
 *     BTC rallies 25%  ->  rotate WBTC -> USDC.   "Take profit, wait in stables."
 *     BTC falls 20%    ->  rotate USDC -> WBTC.   "Buy back cheaper."
 *     net effect       ->  the vault now holds MORE WBTC per share than before the
 *                          round trip. The share price is denominated in WBTC, so
 *                          that is real, compounding outperformance versus holding.
 *
 *   Mirror it for a stable vault by swapping the roles — base = USDC, quote = WBTC —
 *   and the SAME contract buys BTC on drawdowns and sells it into strength, growing
 *   the USDC count. Nothing in the logic below knows or cares which asset is "risky".
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ONE PRICE, ONE DIRECTION, NO PREDICTIONS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   p = the price of ONE QUOTE token expressed in BASE tokens, 1e18 fixed point,
 *       taken as the ratio of the two ORACLE USD prices (never a DEX spot price).
 *
 *   Holding BASE, we are waiting for quote to get CHEAP (p falling), and
 *   holding QUOTE, we are waiting for quote to get DEAR (p rising).
 *   In the WBTC/USDC wiring, "USDC is cheap in BTC terms" IS "BTC is expensive" —
 *   the two readings are the same statement, so a single band covers both sides.
 *
 *   Every threshold is measured against the price of the LAST rotation, not against
 *   an absolute level anyone has to forecast. The strategy therefore never needs a
 *   view on where BTC is going; it only ever reacts to how far the pair has moved
 *   since it last acted.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE FOUR SIGNALS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   Holding BASE, rotate INTO quote when:
 *     enterQuoteDropBps  p has fallen this far below the last exit price
 *                        (= the asset we hold has appreciated this much). The
 *                        take-profit leg.
 *     enterReboundBps    ...and p has since risen this far off its trough. Optional
 *                        confirmation that the move has stopped — without it, a
 *                        one-way trend keeps triggering entries all the way down.
 *
 *   Holding QUOTE, rotate BACK to base when:
 *     exitQuoteGainBps   p has risen this far above the entry price (= base got
 *                        cheap again). The buy-back leg — the whole point.
 *     exitTrailingBps    ...or p has fallen this far from its peak, banking a partial
 *                        round trip instead of watching it evaporate.
 *     exitStopLossBps    ...or p has fallen this far below the entry price: base kept
 *                        running away from us, and sitting in quote is losing base.
 *                        This is the bound on the strategy's real risk (see below).
 *     maxQuoteHold       ...or we have simply waited long enough. A band that never
 *                        comes back must not strand the allocation forever.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE REAL RISK, STATED PLAINLY
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  This strategy WINS in ranges and LOSES in one-way trends. Rotating a WBTC vault
 *  into USDC after a 25% rally is a bet that the rally will retrace; if BTC instead
 *  doubles from there, the vault holds stables through the move and its WBTC-per-share
 *  falls behind a passive holder. That is not a bug to be tuned away — it is the
 *  premium being sold. Bound it with `exitStopLossBps` and `maxQuoteHold`, and size
 *  the strategy's weight to the loss you are willing to take on being wrong.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ⚠ THE VAULT'S CIRCUIT BREAKER MUST BE WIDENED FOR THIS STRATEGY
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `positionValue()` is reported in BASE terms, so while this strategy holds quote its
 *  value moves with the pair — a 20% BTC drop makes a USDC leg worth 20% MORE WBTC.
 *  `LibVaultNav`'s breaker reads that as a suspicious jump, trips `strategyBroken`, and
 *  AUTO-PAUSES the vault. Any vault registering a rotation strategy must set
 *  `strategyMaxDeltaBps` wider than the largest pair move expected between two NAV
 *  refreshes, and should keep `tend()` on a frequent keeper schedule so refreshes stay
 *  close together. This is a deployment requirement, not a suggestion.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   CUSTODY
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Unlike the venue adapters, this strategy CUSTODIES BOTH LEGS itself
 *  (`_custodiesBase() == true`, `receiptToken() == address(0)`). It has to: its base
 *  leg is plain base token, and base token held by the vault is `idleBalance` — the
 *  vault cannot tell the two apart, and counting it in both places would double it
 *  into NAV. The vault keeps full control through divest/emergencyWithdraw, which
 *  unwind both legs back to base.
 */
contract RotationStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    enum Stance {
        HoldBase,
        HoldQuote
    }

    /// @dev Fixed-point scale for `p`. Decimal-free: `p` is a ratio of two USD prices,
    ///      so token decimals never enter the signal math (only the amount math, which
    ///      goes through `_convert`).
    uint256 private constant PRICE_SCALE = 1e18;
    uint256 private constant BPS = 10_000;

    /// @notice The token this strategy rotates INTO and out of. Never the base token.
    IERC20 public immutable quote;
    uint8 public immutable quoteDecimals;

    /// @notice Optional yield venues the legs wait in. `address(0)` = hold raw.
    IERC4626 public immutable basePark;
    IERC4626 public immutable quotePark;

    struct Params {
        uint16 enterQuoteDropBps; // HoldBase  -> HoldQuote when p <= exitPrice*(1-x)
        uint16 enterReboundBps; //   ...and p >= troughPrice*(1+y). 0 = no confirmation
        uint16 exitQuoteGainBps; //  HoldQuote -> HoldBase  when p >= entryPrice*(1+x)
        uint16 exitTrailingBps; //   ...or p <= peakPrice*(1-y). 0 = disabled
        uint16 exitStopLossBps; //   ...or p <= entryPrice*(1-z). 0 = disabled
        uint32 cooldown; //          minimum seconds between two rotations
        uint32 maxQuoteHold; //      force back to base after this long. 0 = disabled
    }

    Params public params;

    Stance public stance; // starts HoldBase — a fresh allocation is just the base asset
    bool public rotationEnabled = true;

    uint256 public quoteEntryPrice; // p when we last rotated INTO quote
    uint256 public quoteExitPrice; //  p when we last rotated OUT of quote
    uint256 public peakPrice; //       max p seen while holding quote (trailing stop)
    uint256 public troughPrice; //     min p seen while holding base  (rebound check)
    uint64 public lastRotation;
    uint64 public rotations;

    event Rotated(Stance indexed from, Stance indexed to, uint256 price, uint256 amountIn, uint256 amountOut);
    event ParamsSet(Params params);
    event RotationEnabledSet(bool enabled);
    event StanceForced(Stance to, uint256 price);
    event UnwindLegFailed(address token, uint256 amount);

    constructor(
        address _vault,
        address _asset,
        address _oracle,
        address _swapper,
        address _quote,
        address _basePark,
        address _quotePark,
        Params memory _params
    ) BaseStrategy(_vault, _asset, _oracle, _swapper) {
        require(_quote != address(0) && _quote != _asset, "BAD_QUOTE");
        quote = IERC20(_quote);
        quoteDecimals = IERC20Metadata(_quote).decimals();

        if (_basePark != address(0)) require(IERC4626(_basePark).asset() == _asset, "BASE_PARK_MISMATCH");
        if (_quotePark != address(0)) require(IERC4626(_quotePark).asset() == _quote, "QUOTE_PARK_MISMATCH");
        basePark = IERC4626(_basePark);
        quotePark = IERC4626(_quotePark);

        _setParams(_params);
    }

    /// @dev Both legs live here, base included. See the custody note in the header.
    function _custodiesBase() internal pure override returns (bool) {
        return true;
    }

    function receiptToken() public pure override returns (address) {
        return address(0);
    }

    function _isProtectedToken(address token) internal view override returns (bool) {
        return token == address(asset) || token == address(quote) || token == address(basePark)
            || token == address(quotePark);
    }

    // ════════════════════════════════ the signal ═════════════════════════════════

    /// @notice Price of ONE quote token in base tokens, 1e18 — the only input to every
    ///         decision below. Oracle-sourced on both sides, so a DEX cannot move it.
    function price() public view returns (uint256) {
        uint256 pQuote = oracle.getPrice(address(quote));
        uint256 pBase = oracle.getPrice(address(asset));
        require(pQuote != 0 && pBase != 0, "NO_PRICE");
        return Math.mulDiv(pQuote, PRICE_SCALE, pBase);
    }

    /// @notice What `tend()` would do right now, and why — for keepers and dashboards.
    /// @return act    Whether a rotation would fire this block.
    /// @return target The stance it would move to.
    /// @return p      The price the decision was made at.
    function previewTend() external view returns (bool act, Stance target, uint256 p) {
        p = price();
        target = _desiredStance(p);
        act = rotationEnabled && target != stance && block.timestamp >= uint256(lastRotation) + params.cooldown;
    }

    /// @dev The state machine. Pure function of `p` and the stored reference prices.
    function _desiredStance(uint256 p) internal view returns (Stance) {
        Params memory q = params;

        if (stance == Stance.HoldBase) {
            // Waiting for quote to get cheap enough to be worth buying.
            if (q.enterQuoteDropBps == 0 || quoteExitPrice == 0) return Stance.HoldBase;
            if (p > Math.mulDiv(quoteExitPrice, BPS - q.enterQuoteDropBps, BPS)) return Stance.HoldBase;
            // Optional confirmation: only step in once the fall has visibly stopped.
            if (q.enterReboundBps != 0) {
                if (troughPrice == 0) return Stance.HoldBase;
                if (p < Math.mulDiv(troughPrice, BPS + q.enterReboundBps, BPS)) return Stance.HoldBase;
            }
            return Stance.HoldQuote;
        }

        // Holding quote: any ONE of these brings us home to base.
        if (q.exitQuoteGainBps != 0 && quoteEntryPrice != 0) {
            if (p >= Math.mulDiv(quoteEntryPrice, BPS + q.exitQuoteGainBps, BPS)) return Stance.HoldBase;
        }
        if (q.exitTrailingBps != 0 && peakPrice != 0) {
            if (p <= Math.mulDiv(peakPrice, BPS - q.exitTrailingBps, BPS)) return Stance.HoldBase;
        }
        if (q.exitStopLossBps != 0 && quoteEntryPrice != 0) {
            if (p <= Math.mulDiv(quoteEntryPrice, BPS - q.exitStopLossBps, BPS)) return Stance.HoldBase;
        }
        if (q.maxQuoteHold != 0 && block.timestamp >= uint256(lastRotation) + q.maxQuoteHold) {
            return Stance.HoldBase;
        }
        return Stance.HoldQuote;
    }

    // ════════════════════════════════ maintenance ════════════════════════════════

    /// @inheritdoc BaseStrategy
    /// @dev The keeper's entry point (`StrategyFacet.tend`). Records the running
    ///      extremes on every call — which is why tending on a schedule matters even
    ///      when no rotation fires: the trailing stop is only as good as the peak it
    ///      has actually seen.
    function _tend() internal override {
        uint256 p = price();
        _observe(p);

        if (!rotationEnabled) return;
        if (block.timestamp < uint256(lastRotation) + params.cooldown) return;

        Stance target = _desiredStance(p);
        if (target != stance) _rotate(target, p);
    }

    /// @dev Track the extreme that the stance we are IN cares about, and seed the
    ///      reference price the first time we ever see a price, so the first rotation
    ///      is measured from a real level instead of from zero.
    function _observe(uint256 p) internal {
        if (stance == Stance.HoldBase) {
            if (quoteExitPrice == 0) quoteExitPrice = p; // seed: today is the reference
            if (troughPrice == 0 || p < troughPrice) troughPrice = p;
        } else {
            if (peakPrice == 0 || p > peakPrice) peakPrice = p;
        }
    }

    function _rotate(Stance target, uint256 p) internal {
        uint256 amountIn;
        uint256 amountOut;

        if (target == Stance.HoldQuote) {
            amountIn = _unparkAllBase();
            if (amountIn == 0) return; // nothing allocated yet — just flip on the next tend
            amountOut = _swap(address(asset), address(quote), amountIn, assetDecimals, quoteDecimals);
            _parkQuote();

            stance = Stance.HoldQuote;
            quoteEntryPrice = p;
            peakPrice = p;
            troughPrice = 0;
        } else {
            amountIn = _unparkAllQuote();
            if (amountIn == 0) return;
            amountOut = _swap(address(quote), address(asset), amountIn, quoteDecimals, assetDecimals);
            _parkBase();

            stance = Stance.HoldBase;
            quoteExitPrice = p;
            troughPrice = p;
            peakPrice = 0;
        }

        lastRotation = uint64(block.timestamp);
        unchecked {
            ++rotations;
        }
        emit Rotated(target == Stance.HoldQuote ? Stance.HoldBase : Stance.HoldQuote, target, p, amountIn, amountOut);
    }

    /// @dev Swap a whole leg, floored at the ORACLE's valuation less `maxSlippageBps`.
    ///      The floor is what makes a rotation safe to trigger from a public keeper
    ///      call: the worst execution anyone can force is the slippage bound.
    function _swap(address from, address to, uint256 amount, uint8 fromDec, uint8 toDec)
        internal
        returns (uint256 received)
    {
        uint256 minOut = _floor(_convert(from, fromDec, amount, to, toDec));
        uint256 before = IERC20(to).balanceOf(address(this));
        IERC20(from).forceApprove(address(swapper), amount);
        swapper.swap(from, to, amount, minOut, from == address(asset) ? buyQuoteRoute : sellQuoteRoute);
        received = IERC20(to).balanceOf(address(this)) - before;
        require(received >= minOut, "MIN_OUT");
    }

    // ═══════════════════════════════ vault hooks ═════════════════════════════════

    function _invest(uint256 amount) internal override {
        if (stance == Stance.HoldBase) {
            _parkBase();
        } else {
            // Arriving capital joins the leg we are actually in, so the position never
            // holds a stray slice of the asset it has decided against.
            _swap(address(asset), address(quote), amount, assetDecimals, quoteDecimals);
            _parkQuote();
        }
    }

    function _divest(uint256 amount) internal override {
        if (stance == Stance.HoldBase) {
            uint256 loose = asset.balanceOf(address(this));
            if (loose < amount) _unparkBase(amount - loose);
            return;
        }

        // Holding quote: free enough quote to realize `amount` of base AFTER slippage,
        // then sell it. Any overshoot stays as base and is simply the next divest's
        // loose balance — never a loss.
        uint256 quoteNeeded = Math.mulDiv(
            _convert(address(asset), assetDecimals, amount, address(quote), quoteDecimals), BPS, BPS - maxSlippageBps
        );
        uint256 looseQuote = quote.balanceOf(address(this));
        if (looseQuote < quoteNeeded) _unparkQuote(quoteNeeded - looseQuote);

        uint256 available = quote.balanceOf(address(this));
        uint256 toSell = quoteNeeded < available ? quoteNeeded : available;
        if (toSell == 0) return;
        _swap(address(quote), address(asset), toSell, quoteDecimals, assetDecimals);
    }

    function _withdrawAll() internal override {
        _unparkAllBase();
        uint256 quoteHeld = _unparkAllQuote();
        if (quoteHeld == 0) return;

        // Best-effort on the emergency path: if the quote leg cannot be sold (no
        // liquidity, dead route, oracle down), the base leg still goes home and the
        // quote stays here, still counted in `positionValue`. Reverting instead would
        // block the vault's only guaranteed exit over one broken swap venue.
        try this.sellQuoteLeg(quoteHeld) {}
        catch {
            emit UnwindLegFailed(address(quote), quoteHeld);
        }
    }

    /// @dev External only so `_withdrawAll` can `try` it. Self-call, so the guard is
    ///      "this contract", not the vault.
    function sellQuoteLeg(uint256 amount) external {
        require(msg.sender == address(this), "ONLY_SELF");
        _swap(address(quote), address(asset), amount, quoteDecimals, assetDecimals);
    }

    // ══════════════════════════════════ value ════════════════════════════════════

    function _positionValue() internal view override returns (uint256) {
        return
            baseLegAssets() + _convert(address(quote), quoteDecimals, quoteLegAssets(), address(asset), assetDecimals);
    }

    /// @notice Base tokens held, loose plus parked.
    function baseLegAssets() public view returns (uint256) {
        uint256 total = asset.balanceOf(address(this));
        if (address(basePark) != address(0)) {
            total += basePark.convertToAssets(basePark.balanceOf(address(this)));
        }
        return total;
    }

    /// @notice Quote tokens held, loose plus parked.
    function quoteLegAssets() public view returns (uint256) {
        uint256 total = quote.balanceOf(address(this));
        if (address(quotePark) != address(0)) {
            total += quotePark.convertToAssets(quotePark.balanceOf(address(this)));
        }
        return total;
    }

    /// @notice Bounded by what the parks can actually release right now.
    function maxWithdraw() external view override returns (uint256) {
        uint256 baseAvail = asset.balanceOf(address(this));
        if (address(basePark) != address(0)) baseAvail += basePark.maxWithdraw(address(this));

        uint256 quoteAvail = quote.balanceOf(address(this));
        if (address(quotePark) != address(0)) quoteAvail += quotePark.maxWithdraw(address(this));

        return baseAvail + _convert(address(quote), quoteDecimals, quoteAvail, address(asset), assetDecimals);
    }

    // ═══════════════════════════════ leg parking ═════════════════════════════════

    function _parkBase() internal {
        if (address(basePark) == address(0)) return;
        uint256 bal = asset.balanceOf(address(this));
        if (bal == 0) return;
        asset.forceApprove(address(basePark), bal);
        basePark.deposit(bal, address(this));
    }

    function _parkQuote() internal {
        if (address(quotePark) == address(0)) return;
        uint256 bal = quote.balanceOf(address(this));
        if (bal == 0) return;
        quote.forceApprove(address(quotePark), bal);
        quotePark.deposit(bal, address(this));
    }

    function _unparkBase(uint256 amount) internal {
        if (address(basePark) == address(0) || amount == 0) return;
        uint256 avail = basePark.maxWithdraw(address(this));
        uint256 toPull = amount > avail ? avail : amount;
        if (toPull != 0) basePark.withdraw(toPull, address(this), address(this));
    }

    function _unparkQuote(uint256 amount) internal {
        if (address(quotePark) == address(0) || amount == 0) return;
        uint256 avail = quotePark.maxWithdraw(address(this));
        uint256 toPull = amount > avail ? avail : amount;
        if (toPull != 0) quotePark.withdraw(toPull, address(this), address(this));
    }

    function _unparkAllBase() internal returns (uint256) {
        if (address(basePark) != address(0)) {
            uint256 shares = basePark.balanceOf(address(this));
            if (shares != 0) basePark.redeem(shares, address(this), address(this));
        }
        return asset.balanceOf(address(this));
    }

    function _unparkAllQuote() internal returns (uint256) {
        if (address(quotePark) != address(0)) {
            uint256 shares = quotePark.balanceOf(address(this));
            if (shares != 0) quotePark.redeem(shares, address(this), address(this));
        }
        return quote.balanceOf(address(this));
    }

    // ══════════════════════════════════ admin ════════════════════════════════════

    /// @notice Swap routes for the two rotation legs. Set before the first tend.
    bytes public buyQuoteRoute; // base  -> quote
    bytes public sellQuoteRoute; // quote -> base

    event RoutesSet();

    function setRoutes(bytes calldata _buyQuoteRoute, bytes calldata _sellQuoteRoute) external onlyVault {
        buyQuoteRoute = _buyQuoteRoute;
        sellQuoteRoute = _sellQuoteRoute;
        emit RoutesSet();
    }

    function setParams(Params calldata p) external onlyVault {
        _setParams(p);
    }

    function _setParams(Params memory p) internal {
        // Bands must be real percentages, not "rotate on any tick" (which would just
        // pay the swap fee both ways forever) and not >= 100% (unreachable, or a
        // negative threshold once subtracted).
        require(p.enterQuoteDropBps < BPS && p.exitStopLossBps < BPS && p.exitTrailingBps < BPS, "BAND_TOO_WIDE");
        require(p.cooldown >= 1 hours, "COOLDOWN_TOO_SHORT");
        params = p;
        emit ParamsSet(p);
    }

    /// @notice Master switch. Off = the position stays exactly where it is and only
    ///         deposits/withdrawals move it — the safe state while retuning bands.
    function setRotationEnabled(bool enabled) external onlyVault {
        rotationEnabled = enabled;
        emit RotationEnabledSet(enabled);
    }

    /// @notice Governance override: rotate now, ignoring bands and cooldown.
    ///         The manual hand on a strategy whose whole job is timing.
    function forceStance(Stance target) external onlyVault nonReentrant {
        uint256 p = price();
        if (target != stance) _rotate(target, p);
        emit StanceForced(target, p);
    }
}
