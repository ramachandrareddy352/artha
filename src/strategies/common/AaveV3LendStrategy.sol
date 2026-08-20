// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {MultiRewardStrategy} from "./MultiRewardStrategy.sol";

/// @notice Minimal Aave V3 Pool surface.
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getReserveData(address asset) external view returns (ReserveDataLegacy memory);
}

/// @dev Only the two fields this strategy reads are named meaningfully; the rest are
///      laid out to match Aave V3's `ReserveDataLegacy` so the decode is correct.
struct ReserveDataLegacy {
    uint256 configuration;
    uint128 liquidityIndex;
    uint128 currentLiquidityRate;
    uint128 variableBorrowIndex;
    uint128 currentVariableBorrowRate;
    uint128 currentStableBorrowRate;
    uint40 lastUpdateTimestamp;
    uint16 id;
    address aTokenAddress;
    address stableDebtTokenAddress;
    address variableDebtTokenAddress;
    address interestRateStrategyAddress;
    uint128 accruedToTreasury;
    uint128 unbacked;
    uint128 isolationModeTotalDebt;
}

/**
 * @notice Aave V3 liquidity-mining controller. Rewards accrue to whoever HOLDS the
 *         aToken — here, the vault — so claiming them requires this strategy to be the
 *         vault's registered claimer (`setClaimer`, an Aave emission-manager action).
 */
interface IAaveRewardsController {
    function claimAllRewardsOnBehalf(address[] calldata assets, address user, address to)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
    function getUserRewards(address[] calldata assets, address user, address reward) external view returns (uint256);
    function getAllUserRewards(address[] calldata assets, address user)
        external
        view
        returns (address[] memory rewardsList, uint256[] memory unclaimedAmounts);
    function getClaimer(address user) external view returns (address);
}

/**
 * @title  AaveV3LendStrategy — the Aave-shaped lending adapter, token-agnostic
 * @notice Supplies the base token to an Aave V3 (or Aave-V3-fork) market with the
 *         rebasing aToken receipt credited to the VAULT. One contract serves every
 *         asset and every fork — USDC, USDT, DAI, WETH, WBTC on Aave, Spark, Radiant,
 *         Seamless — because nothing here is token-specific.
 *
 *   invest   : pool.supply(asset, amount, onBehalfOf = VAULT, 0)  -> aToken to the vault
 *   value    : aToken.balanceOf(VAULT). The aToken REBASES, so the balance already
 *              includes every unit of accrued interest — no index math needed.
 *   divest   : pull the vault's aToken (transient allowance) into this strategy, then
 *              pool.withdraw(asset, amt, this); the base wrapper forwards it to the vault.
 *   harvest  : claim the VAULT's incentives on-behalf and sell them to base, via
 *              MultiRewardStrategy. A no-op on the many markets that pay none.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   INCENTIVES ARE ONLY COUNTED WHEN THEY ARE ACTUALLY CLAIMABLE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Because the aToken sits in the VAULT, the vault is the reward owner and only its
 *  registered claimer may claim on its behalf — and that registration is made by
 *  AAVE's emission manager, not by us. So both reward paths are gated on
 *  `getClaimer(vault) == address(this)`:
 *
 *    - unclaimed rewards count toward NAV only while we can actually realize them
 *      (otherwise the share price would carry value no holder could ever withdraw), and
 *    - `_claimRewards` stays silent rather than reverting when we are not the claimer,
 *      so an un-incentivized market harvests cleanly instead of failing every time.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHAT MAKES A WITHDRAWAL FAIL
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Aave reverts a withdraw when the reserve is PAUSED, or when utilization is so high
 *  that the pool's free liquidity is below the request. `maxWithdraw()` reports that
 *  real, live bound (position capped by the aToken's own underlying balance) so the
 *  vault's withdrawal queue can route around it, and the queue uses `tryDivestFrom`
 *  so a frozen reserve degrades to "this leg contributed nothing" instead of bricking
 *  every withdrawal in the vault.
 */
