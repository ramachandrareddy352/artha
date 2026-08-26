// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UserRewardManager.sol";

/**
 * @title  UserRewardSystem
 * @notice The staking accrual layer. It knows "how many shares each user staked in
 *         each vault" and "how fast each vault's shares earn ARTHA". It holds no
 *         money and enforces no budget -- that is UserRewardVault's job.
 *
 *             UserRewardManager  <-  UserRewardSystem  <-  UserRewardVault
 *
 *  Each vault has one admin-set rate: ARTHA per share per second, 1e18 fixed point.
 *  A user's accrual does NOT depend on how many other users are staked in the same
 *  vault -- everybody earns their own shares' worth, independently. There is no
 *  totalStaked denominator anywhere in this file, and stake()/unstake() never touch
 *  vault-level state -- only the caller's own Position.
 *
 *  What there IS, is a per-vault running index -- `accRewardPerShare` -- that is the
 *  time-integral of the rate alone (NOT divided by totalStaked, unlike Synthetix /
 *  MasterChef's version of this same idea):
 *
 *      accRewardPerShare(t) = ∫ rewardRate(τ) dτ   for τ in [vault genesis, t]
 *
 *  It only has one job: remember exactly how the rate moved over time, so that a
 *  position which goes untouched across a rate change still gets charged the OLD
 *  rate for the OLD stretch and the NEW rate for the NEW stretch -- not the current
 *  rate applied to the whole gap. `_setRewardRate` (rate changes) is the ONLY thing
 *  that ever writes to it; a position's `_settle` only ever READS it.
 *
 *      accrued_since_last_settle = shares * (accRewardPerShare(now) - rewardDebt) / 1e18
 *
 *  `rewardDebt` is a position's `accRewardPerShare` snapshot at its own last touch --
 *  the "you were not here for this part" offset, same idea as rewardDebt in every
 *  Synthetix-derived design, just against a rate index instead of a pool index.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY stake()/unstake() NEVER TOUCH THE INDEX
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  In MasterChef, accRewardPerShare is divided by totalStaked, so it is a function of
 *  EVERY staker's balance -- any stake or unstake changes the denominator and forces
 *  a pool-wide checkpoint first. Here there is no division: accRewardPerShare is
 *  purely a function of TIME and RATE, neither of which a stake or unstake changes.
 *  So a user's own settle can read the index on the fly (`_currentAcc`, a pure view)
 *  without the index itself ever needing to be written outside of a rate change.
 *  Only `_setRewardRate` calls `_advanceAcc`, which is the one place old-rate time is
 *  permanently banked before the new rate starts contributing.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY THERE IS NO MUTATING _settle() HERE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `_accruedSince()` is a pure calculation: it reads a position and the rate index
 *  and returns what has been earned since the position's last touch. It does NOT
 *  write anything, on purpose -- crediting that amount means minting it against the
 *  programme's global ARTHA budget, and that budget lives one layer up in
 *  UserRewardVault (MAX_ARTHA). UserRewardVault._settle() does the banking, clamped,
 *  and moves the position's rewardDebt forward.
 */
