// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";

/**
 * @title  BaseStrategy — stateless executor
 * @notice The shared skeleton every Artha strategy inherits. A strategy
 *         CUSTODIES NOTHING: every venue receipt is credited to the VAULT, and
 *         every redemption returns base token to the VAULT. Base token only ever
 *         passes through the strategy transiently within a single call.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE FOUR HOOKS (a concrete strategy fills these in)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   _invest(amount)      : base is already in THIS strategy (pulled from the
 *                          vault by `invest`); deposit it into the venue with the
 *                          receipt credited to the VAULT (onBehalfOf/receiver=vault).
 *   _divest(amount)      : redeem up to `amount` base from the vault's venue
 *                          position, delivering the base into THIS strategy (the
 *                          base wrapper forwards it to the vault).
 *   _withdrawAll()       : unwind the vault's entire position to base into THIS
 *                          strategy (the wrapper forwards to the vault).
 *   _positionValue()     : value of the VAULT's venue position, in base.
 *
 *  Optional: `_pendingRewardsValue`, `_harvestRewards`, `_tend`, `receiptToken`.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE ONE EXCEPTION: BASE-CUSTODYING STRATEGIES
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  A strategy whose POSITION can legitimately be plain base token sitting in the
 *  strategy — a rotation/hold strategy parked on its base leg — overrides
 *  `_custodiesBase()` to true. That single flag changes three things, because the
 *  usual balance-DELTA settlement is meaningless when the strategy's resting
 *  balance is itself the position:
 *
 *    invest  : the post-invest dust sweep is skipped (it would claw the whole
 *              position back to the vault the moment the strategy holds base).
 *    divest  : settles on `min(requested, balance)` rather than on the delta.
 *    exit    : `emergencyWithdraw` sends the whole balance, not the delta.
 *
 *  `harvest` still settles on the delta in BOTH modes: reward proceeds are the only
 *  thing that can raise the base balance during a harvest, so the delta measures
 *  exactly what was realized without disturbing the resting position.
 *
 *  Such a strategy must NEVER let its position be base token held by the VAULT —
 *  that is `idleBalance`, and counting it in `positionValue()` too would double-count
 *  it into NAV. The same rule holds for every receipt: exactly one registered
 *  strategy may report a given token balance as its position.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   VAULT-ONLY. RECEIPTS IN THE VAULT.
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Every money-moving function is `onlyVault`. To divest, the vault grants this
 *  strategy transient access to the receipt token (an ERC-20 approval, done by
 *  `LibStrategyRegistry.divestFrom`), which `_divest`/`_withdrawAll` consume.
 */
