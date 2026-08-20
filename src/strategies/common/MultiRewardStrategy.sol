// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseStrategy} from "../BaseStrategy.sol";

/**
 * @title  MultiRewardStrategy — the shared reward engine
 * @notice Everything about EMISSIONS, in one place: the registry of which tokens a
 *         venue pays, what each is worth before it is claimed, the dust floor below
 *         which selling one is a net loss, the route it sells through, and the
 *         oracle-derived floor that sale must clear.
 *
 *         A concrete strategy inheriting this implements at most two hooks:
 *
 *           _claimRewards()                 : pull the venue's rewards INTO this
 *                                             strategy. (Nothing else — no selling.)
 *           _pendingRewardAmount(token)     : how much of `token` has accrued but is
 *                                             not yet claimed, in token units. 0 when
 *                                             the venue cannot be read in a view.
 *
 *         Everything below — valuation, thresholds, approvals, floors, the swap
 *         itself, the events — is handled here and is identical for every venue.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY PENDING REWARDS ARE IN THE SHARE PRICE BEFORE THEY ARE CLAIMED
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `positionValue()` = `_positionValue()` + `_pendingRewardsValue()`, so emissions
 *  are priced into NAV AS THEY ACCRUE (at a 2% haircut, `REWARD_HAIRCUT_BPS`). The
 *  `harvest()` that later realizes them is therefore close to a price-per-share
 *  no-op: there is no reward "spike" for a depositor to time. If pending rewards were
 *  only counted at harvest, anyone watching the mempool could deposit one block
 *  before the keeper's harvest and capture a slice of yield they were never staked
 *  for.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   VALUATION MUST NEVER REVERT; SELLING MUST NEVER PROCEED BLIND
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  These two paths treat a missing oracle price in OPPOSITE ways, on purpose:
 *
 *   - Valuation (`_pendingRewardsValue`, a view reached from the vault's NAV loop)
 *     SKIPS a token whose price cannot be read. A revert there would be caught by
 *     `LibVaultNav` as a failed position read, tripping this strategy's circuit
 *     breaker and auto-PAUSING the whole vault — an unpriced airdrop must not be able
 *     to do that. Skipping under-reports NAV, which is never exploitable.
 *
 *   - Selling (`_sellReward`) REFUSES to swap a token whose price cannot be read,
 *     because the oracle price IS the `minOut` floor. Falling back to a floor of 0
 *     would hand a sandwicher the entire harvest. An unsellable token simply stays
 *     put and is reported via `RewardSkipped` (governance can then set a route, add a
 *     price, or `rescue()` it to the vault).
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   DUST FLOORS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `minHarvest` (per reward token) is the amount below which claiming and selling
 *  costs more in gas and slippage than the reward is worth. Amounts under it are
 *  neither sold NOR counted into NAV — counting value the vault would never rationally
 *  realize would overstate the share price.
 */
