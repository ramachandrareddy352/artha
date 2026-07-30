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
 *  Optional: `_pendingRewardsValue`, `_harvestRewards`, `receiptToken`.
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
    event EmergencyWithdrawn(uint256 assets);
    event MaxSlippageSet(uint256 bps);

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

    /// @inheritdoc IStrategy
    function receiptToken() public view virtual override returns (address);

    // ─────────────────────────── vault actions ──────────────────────────────────

    function invest(uint256 assets) external override onlyVault nonReentrant {
        require(assets != 0, "ZERO");
        asset.safeTransferFrom(vault, address(this), assets);
        _invest(assets);
        // Return any base the venue didn't consume (rounding/min-deposit dust) so it
        // stays as the vault's idle instead of stranding in this stateless executor.
        uint256 dust = asset.balanceOf(address(this));
        if (dust != 0) asset.safeTransfer(vault, dust);
        emit Invested(assets);
    }

    function divest(uint256 assets) external override onlyVault nonReentrant returns (uint256 withdrawn) {
        require(assets != 0, "ZERO");
        uint256 before = asset.balanceOf(address(this));
        _divest(assets);
        withdrawn = asset.balanceOf(address(this)) - before;
        if (withdrawn != 0) asset.safeTransfer(vault, withdrawn);
        emit Divested(withdrawn);
    }

    function harvest() external override onlyVault nonReentrant returns (uint256 realized) {
        uint256 before = asset.balanceOf(address(this));
        _harvestRewards();
        realized = asset.balanceOf(address(this)) - before;
        if (realized != 0) asset.safeTransfer(vault, realized);
        emit Harvested(realized);
    }

    function emergencyWithdraw() external override onlyVault nonReentrant returns (uint256 withdrawn) {
        uint256 before = asset.balanceOf(address(this));
        _withdrawAll();
        withdrawn = asset.balanceOf(address(this)) - before;
        if (withdrawn != 0) asset.safeTransfer(vault, withdrawn);
        emit EmergencyWithdrawn(withdrawn);
    }

    // ─────────────────────────────── views ──────────────────────────────────────

    function positionValue() public view override returns (uint256) {
        return _positionValue() + _pendingRewardsValue();
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

        uint256 gross = Math.mulDiv(
            rewardAmount, rewardPrice * (10 ** assetDecimals), assetPrice * (10 ** rewardDecimals)
        );
        return (gross * (10_000 - REWARD_HAIRCUT_BPS)) / 10_000;
    }
}