contract UserRewardSystem is UserRewardManager {
    /**
     * @notice Hard ceiling on a vault's reward rate: 1 ARTHA per share per second.
     *
     *  Unbounded, this parameter is a one-way brick. The index advances as
     *  `accRewardPerShare += rewardRate * elapsed`, and that product is read on EVERY
     *  path — `_currentAcc` feeds `_accruedSince`, which `_settle` runs as the first
     *  statement of stake, unstake AND claim. A rate near `type(uint256).max` overflows
     *  one second later and reverts all three forever. The repair is dead too:
     *  `setRewardRate(0)` calls `_advanceAcc` first, which computes the same overflowing
     *  product. Every staked share would be locked permanently, and it needs no malice —
     *  a per-year figure pasted into a per-second field is enough.
     *
     *  1e18/share/second is already absurd (a single share earns 86,400 ARTHA a day),
     *  so this bounds the damage without constraining any real emission schedule.
     */
    uint256 public constant MAX_REWARD_RATE = 1e18;

    /**
     * @notice One user's staked position in one vault.
     * @param shares            Shares currently staked, 1e18 fixed point.
     * @param rewardDebt        accRewardPerShare snapshot at this position's last
     *                          settle. Growth in the index before this value is not
     *                          this position's to claim.
     * @param earnedArtha       Settled, unclaimed ARTHA.
     * @param totalEarnedArtha  Lifetime ARTHA ever earned here (includes claimed).
     * @param totalClaimedArtha Lifetime ARTHA ever withdrawn from here.
     */
    struct Position {
        uint256 shares;
        uint256 rewardDebt;
        uint256 earnedArtha;
        uint256 totalEarnedArtha;
        uint256 totalClaimedArtha;
    }

    /**
     * @notice One vault's rate history, folded into a running index.
     * @param rewardRate        Current ARTHA per share per second, 1e18 fixed point.
     * @param accRewardPerShare Cumulative ARTHA per share banked up to
     *                          `rateCheckpoint`, at the rates that were active along
     *                          the way. 1e18 fixed point.
     * @param rateCheckpoint    When accRewardPerShare was last advanced -- always a
     *                          past rate-change (or vault registration) timestamp.
     */
    struct Emission {
        uint256 rewardRate;
        uint256 accRewardPerShare;
        uint256 rateCheckpoint;
    }

    /// @notice vault => rate index.
    mapping(address => Emission) internal _emission;

    /// @notice vault => user => staked position.
    mapping(address => mapping(address => Position)) internal _position;

    /// @notice vault => total shares currently staked across every position.
    mapping(address => uint256) internal _totalStaked;

    /// @notice vault => Σ over positions of `shares × rewardDebt`, 1e18-scaled.
    ///
    ///  Kept alongside `_totalStaked` so the ACCRUED-BUT-UNSETTLED debt of a whole vault
    ///  can be read in O(1):
    ///
    ///      unsettled = (totalStaked × accNow − Σ shares·rewardDebt) / 1e18
    ///
    ///  which is exactly `Σ _accruedSince(user)` without iterating users. Without it,
    ///  the only debt the contract can see is what `_settle` has already banked — and a
    ///  staker who merely HOLDS a position accrues real, owed ARTHA that would be
    ///  invisible to `outstandingArtha()`, and therefore rescuable out from under them.
    mapping(address => uint256) internal _weightedDebt;

    event RewardRateUpdated(address indexed vault, uint256 oldRate, uint256 newRate);

    constructor(address _admin) UserRewardManager(_admin) {}

    // ─────────────────────────────── views ──────────────────────────────────────

    function positionOf(address vault, address user) external view returns (Position memory) {
        return _position[vault][user];
    }

    function emissionOf(address vault) external view returns (Emission memory) {
        return _emission[vault];
    }

    function rewardRateOf(address vault) external view returns (uint256) {
        return _emission[vault].rewardRate;
    }

    function stakedShares(address vault, address user) external view returns (uint256) {
        return _position[vault][user].shares;
    }

    // ────────────────────────── accrual internals ───────────────────────────────

    /// @dev The rate index as of right now: banked history plus the current rate's
    ///      contribution since its own last checkpoint. Pure read, no mutation.
    function _currentAcc(address _vault) internal view returns (uint256) {
        Emission storage e = _emission[_vault];
        uint256 elapsed = block.timestamp - e.rateCheckpoint;
        if (elapsed == 0) return e.accRewardPerShare;
        return e.accRewardPerShare + e.rewardRate * elapsed;
    }

    /// @dev Pure, uncapped ARTHA earned since a position's last settle. Reads only --
    ///      see the header for why this never writes state.
    function _accruedSince(address _vault, address _user) internal view returns (uint256) {
        Position storage pos = _position[_vault][_user];
        if (pos.shares == 0) return 0;

        uint256 acc = _currentAcc(_vault);
        if (acc <= pos.rewardDebt) return 0;

        return (pos.shares * (acc - pos.rewardDebt)) / 1e18;
    }

    /// @dev Accrued-but-unsettled ARTHA across EVERY position in one vault, computed in
    ///      O(1) from the two running sums. Uncapped by the programme budget — the
    ///      caller applies that clamp, exactly as `_settle` does per position.
    function _unsettledAccrual(address _vault) internal view returns (uint256) {
        uint256 staked = _totalStaked[_vault];
        if (staked == 0) return 0;

        uint256 gross = staked * _currentAcc(_vault);
        uint256 debt = _weightedDebt[_vault];
        if (gross <= debt) return 0;

        return (gross - debt) / 1e18;
    }

    /// @dev Move a position's `rewardDebt` to `newDebt`, keeping `_weightedDebt` in
    ///      step. Every write to `rewardDebt` must go through here.
    function _restampDebt(address _vault, Position storage pos, uint256 newDebt) internal {
        uint256 shares = pos.shares;
        if (shares != 0) {
            _weightedDebt[_vault] = _weightedDebt[_vault] + shares * newDebt - shares * pos.rewardDebt;
        }
        pos.rewardDebt = newDebt;
    }

    /// @dev Credit `amount` shares to a position that is already settled (so its
    ///      `rewardDebt` equals the live index).
    function _addShares(address _vault, Position storage pos, uint256 amount) internal {
        pos.shares += amount;
        _totalStaked[_vault] += amount;
        _weightedDebt[_vault] += amount * pos.rewardDebt;
    }

    /// @dev Remove `amount` shares from a position, at whatever `rewardDebt` it
    ///      currently carries — settled or not, so the emergency path can use it too.
    function _removeShares(address _vault, Position storage pos, uint256 amount) internal {
        pos.shares -= amount;
        _totalStaked[_vault] -= amount;
        uint256 weight = amount * pos.rewardDebt;
        uint256 current = _weightedDebt[_vault];
        _weightedDebt[_vault] = current > weight ? current - weight : 0;
    }

    /// @dev Permanently bank the current rate's contribution up to now, before
    ///      anything is allowed to change it. MUST run before `rewardRate` is
    ///      overwritten -- skip it and the stretch just banked silently vanishes,
    ///      overwritten by the new rate on the next read.
    function _advanceAcc(address _vault) internal {
        Emission storage e = _emission[_vault];
        uint256 elapsed = block.timestamp - e.rateCheckpoint;
        if (elapsed != 0) {
            e.accRewardPerShare += e.rewardRate * elapsed;
            e.rateCheckpoint = block.timestamp;
        }
    }

    /// @dev Set a vault's reward rate. Public entry point lives in
    ///      UserRewardVault.setRewardRate() (also used by registerVault()).
    function _setRewardRate(address _vault, uint256 _newRate) internal {
        require(_newRate <= MAX_REWARD_RATE, "RATE_TOO_HIGH");
        _advanceAcc(_vault);
        Emission storage e = _emission[_vault];
        uint256 old = e.rewardRate;
        e.rewardRate = _newRate;
        emit RewardRateUpdated(_vault, old, _newRate);
    }
}