abstract contract MultiRewardStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    struct Reward {
        bool registered;
        bool enabled; //   governance kill-switch per token
        uint8 decimals; //  cached at registration
        uint128 minHarvest; // dust floor, in reward-token units
        bytes route; //     venue-specific swap route (reward -> base)
    }

    /// @notice Every reward token this strategy knows about, in registration order.
    address[] public rewardTokens;
    mapping(address token => Reward) public rewards;

    event RewardRegistered(address indexed token, uint128 minHarvest);
    event RewardEnabledSet(address indexed token, bool enabled);
    event RewardRouteSet(address indexed token);
    event RewardMinHarvestSet(address indexed token, uint128 minHarvest);
    event RewardSold(address indexed token, uint256 amountIn, uint256 baseOut);
    event RewardSkipped(address indexed token, uint256 amount, string reason);
    event ClaimFailed();

    constructor(address _vault, address _asset, address _oracle, address _swapper, address[] memory _rewardTokens)
        BaseStrategy(_vault, _asset, _oracle, _swapper)
    {
        for (uint256 i; i < _rewardTokens.length; ++i) {
            _registerReward(_rewardTokens[i], 0);
        }
    }

    // ─────────────────────────── hooks for the venue ────────────────────────────

    /// @dev Claim the venue's rewards INTO this strategy. Selling is not your job.
    function _claimRewards() internal virtual {}

    /// @notice The claim step, exposed so `_harvestRewards` can `try` it — an internal
    ///         call cannot be caught, and this must never take a harvest down. Self-call
    ///         only; deliberately NOT `nonReentrant`, since `harvest()` already holds
    ///         that lock when it reaches here.
    function claimRewards() external {
        require(msg.sender == address(this), "ONLY_SELF");
        _claimRewards();
    }

    /// @dev Accrued-but-unclaimed `token`, in token units. Return 0 when the venue
    ///      exposes no view for it — under-reporting is safe, over-reporting is not.
    function _pendingRewardAmount(address token) internal view virtual returns (uint256) {
        token; // silence unused-parameter warning in the default implementation
        return 0;
    }

    // ──────────────────────────── the reward engine ─────────────────────────────

    /// @inheritdoc BaseStrategy
    /// @dev Counts BOTH sides of "not yet base": rewards still sitting at the venue,
    ///      and rewards already claimed into this strategy but not yet sold (a harvest
    ///      that claimed but could not sell, or a partially-routed reward set).
    function _pendingRewardsValue() internal view virtual override returns (uint256 total) {
        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = rewardTokens[i];
            Reward storage r = rewards[token];
            if (!r.enabled) continue;

            uint256 amount = _claimableAmount(token) + IERC20(token).balanceOf(address(this));
            if (amount < r.minHarvest) continue;

            (bool ok, uint256 value) = _tryValueInAsset(token, amount, r.decimals);
            if (ok) total += value;
        }
    }

    /// @inheritdoc BaseStrategy
    /// @dev The CLAIM is best-effort, for the same reason the sell is.
    ///
    ///      A venue can fail to pay emissions it has already promised — most commonly
    ///      because its distributor contract has simply RUN OUT of the reward token
    ///      (Compound's `CometRewards` is in exactly that state on mainnet today, and
    ///      reverts `claim` with "transfer amount exceeds balance"). If that revert
    ///      propagated, one under-funded third-party contract would take down far more
    ///      than the reward it failed to pay:
    ///
    ///        - `StrategyFacet.rebalance` harvests with hardRevert -> NO rebalance,
    ///          ever, for the whole vault;
    ///        - `removeStrategy` / `migrateStrategy` require the harvest to succeed ->
    ///          governance could not even RETIRE the affected strategy;
    ///        - `StrategyFacet.harvest` reverts outright.
    ///
    ///      So a failed claim is recorded and stepped over: the emission stays
    ///      unclaimed at the venue, every other reward in the set still sells, and the
    ///      whole thing is retried on the next harvest.
    function _harvestRewards() internal virtual override {
        try this.claimRewards() {}
        catch {
            emit ClaimFailed();
        }

        uint256 n = rewardTokens.length;
        for (uint256 i; i < n; ++i) {
            address token = rewardTokens[i];
            Reward storage r = rewards[token];
            if (!r.enabled) continue;

            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal == 0 || bal < r.minHarvest) continue;

            _sellReward(token, bal, r);
        }
    }

    /// @dev Sell `amount` of `token` for base, floored at the ORACLE's valuation of it
    ///      (already carrying the 2% reward haircut, which doubles as the slippage
    ///      allowance for these thin, volatile markets). Measures the base actually
    ///      received rather than trusting the swapper's return value.
    function _sellReward(address token, uint256 amount, Reward storage r) internal {
        if (token == address(asset)) return; // already base — nothing to sell

        (bool priced, uint256 minOut) = _tryValueInAsset(token, amount, r.decimals);
        if (!priced) {
            emit RewardSkipped(token, amount, "NO_PRICE");
            return;
        }

        uint256 before = asset.balanceOf(address(this));
        IERC20(token).forceApprove(address(swapper), amount);
        try swapper.swap(token, address(asset), amount, minOut, r.route) {
            uint256 received = asset.balanceOf(address(this)) - before;
            emit RewardSold(token, amount, received);
        } catch {
            // One unsellable reward (no liquidity, stale route, venue paused) must not
            // take the whole harvest down with it — the rest of the set still sells,
            // and this one is retried next harvest.
            IERC20(token).forceApprove(address(swapper), 0);
            emit RewardSkipped(token, amount, "SWAP_FAILED");
        }
    }

    /// @dev `_valueInAsset` with the oracle read made non-fatal. See the header for why
    ///      valuation may never revert but selling may never proceed unpriced.
    function _tryValueInAsset(address token, uint256 amount, uint8 decimals)
        internal
        view
        returns (bool ok, uint256 value)
    {
        uint256 gross;
        (ok, gross) = _tryConvert(token, decimals, amount, address(asset), assetDecimals);
        if (!ok) return (false, 0);
        return (true, (gross * (10_000 - REWARD_HAIRCUT_BPS)) / 10_000);
    }

    /// @dev `_pendingRewardAmount` made non-fatal for the same reason: a venue whose
    ///      pending-reward view reverts (paused, migrated, mis-wired) must not be able
    ///      to pause the vault through the NAV loop.
    function _claimableAmount(address token) internal view returns (uint256) {
        try this.pendingRewardAmount(token) returns (uint256 amount) {
            return amount;
        } catch {
            return 0;
        }
    }

    /// @notice Accrued-but-unclaimed `token` at the venue. External so the guarded
    ///         internal read above can `try` it; also useful to keepers directly.
    function pendingRewardAmount(address token) external view returns (uint256) {
        return _pendingRewardAmount(token);
    }

    // ─────────────────────────────── registry ───────────────────────────────────

    /// @notice Register a reward token this venue pays. Idempotent on the token, so it
    ///         doubles as "re-enable and re-floor" for one already known.
    function registerReward(address token, uint128 minHarvest) external onlyVault {
        _registerReward(token, minHarvest);
    }

    function _registerReward(address token, uint128 minHarvest) internal {
        require(token != address(0), "ZERO_REWARD");
        Reward storage r = rewards[token];
        if (!r.registered) {
            require(rewardTokens.length < 8, "TOO_MANY_REWARDS"); // bounds every loop above
            r.registered = true;
            r.decimals = IERC20Metadata(token).decimals();
            rewardTokens.push(token);
        }
        r.enabled = true;
        r.minHarvest = minHarvest;
        emit RewardRegistered(token, minHarvest);
    }

    /// @notice Stop claiming/valuing a reward token without forgetting its route.
    ///         The way to neutralize an emission that has become unsellable.
    function setRewardEnabled(address token, bool enabled) external onlyVault {
        require(rewards[token].registered, "UNKNOWN_REWARD");
        rewards[token].enabled = enabled;
        emit RewardEnabledSet(token, enabled);
    }

    /// @notice Set the swap route (venue-specific calldata) used to sell `token`.
    function setRewardRoute(address token, bytes calldata route) external onlyVault {
        require(rewards[token].registered, "UNKNOWN_REWARD");
        rewards[token].route = route;
        emit RewardRouteSet(token);
    }

    /// @notice Set the amount below which `token` is neither sold nor counted in NAV.
    function setRewardMinHarvest(address token, uint128 minHarvest) external onlyVault {
        require(rewards[token].registered, "UNKNOWN_REWARD");
        rewards[token].minHarvest = minHarvest;
        emit RewardMinHarvestSet(token, minHarvest);
    }

    function rewardTokensLength() external view returns (uint256) {
        return rewardTokens.length;
    }

    /// @notice The reward route for `token` — `rewards()` cannot return the bytes.
    function rewardRoute(address token) external view returns (bytes memory) {
        return rewards[token].route;
    }
}