abstract contract BaseStrategy is IStrategy, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable override asset;
    uint8 public immutable assetDecimals;
    /// @notice The vault this strategy serves — the only caller and the custodian.
    address public immutable override vault;
    IPriceOracle public immutable oracle;
    ISwapper public immutable swapper;

    /// @notice Discount applied to unclaimed-reward value in `positionValue`. 200 = 2%.
    uint256 public constant REWARD_HAIRCUT_BPS = 200;

    uint256 public maxSlippageBps = 100; // 1%
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // 5% ceiling

    event Invested(uint256 assets);
    event Divested(uint256 assets);
    event Harvested(uint256 realized);
    event Tended();
    event EmergencyWithdrawn(uint256 assets);
    event MaxSlippageSet(uint256 bps);
    event Rescued(address indexed token, uint256 amount);

    modifier onlyVault() {
        require(msg.sender == vault, "NOT_VAULT");
        _;
    }

    constructor(address _vault, address _asset, address _oracle, address _swapper) {
        require(_vault != address(0) && _asset != address(0), "ZERO_ADDR");
        vault = _vault;
        asset = IERC20(_asset);
        assetDecimals = IERC20Metadata(_asset).decimals();
        oracle = IPriceOracle(_oracle);
        swapper = ISwapper(_swapper);
    }

    // ─────────────────────── protocol hooks (override) ──────────────────────────

    /// @dev Deploy `amount` of base (already in this strategy) into the venue,
    ///      crediting the receipt to the VAULT.
    function _invest(uint256 amount) internal virtual;

    /// @dev Free up to `amount` of base from the vault's venue position INTO this
    ///      strategy (the wrapper forwards it to the vault).
    function _divest(uint256 amount) internal virtual;

    /// @dev Current venue position (owned by the vault), valued in base token.
    function _positionValue() internal view virtual returns (uint256);

    /// @dev Base value of unclaimed rewards, oracle-priced and haircut. 0 default.
    function _pendingRewardsValue() internal view virtual returns (uint256) {
        return 0;
    }

    /// @dev Claim rewards and swap them to base INTO this strategy. 0 default.
    function _harvestRewards() internal virtual {}

    /// @dev Unwind the vault's entire venue position to base INTO this strategy.
    function _withdrawAll() internal virtual;

    /// @dev Position maintenance that neither takes base from nor returns base to the
    ///      vault (a rotation between legs, a re-park). No-op default.
    function _tend() internal virtual {}

    /// @dev True when plain base token resting in THIS strategy is the position rather
    ///      than un-deployed dust. See the header — it switches invest/divest/exit
    ///      settlement from delta-based to balance-based.
    function _custodiesBase() internal view virtual returns (bool) {
        return false;
    }

    /// @inheritdoc IStrategy
    function receiptToken() public view virtual override returns (address);

    // ─────────────────────────── vault actions ──────────────────────────────────

    function invest(uint256 assets) external override onlyVault nonReentrant {
        require(assets != 0, "ZERO");
        asset.safeTransferFrom(vault, address(this), assets);
        _invest(assets);
        // Return any base the venue didn't consume (rounding/min-deposit dust) so it
        // stays as the vault's idle instead of stranding in this stateless executor.
        // Skipped for a base-custodying strategy, where the resting balance IS the
        // position and this sweep would undo the entire investment.
        if (!_custodiesBase()) {
            uint256 dust = asset.balanceOf(address(this));
            if (dust != 0) asset.safeTransfer(vault, dust);
        }
        emit Invested(assets);
    }

    function divest(uint256 assets) external override onlyVault nonReentrant returns (uint256 withdrawn) {
        require(assets != 0, "ZERO");
        if (_custodiesBase()) {
            _divest(assets);
            // The strategy's resting base balance is part of the position, so a delta
            // would read 0 whenever the position was ALREADY base. Settle on what is
            // actually available instead, capped at what the vault asked for.
            uint256 bal = asset.balanceOf(address(this));
            withdrawn = assets < bal ? assets : bal;
        } else {
            uint256 before = asset.balanceOf(address(this));
            _divest(assets);
            withdrawn = asset.balanceOf(address(this)) - before;
        }
        if (withdrawn != 0) asset.safeTransfer(vault, withdrawn);
        emit Divested(withdrawn);
    }

    function harvest() external override onlyVault nonReentrant returns (uint256 realized) {
        // Delta in BOTH modes: only reward proceeds can move the base balance here, so
        // the delta is exactly what was realized, resting position or not.
        uint256 before = asset.balanceOf(address(this));
        _harvestRewards();
        realized = asset.balanceOf(address(this)) - before;
        if (realized != 0) asset.safeTransfer(vault, realized);
        emit Harvested(realized);
    }

    function tend() external override onlyVault nonReentrant {
        _tend();
        emit Tended();
    }

    function emergencyWithdraw() external override onlyVault nonReentrant returns (uint256 withdrawn) {
        if (_custodiesBase()) {
            _withdrawAll();
            withdrawn = asset.balanceOf(address(this)); // everything, not the delta
        } else {
            uint256 before = asset.balanceOf(address(this));
            _withdrawAll();
            withdrawn = asset.balanceOf(address(this)) - before;
        }
        if (withdrawn != 0) asset.safeTransfer(vault, withdrawn);
        emit EmergencyWithdrawn(withdrawn);
    }

    // ─────────────────────────────── views ──────────────────────────────────────

    function positionValue() public view override returns (uint256) {
        return _positionValue() + _pendingRewardsValue();
    }

    function pendingRewardsValue() external view override returns (uint256) {
        return _pendingRewardsValue();
    }

    function maxWithdraw() external view virtual override returns (uint256) {
        return _positionValue();
    }

    // ─────────────────────────────── admin ──────────────────────────────────────

    function setMaxSlippageBps(uint256 _bps) external onlyVault {
        require(_bps <= MAX_SLIPPAGE_BPS, "SLIPPAGE_TOO_HIGH");
        maxSlippageBps = _bps;
        emit MaxSlippageSet(_bps);
    }

    /// @notice Sweep a token that is NOT part of this strategy's position back to the
    ///         vault — an airdrop, a reward with no configured route, a leftover leg
    ///         from a partially-failed swap.
    /// @dev    The destination is hard-coded to the vault, so this is not an exfil
    ///         path: the worst a compromised governance call achieves is moving a
    ///         stray token to the custodian that already owns it. Position tokens are
    ///         refused outright (`_isProtectedToken`), because sweeping one would
    ///         silently move value out of `positionValue()` and into un-tracked idle.
    function rescue(address token) external onlyVault nonReentrant returns (uint256 amount) {
        require(!_isProtectedToken(token), "PROTECTED_TOKEN");
        amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) IERC20(token).safeTransfer(vault, amount);
        emit Rescued(token, amount);
    }

    /// @dev Tokens that make up this strategy's position and must never be swept.
    ///      Base token counts only where the strategy custodies it as its position;
    ///      elsewhere a stray base balance is dust the vault should get back.
    function _isProtectedToken(address token) internal view virtual returns (bool) {
        if (token == address(asset)) return _custodiesBase();
        return token == receiptToken();
    }

    // ────────────────────────────── internal ────────────────────────────────────

    /// @dev Value `rewardAmount` of `rewardToken` in base-token units, oracle-priced
    ///      and haircut. Used to derive a swap `minOut` at harvest.
    function _valueInAsset(address rewardToken, uint256 rewardAmount, uint8 rewardDecimals)
        internal
        view
        returns (uint256)
    {
        if (rewardAmount == 0) return 0;
        uint256 rewardPrice = oracle.getPrice(rewardToken); // 8dp USD
        uint256 assetPrice = oracle.getPrice(address(asset)); // 8dp USD
        if (rewardPrice == 0 || assetPrice == 0) return 0;

        uint256 gross =
            Math.mulDiv(rewardAmount, rewardPrice * (10 ** assetDecimals), assetPrice * (10 ** rewardDecimals));
        return (gross * (10_000 - REWARD_HAIRCUT_BPS)) / 10_000;
    }

    /// @dev Convert `amount` of `from` into `to` units at ORACLE prices (no haircut).
    ///      The one conversion every cross-asset strategy uses — for valuation, and to
    ///      derive the `minOut` floor of the swap that realizes it. Reverts rather than
    ///      returning 0 when either price is missing: a silent 0 here would become a
    ///      `minOut` of 0, which is an unbounded-slippage swap.
    function _convert(address from, uint8 fromDecimals, uint256 amount, address to, uint8 toDecimals)
        internal
        view
        returns (uint256)
    {
        if (amount == 0) return 0;
        if (from == to) return amount;
        uint256 pFrom = oracle.getPrice(from); // 8dp USD
        uint256 pTo = oracle.getPrice(to); // 8dp USD
        require(pFrom != 0 && pTo != 0, "NO_PRICE");
        return Math.mulDiv(amount, pFrom * (10 ** toDecimals), pTo * (10 ** fromDecimals));
    }

    /// @dev `_convert` with the oracle reads made non-fatal, for the paths that must
    ///      degrade instead of revert — chiefly anything reachable from the vault's NAV
    ///      loop, where a revert trips this strategy's circuit breaker and pauses the
    ///      whole vault. Callers that use the result as a swap floor MUST refuse to
    ///      swap when `ok` is false rather than treating 0 as "no minimum".
    function _tryConvert(address from, uint8 fromDecimals, uint256 amount, address to, uint8 toDecimals)
        internal
        view
        returns (bool ok, uint256 value)
    {
        if (amount == 0) return (true, 0);
        if (from == to) return (true, amount);

        uint256 pFrom;
        uint256 pTo;
        try oracle.getPrice(from) returns (uint256 p) {
            pFrom = p;
        } catch {
            return (false, 0);
        }
        try oracle.getPrice(to) returns (uint256 p) {
            pTo = p;
        } catch {
            return (false, 0);
        }
        if (pFrom == 0 || pTo == 0) return (false, 0);

        return (true, Math.mulDiv(amount, pFrom * (10 ** toDecimals), pTo * (10 ** fromDecimals)));
    }

    /// @dev `expected` less the strategy's slippage tolerance — the floor handed to
    ///      every swapper call. Never derived from the venue's own quote.
    function _floor(uint256 expected) internal view returns (uint256) {
        return (expected * (10_000 - maxSlippageBps)) / 10_000;
    }
}
