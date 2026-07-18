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
 * @title  BaseStrategy
 * @notice The shared skeleton every Artha strategy inherits. It fixes the lifecycle
 *         (deposit / withdraw / harvest / value) and the safety rules once, so a
 *         concrete strategy only fills in the four protocol-specific hooks.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ONE STRATEGY = ONE COMPOSITION, HOWEVER MANY PROTOCOLS IT TOUCHES
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  A strategy is one address the vault treats as a black box. Inside it may chain
 *  several protocols — e.g. deposit USDC to Curve, stake the LP in Convex, sell CRV
 *  and CVX, redeposit — but the vault only ever sees `deposit / withdraw / harvest /
 *  totalAssets`. That is why "invest in Curve then stake in Convex for extra yield"
 *  is ONE strategy slot, not two: the second protocol is an internal implementation
 *  detail hidden behind these hooks.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   VAULT-ONLY. NO KEEPER CAN FORCE A TINY HARVEST.
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Every money-moving function is `onlyVault`. Harvest especially: reward-selling
 *  costs gas and eats slippage, so harvesting a trivial amount is a net loss. Gating
 *  it to the vault means only the vault's own keeper flow — which decides WHEN it is
 *  economic — can trigger it. No third party can grief the position with dust harvests.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   VALUE = POSITION + PENDING REWARDS (counted continuously)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *      totalAssets = _positionValue() + _pendingRewardsValue()
 *
 *  Unclaimed reward tokens are counted into `totalAssets` AS THEY ACCRUE, valued via
 *  the oracle at a haircut. This is the anti-front-running rule: because pending
 *  rewards are already in the share price, the actual `harvest()` that realizes them
 *  is a price-per-share no-op — there is no reward "spike" for a depositor to jump in
 *  front of. (README §8.) When a venue makes pending rewards impossible to read in a
 *  view, a strategy under-reports them (returns less) rather than over-reports —
 *  under-reporting can never be gamed for profit.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHERE THE COMPOUNDED YIELD GOES (no new shares!)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `harvest()` claims rewards, swaps them to base, and reinvests via `_invest`. That
 *  raises `_positionValue` while the vault's share count is unchanged, so every
 *  holder's share simply becomes worth more. Reinvested yield NEVER mints shares —
 *  only a genuine outside deposit does.
 */
abstract contract BaseStrategy is IStrategy, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The base token (USDC, WETH, ...). Immutable per strategy.
    IERC20 public immutable override asset;
    /// @notice Cached decimals of `asset`, for reward valuation math.
    uint8 public immutable assetDecimals;
    /// @notice The Diamond. The only caller of every state-changing function.
    address public immutable override vault;
    /// @notice USD price feed (8dp) for valuing reward tokens and deriving swap floors.
    IPriceOracle public immutable oracle;
    /// @notice Reward-selling execution venue.
    ISwapper public immutable swapper;

    /// @notice Discount applied to unclaimed-reward value in `totalAssets`. Rewards are
    ///         worth less than face until sold: slippage, oracle lag, timing. Always
    ///         under-report. 200 = 2%.
    uint256 public constant REWARD_HAIRCUT_BPS = 200;

    /// @notice Max slippage strategies allow on their own LP/swap legs. Vault-settable,
    ///         hard-capped so a compromised setter cannot open the door to a full drain.
    uint256 public maxSlippageBps = 100; // 1%
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // 5% ceiling

    event Deposited(uint256 assets);
    event Withdrawn(uint256 assets);
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

    /// @dev Deploy `amount` of base token already held by this contract into the venue.
    function _invest(uint256 amount) internal virtual;

    /// @dev Free up to `amount` of base token from the venue back into this contract.
    ///      Returns the amount actually freed (never more than requested).
    function _divest(uint256 amount) internal virtual returns (uint256 freed);

    /// @dev Current venue position, valued in base token (principal + accrued interest).
    function _positionValue() internal view virtual returns (uint256);

    /// @dev Base-token value of unclaimed rewards, oracle-priced and haircut. 0 by
    ///      default (interest/appreciation strategies have no reward token).
    function _pendingRewardsValue() internal view virtual returns (uint256) {
        return 0;
    }

    /// @dev Claim reward tokens and swap them to base. Returns base realized. Does NOT
    ///      reinvest — the base wrapper does that. 0 by default.
    function _harvestRewards() internal virtual returns (uint256 realized) {
        return 0;
    }

    /// @dev Unwind the entire venue position to base token. Default: divest the whole
    ///      valued position. Override where the venue needs an exact "withdraw all".
    function _withdrawAll() internal virtual returns (uint256 freed) {
        return _divest(_positionValue());
    }

    // ─────────────────────────── vault actions ──────────────────────────────────

    function deposit(uint256 assets) external override onlyVault nonReentrant {
        require(assets != 0, "ZERO");
        asset.safeTransferFrom(vault, address(this), assets);
        _invest(assets);
        emit Deposited(assets);
    }

    function withdraw(uint256 assets) external override onlyVault nonReentrant returns (uint256 withdrawn) {
        require(assets != 0, "ZERO");
        withdrawn = _divest(assets);
        if (withdrawn != 0) asset.safeTransfer(vault, withdrawn);
        emit Withdrawn(withdrawn);
    }

    function harvest() external override onlyVault nonReentrant returns (uint256 realized) {
        realized = _harvestRewards();
        if (realized != 0) _invest(realized);
        emit Harvested(realized);
    }

    function emergencyWithdraw() external override onlyVault nonReentrant returns (uint256 withdrawn) {
        withdrawn = _withdrawAll();
        uint256 bal = asset.balanceOf(address(this));
        if (bal != 0) asset.safeTransfer(vault, bal);
        emit EmergencyWithdrawn(bal);
        return bal;
    }

    // ─────────────────────────────── views ──────────────────────────────────────

    function totalAssets() public view override returns (uint256) {
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
    ///      and haircut. Used both by `_pendingRewardsValue` (view) and to derive a
    ///      swap `minOut` at harvest.
    function _valueInAsset(address rewardToken, uint256 rewardAmount, uint8 rewardDecimals)
        internal
        view
        returns (uint256)
    {
        if (rewardAmount == 0) return 0;
        uint256 rewardPrice = oracle.getPrice(rewardToken); // 8dp USD
        uint256 assetPrice = oracle.getPrice(address(asset)); // 8dp USD
        if (rewardPrice == 0 || assetPrice == 0) return 0;

        // assetUnits = rewardAmount * rewardPrice * 10^assetDecimals
        //            / (assetPrice * 10^rewardDecimals)
        uint256 gross = Math.mulDiv(
            rewardAmount, rewardPrice * (10 ** assetDecimals), assetPrice * (10 ** rewardDecimals)
        );
        return (gross * (10_000 - REWARD_HAIRCUT_BPS)) / 10_000;
    }
}
