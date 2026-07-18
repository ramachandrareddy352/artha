// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseStrategy} from "../../BaseStrategy.sol";

/// @notice Minimal Aave V3 Pool surface.
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @notice Aave V3 liquidity-mining controller (optional; many markets have none).
interface IAaveRewardsController {
    function claimAllRewards(address[] calldata assets, address to)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}

/**
 * @title  AaveV3UsdcStrategy  —  the reference Shape-1 strategy
 * @notice Supplies USDC to Aave V3 and earns borrower-paid interest. The simplest,
 *         lowest-risk strategy in the stack and the template every other lending
 *         adapter follows.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW WE INVEST
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   invest   : pool.supply(USDC, amount, this, 0)  -> Aave mints aUSDC to this
 *              contract, 1:1 with the USDC supplied.
 *   value    : aUSDC.balanceOf(this). aUSDC REBASES — its balance grows every block
 *              as borrowers pay interest — so the balance itself IS the current worth
 *              in USDC. No price conversion, no share math (this is Shape 1: "balance
 *              grows, price fixed").
 *   withdraw : pool.withdraw(USDC, amount, this). Instant and exact as long as Aave
 *              has free liquidity (it almost always does for USDC). Returns the amount
 *              actually withdrawn.
 *   harvest  : Aave's core USDC market usually has NO reward token. If a market does
 *              run incentives, set the rewards controller and this claims them and
 *              swaps to USDC. With no controller set, harvest is a no-op — the yield
 *              is already in the rebasing aUSDC balance.
 *   settle   : none — interest accrues continuously into the aUSDC balance; the vault
 *              reads it live via totalAssets whenever it prices shares.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW YIELD IS GENERATED
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Borrowers over-collateralize and pay a utilization-driven interest rate; Aave
 *  streams that to suppliers by rebasing aUSDC upward. Higher borrow demand -> higher
 *  supply APY. There is no lock, no emission token to babysit, and exit is immediate —
 *  which is exactly why this is the "do first" strategy and the buffer-liquidity
 *  workhorse.
 */
contract AaveV3UsdcStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IAaveV3Pool public immutable pool;
    IERC20 public immutable aToken; // aUSDC — rebasing 1:1 receipt

    /// @notice Optional. address(0) => the market runs no incentives; harvest no-ops.
    IAaveRewardsController public rewardsController;

    event RewardsControllerSet(address controller);

    constructor(
        address _vault,
        address _asset, // USDC
        address _oracle,
        address _swapper,
        address _pool,
        address _aToken
    ) BaseStrategy(_vault, _asset, _oracle, _swapper) {
        require(_pool != address(0) && _aToken != address(0), "ZERO_ADDR");
        pool = IAaveV3Pool(_pool);
        aToken = IERC20(_aToken);
    }

    function _invest(uint256 amount) internal override {
        asset.forceApprove(address(pool), amount);
        pool.supply(address(asset), amount, address(this), 0);
    }

    function _divest(uint256 amount) internal override returns (uint256 freed) {
        uint256 held = aToken.balanceOf(address(this));
        uint256 toWithdraw = amount > held ? held : amount;
        if (toWithdraw == 0) return 0;
        // Aave returns the exact amount withdrawn.
        freed = pool.withdraw(address(asset), toWithdraw, address(this));
    }

    function _positionValue() internal view override returns (uint256) {
        return aToken.balanceOf(address(this)); // rebasing, already in USDC terms
    }

    function _withdrawAll() internal override returns (uint256 freed) {
        if (aToken.balanceOf(address(this)) == 0) return 0;
        // type(uint256).max tells Aave to withdraw the entire balance.
        freed = pool.withdraw(address(asset), type(uint256).max, address(this));
    }

    /// @dev If the market runs incentives, claim all reward tokens and swap each to
    ///      USDC. With no controller, returns 0 and harvest is a no-op.
    function _harvestRewards() internal override returns (uint256 realized) {
        if (address(rewardsController) == address(0)) return 0;

        address[] memory assets = new address[](1);
        assets[0] = address(aToken);
        (address[] memory rewards, uint256[] memory amounts) =
            rewardsController.claimAllRewards(assets, address(this));

        for (uint256 i; i < rewards.length; ++i) {
            if (rewards[i] == address(asset) || amounts[i] == 0) {
                if (rewards[i] == address(asset)) realized += amounts[i];
                continue;
            }
            realized += _sellReward(rewards[i], amounts[i]);
        }
    }

    /// @dev Sell a claimed reward token to USDC, flooring minOut at the oracle value.
    ///      Route bytes are pre-set per reward by the vault (see setSwapRoute).
    mapping(address => bytes) public swapRoute;

    function setSwapRoute(address reward, bytes calldata route) external onlyVault {
        swapRoute[reward] = route;
    }

    function _sellReward(address reward, uint256 amount) internal returns (uint256) {
        uint256 minOut = _valueInAsset(reward, amount, IERC20MetadataLike(reward).decimals());
        IERC20(reward).forceApprove(address(swapper), amount);
        return swapper.swap(reward, address(asset), amount, minOut, swapRoute[reward]);
    }

    function setRewardsController(address _controller) external onlyVault {
        rewardsController = IAaveRewardsController(_controller);
        emit RewardsControllerSet(_controller);
    }
}

/// @dev tiny local decimals reader to avoid an extra import in the reward path.
interface IERC20MetadataLike {
    function decimals() external view returns (uint8);
}
