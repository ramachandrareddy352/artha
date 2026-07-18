// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseStrategy} from "../BaseStrategy.sol";

/// @notice Convex/Aura-shaped booster (stakes an LP into its reward gauge in one call).
///         Aura and StakeDAO's veCRV-locker products are Convex forks with the same
///         surface, so this one interface serves all three.
interface ILpBooster {
    function deposit(uint256 pid, uint256 amount, bool stake) external returns (bool);
}

interface ILpBoosterRewards {
    function balanceOf(address account) external view returns (uint256); // staked LP
    function getReward() external returns (bool); // claim all reward tokens to caller
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
}

/**
 * @title  LpBoosterStrategy  —  stake an LP token in Convex / Aura / StakeDAO
 * @notice For a vault whose BASE TOKEN IS AN LP TOKEN (a Curve LP or a Balancer BPT).
 *         Users deposit the LP; this stakes it in the booster for BOOSTED emissions,
 *         then compounds those emissions back into more of the same LP.
 *
 *  Because the base token IS the LP, valuation is trivial — the staked balance is the
 *  position in base units, no virtual-price or oracle needed for the position itself.
 *  (Contrast CurveConvexUsdcStrategy, where the base is USDC and the LP must be minted
 *  and valued.)
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   LIFECYCLE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   invest   : booster.deposit(pid, lp, stake=true)
 *   value    : rewards.balanceOf(this)  (staked LP == base units, 1:1)
 *   withdraw : rewards.withdrawAndUnwrap(lp, claim=false)  -> LP back to vault
 *   harvest  : rewards.getReward() -> for each reward token, swap reward -> LP via the
 *              swapper (a ZAP route: reward -> pool coin -> add_liquidity/join -> LP),
 *              then the base wrapper re-stakes the new LP. Vault-only.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE MINOUT REQUIREMENT (read before deploying)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Compounding sells volatile emissions (CRV/CVX, BAL/AURA, SDT) into the LP. The
 *  swap floor is derived from the oracle's price of the BASE LP token — so the oracle
 *  MUST expose a FAIR-LP price for it (constant-product fair pricing, not spot
 *  reserves). If it does not, `_valueInAsset` reverts and harvest fails by design:
 *  never compound emissions without a real slippage floor. Configure the LP price
 *  before enabling harvest.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   HOW YIELD IS AMPLIFIED
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Staking via a booster instead of the native gauge adds the booster's pooled
 *  veCRV/veBAL BOOST plus its own token (CVX/AURA/SDT) on top of base emissions —
 *  materially higher than native staking. Compounding turns that into a rising LP
 *  balance per share.
 */
contract LpBoosterStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    ILpBooster public immutable booster;
    ILpBoosterRewards public immutable rewards;
    uint256 public immutable pid;

    /// @notice Emission tokens this gauge pays (e.g. [CRV, CVX] or [BAL, AURA]).
    address[] public rewardTokens;
    /// @notice reward token => zap route bytes (reward -> base LP).
    mapping(address => bytes) public rewardRoute;

    event RewardRouteSet(address indexed reward);

    constructor(
        address _vault,
        address _lp, // base token = the LP / BPT
        address _oracle,
        address _swapper,
        address _booster,
        address _rewards,
        uint256 _pid,
        address[] memory _rewardTokens
    ) BaseStrategy(_vault, _lp, _oracle, _swapper) {
        require(_booster != address(0) && _rewards != address(0), "ZERO_ADDR");
        booster = ILpBooster(_booster);
        rewards = ILpBoosterRewards(_rewards);
        pid = _pid;
        for (uint256 i; i < _rewardTokens.length; ++i) {
            require(_rewardTokens[i] != address(0), "ZERO_REWARD");
            rewardTokens.push(_rewardTokens[i]);
        }
    }

    function _invest(uint256 amount) internal override {
        asset.forceApprove(address(booster), amount);
        booster.deposit(pid, amount, true);
    }

    function _divest(uint256 amount) internal override returns (uint256 freed) {
        uint256 staked = rewards.balanceOf(address(this));
        uint256 toPull = amount > staked ? staked : amount;
        if (toPull == 0) return 0;
        uint256 before = asset.balanceOf(address(this));
        rewards.withdrawAndUnwrap(toPull, false);
        freed = asset.balanceOf(address(this)) - before;
    }

    function _withdrawAll() internal override returns (uint256 freed) {
        uint256 staked = rewards.balanceOf(address(this));
        if (staked == 0) return 0;
        uint256 before = asset.balanceOf(address(this));
        rewards.withdrawAndUnwrap(staked, false);
        freed = asset.balanceOf(address(this)) - before;
    }

    function _positionValue() internal view override returns (uint256) {
        return rewards.balanceOf(address(this)); // staked LP == base units
    }

    function _harvestRewards() internal override returns (uint256 realized) {
        rewards.getReward();
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address r = rewardTokens[i];
            uint256 bal = IERC20(r).balanceOf(address(this));
            if (bal == 0) continue;
            // minOut floored at the oracle's fair-LP value of `bal` reward — reverts if
            // no LP price is configured (intentional; see the header).
            uint256 minOut = _valueInAsset(r, bal, IERC20Metadata(r).decimals());
            IERC20(r).forceApprove(address(swapper), bal);
            realized += swapper.swap(r, address(asset), bal, minOut, rewardRoute[r]);
        }
    }

    function setRewardRoute(address reward, bytes calldata route) external onlyVault {
        rewardRoute[reward] = route;
        emit RewardRouteSet(reward);
    }

    function rewardTokensLength() external view returns (uint256) {
        return rewardTokens.length;
    }
}