contract AaveV3LendStrategy is MultiRewardStrategy {
    using SafeERC20 for IERC20;

    IAaveV3Pool public immutable pool;
    IERC20 public immutable aToken; // rebasing 1:1 receipt, custodied by the VAULT

    IAaveRewardsController public rewardsController;

    event RewardsControllerSet(address controller);

    constructor(
        address _vault,
        address _asset,
        address _oracle,
        address _swapper,
        address _pool,
        address _aToken,
        address _rewardsController,
        address[] memory _rewardTokens
    ) MultiRewardStrategy(_vault, _asset, _oracle, _swapper, _rewardTokens) {
        require(_pool != address(0) && _aToken != address(0), "ZERO_ADDR");
        pool = IAaveV3Pool(_pool);
        aToken = IERC20(_aToken);
        rewardsController = IAaveRewardsController(_rewardsController);
    }

    function receiptToken() public view override returns (address) {
        return address(aToken);
    }

    // ─────────────────────────── invest / divest ────────────────────────────────

    function _invest(uint256 amount) internal override {
        asset.forceApprove(address(pool), amount);
        pool.supply(address(asset), amount, vault, 0); // aToken minted to the vault
    }

    function _divest(uint256 amount) internal override {
        uint256 held = aToken.balanceOf(vault);
        uint256 toWithdraw = amount > held ? held : amount;
        if (toWithdraw == 0) return;
        aToken.safeTransferFrom(vault, address(this), toWithdraw); // granted allowance
        pool.withdraw(address(asset), toWithdraw, address(this)); // base to this strategy
    }

    function _withdrawAll() internal override {
        uint256 held = aToken.balanceOf(vault);
        if (held == 0) return;
        aToken.safeTransferFrom(vault, address(this), held);
        // type(uint256).max withdraws the FULL aToken balance this strategy now holds,
        // including any interest that accrued between the transfer and this line.
        pool.withdraw(address(asset), type(uint256).max, address(this));
    }

    function _positionValue() internal view override returns (uint256) {
        return aToken.balanceOf(vault); // rebasing — the balance IS the value
    }

    /// @notice Bounded by the pool's free liquidity, not just by our position: an
    ///         Aave reserve at 100% utilization cannot pay a withdrawal of any size.
    function maxWithdraw() external view override returns (uint256) {
        uint256 position = aToken.balanceOf(vault);
        uint256 available = asset.balanceOf(address(aToken)); // the reserve's free liquidity
        return position < available ? position : available;
    }

    // ──────────────────────────────── rewards ───────────────────────────────────

    function _claimRewards() internal override {
        if (!_canClaim()) return;

        address[] memory assets = new address[](1);
        assets[0] = address(aToken);
        // Rewards belong to the VAULT (it holds the aToken); claim them to THIS
        // strategy so the engine above can sell them into base.
        rewardsController.claimAllRewardsOnBehalf(assets, vault, address(this));
    }

    function _pendingRewardAmount(address token) internal view override returns (uint256) {
        if (!_canClaim()) return 0; // see the header: unclaimable value is not NAV

        address[] memory assets = new address[](1);
        assets[0] = address(aToken);
        return rewardsController.getUserRewards(assets, vault, token);
    }

    /// @dev Are we the vault's registered claimer on this controller? Guarded so a
    ///      controller that does not implement `getClaimer` degrades to "no rewards"
    ///      instead of reverting valuation.
    function _canClaim() internal view returns (bool) {
        if (address(rewardsController) == address(0)) return false;
        try rewardsController.getClaimer(vault) returns (address claimer) {
            return claimer == address(this);
        } catch {
            return false;
        }
    }

    function setRewardsController(address _controller) external onlyVault {
        rewardsController = IAaveRewardsController(_controller);
        emit RewardsControllerSet(_controller);
    }

    /// @notice Every reward this market currently owes the vault, as the controller
    ///         reports it — for keepers sizing a harvest, and for spotting an emission
    ///         that is being paid but is not yet registered here.
    function allUnclaimedRewards() external view returns (address[] memory rewardsList, uint256[] memory amounts) {
        if (address(rewardsController) == address(0)) return (new address[](0), new uint256[](0));
        address[] memory assets = new address[](1);
        assets[0] = address(aToken);
        return rewardsController.getAllUserRewards(assets, vault);
    }

    /// @notice Live supply APR of this reserve, in ray (1e27) per year — the number the
    ///         allocator compares venues on.
    function supplyRateRay() external view returns (uint256) {
        return pool.getReserveData(address(asset)).currentLiquidityRate;
    }
}
