// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {MultiRewardStrategy} from "./MultiRewardStrategy.sol";

/// @notice Convex/Aura/StakeDAO-shaped booster — stakes an LP into its reward gauge in
///         one call. Aura and StakeDAO's veCRV-locker products are Convex forks with
///         the same surface, so one interface serves all three.
interface ILpBooster {
    function deposit(uint256 pid, uint256 amount, bool stake) external returns (bool);
}

interface ILpBoosterRewards {
    function balanceOf(address account) external view returns (uint256); // staked LP
    function earned(address account) external view returns (uint256); // pending primary reward
    function getReward() external returns (bool); // claim the whole set to the caller
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
}

/**
 * @title  LpBoosterStrategy — for a vault whose BASE TOKEN IS AN LP TOKEN
 * @notice Users deposit the LP itself (a Curve LP, a Balancer BPT); this stakes it in
 *         a booster for BOOSTED emissions and sells those emissions back into more of
 *         the same LP, so the staked LP count per share grows.
 *
 *         Valuation is trivial here and that is the whole reason this is a separate
 *         file from `CurveConvexStrategy`: because the base token IS the LP, the staked
 *         balance is the position in base units, 1:1 — no virtual price, no oracle, no
 *         peg assumption anywhere in the accounting.
 *
 *   invest   : booster.deposit(pid, lp, stake = true)
 *   value    : rewards.balanceOf(this)             (staked LP == base units)
 *   divest   : rewards.withdrawAndUnwrap(lp, false) -> LP to this strategy -> vault
 *   harvest  : rewards.getReward() -> sell each emission back into LP -> vault
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE ORACLE REQUIREMENT (read before deploying)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Compounding sells volatile emissions (CRV/CVX, BAL/AURA, SDT) INTO the base LP, and
 *  every such sale is floored at the oracle's price of that LP. So the oracle MUST
 *  carry a FAIR-LP price for the base token — a fair-value reconstruction from the
 *  pool's invariant, never spot reserves, which a flash loan can move at will. Without
 *  it the reward is skipped and reported via `RewardSkipped`, never sold blind. The
 *  route itself is a ZAP: emission -> a pool coin -> add_liquidity -> LP.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY A BOOSTER INSTEAD OF THE NATIVE GAUGE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Staking through Convex/Aura adds their pooled veCRV/veBAL BOOST plus their own
 *  token (CVX/AURA/SDT) on top of the base emissions — materially more than staking
 *  the gauge directly, with no lock of our own. The staked position is an internal
 *  ledger keyed to the staker, so `receiptToken()` is `address(0)` and this strategy
 *  holds it; the vault controls it through divest/emergencyWithdraw as always.
 */
contract LpBoosterStrategy is MultiRewardStrategy {
    using SafeERC20 for IERC20;

    ILpBooster public immutable booster;
    ILpBoosterRewards public immutable rewardPool;
    uint256 public immutable pid;
    /// @notice The one emission whose accrual the gauge exposes in a view (CRV/BAL).
    address public immutable primaryReward;

    constructor(
        address _vault,
        address _lp, // base token == the LP / BPT
        address _oracle,
        address _swapper,
        address _booster,
        address _rewardPool,
        uint256 _pid,
        address _primaryReward,
        address[] memory _rewardTokens // [CRV, CVX] / [BAL, AURA] / ...
    ) MultiRewardStrategy(_vault, _lp, _oracle, _swapper, _rewardTokens) {
        require(_booster != address(0) && _rewardPool != address(0) && _primaryReward != address(0), "ZERO_ADDR");
        booster = ILpBooster(_booster);
        rewardPool = ILpBoosterRewards(_rewardPool);
        pid = _pid;
        primaryReward = _primaryReward;
    }

    /// @dev Internal-ledger venue (booster staking): no receipt token for the vault.
    function receiptToken() public pure override returns (address) {
        return address(0);
    }

    function _invest(uint256 amount) internal override {
        asset.forceApprove(address(booster), amount);
        booster.deposit(pid, amount, true);
    }

    function _divest(uint256 amount) internal override {
        uint256 staked = rewardPool.balanceOf(address(this));
        uint256 toPull = amount > staked ? staked : amount;
        if (toPull == 0) return;
        rewardPool.withdrawAndUnwrap(toPull, false); // LP (== base) to this strategy
    }

    function _withdrawAll() internal override {
        uint256 staked = rewardPool.balanceOf(address(this));
        if (staked == 0) return;
        rewardPool.withdrawAndUnwrap(staked, false);
    }

    function _positionValue() internal view override returns (uint256) {
        return rewardPool.balanceOf(address(this)); // staked LP == base units, 1:1
    }

    function _claimRewards() internal override {
        rewardPool.getReward();
    }

    function _pendingRewardAmount(address token) internal view override returns (uint256) {
        // Only the primary emission is readable; the booster's own token is minted on a
        // schedule with no view, so it is under-reported until it lands.
        return token == primaryReward ? rewardPool.earned(address(this)) : 0;
    }

    /// @notice LP currently staked in the booster.
    function stakedLpBalance() external view returns (uint256) {
        return rewardPool.balanceOf(address(this));
    }
}
