// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "./UserRewardSystem.sol";

/**
 * @title  UserRewardVault
 * @notice Custodies staked vault shares and pays out ARTHA earned flat per share,
 *         against a rate that can change over time without mispricing anyone.
 *
 *             UserRewardManager  <-  UserRewardSystem  <-  UserRewardVault (deployed)
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHAT A USER ACTUALLY GETS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Hold vault shares -> earn vault yield. That is the vault's job, untouched by this.
 *  STAKE those shares here -> earn ARTHA on top, per share, priced against however
 *  the vault's rate has moved since this position was last settled:
 *
 *      earned += shares * (accRewardPerShare(now) - rewardDebt) / 1e18
 *
 *  `accRewardPerShare` is UserRewardSystem's rate-time index -- see its header for
 *  why a rate change is banked into it immediately, so a position that goes untouched
 *  across a rate change is still charged the OLD rate for the OLD stretch and the NEW
 *  rate for the NEW one, never the current rate for the whole gap. It does not depend
 *  on how much anyone else has staked -- there is still no totalStaked anywhere.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   STAKING FOR SOMEONE ELSE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  stake(vault, user, amount) pulls `amount` shares from msg.sender but credits the
 *  position to `user`. Anyone may stake on another user's behalf this way. From then
 *  on the position belongs to `user` alone: only `user` can unstake it or claim its
 *  ARTHA. The payer has no further claim on it.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE 10M CAP IS ENFORCED AT ACCRUAL, NOT AT CLAIM
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  MAX_ARTHA (10,000,000e18) is this programme's lifetime budget, separate from the
 *  referral programme's identical one.
 *
 *  It is charged the moment ARTHA is EARNED (in _settle), not when it is claimed.
 *  Clamping only at claim would let the books accrue promises beyond a 10M budget
 *  and break the news to whoever claimed last. So _settle clamps the accrual itself:
 *
 *      raw = shares * (accRewardPerShare(now) - rewardDebt) / 1e18
 *      remaining = MAX_ARTHA - totalArthaMinted
 *      if (raw > remaining) raw = remaining;   // partial, then the budget is dry
 *      totalArthaMinted += raw
 *
 *  At the boundary the last stretch banks exactly what is left and stops growing for
 *  good. No revert, no silent zero, no promise that cannot be paid. Stakers keep
 *  their shares and can always unstake. This clamp is entirely separate from the
 *  vault's own rate index, which keeps advancing regardless -- once the global
 *  budget is spent there is simply nothing left to bank, forever after.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   FUNDING
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  This contract does NOT mint ARTHA. Fund it up front; claims pay from balance.
 *  `outstandingArtha()` is what is owed -- keep the balance at or above it. Staked
 *  shares are custodied here, never lent or re-staked, and rescue() cannot touch
 *  them.
 */
contract UserRewardVault is UserRewardSystem, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────── constants ──────────────────────────────────

    /// @notice Lifetime ARTHA budget for the entire user-staking programme.
    uint256 public constant MAX_ARTHA = 10_000_000e18;

    IERC20 public immutable arthaToken;

    // ─────────────────────────────── types ──────────────────────────────────────

    /// @notice Config + lifetime books for one registered vault.
    struct VaultInfo {
        bool registered; // if set false again, the vault is ignored
        address shareToken; // the vault's share token, custodied here when staked
        uint256 totalArthaEarned; // lifetime ARTHA accrued to this vault's stakers
        uint256 totalArthaClaimed; // lifetime ARTHA claimed out of this vault
    }

    // ─────────────────────────────── events ─────────────────────────────────────

    event VaultRegistered(address indexed vault, address shareToken, uint256 rewardRate);
    event Staked(address indexed vault, address user, address payer, uint256 amount, uint256 newShares);
    event Unstaked(address indexed vault, address user, uint256 amount, uint256 newShares);
    event ArthaClaimed(address indexed vault, address user, uint256 amount);
    event Settled(address indexed vault, address user, uint256 accrued);
    event ArthaCapReached(uint256 emitted, uint256 totalMinted);
    event Rescued(address token, address to, uint256 amount);

    // ─────────────────────────────── storage ────────────────────────────────────

    /// @notice Lifetime ARTHA accrued across all vaults. NEVER exceeds MAX_ARTHA.
    uint256 public totalArthaMinted;
    /// @notice Lifetime ARTHA claimed, all vaults.
    uint256 public totalArthaClaimed;

    /// @notice vault => config + lifetime books.
    mapping(address => VaultInfo) private _vaultInfo;

    /// @notice user => lifetime ARTHA claimed across every vault.
    mapping(address => uint256) public userTotalArthaClaimed;

    /// @notice Registered vault set. Used to guard rescue() against a share token.
    address[] public registeredVaults;

    constructor(address _artha, address _admin) UserRewardSystem(_admin) {
        require(_artha != address(0), "INVALID_ARTHA");
        arthaToken = IERC20(_artha);
    }

    function artha() external view returns (address) {
        return address(arthaToken);
    }

    /**
     * @dev Bank a position's accrual since its last settle, clamped to the global
     *      budget, then move its rewardDebt to the current rate index. Call BEFORE
     *      any change to that position's shares.
     *
     *  This is the only place ARTHA is ever credited to a user, so it is the only
     *  place that needs to know MAX_ARTHA -- see UserRewardSystem's header for why
     *  the raw calculation lives one layer down and this layer only ever banks it
     *  clamped. Note the cap is orthogonal to the rate index: `_currentAcc` keeps
     *  growing with the vault's own rate history regardless of the GLOBAL budget, so
     *  a position's rewardDebt always catches up to it in full even on a capped
     *  settle -- once the budget is spent there is nothing left to under-credit, so
     *  there is nothing to preserve for later.
     */
    function _settle(address _vault, address _user) internal {
        uint256 raw = _accruedSince(_vault, _user);
        Position storage pos = _position[_vault][_user];

        if (raw != 0) {
            uint256 remaining = MAX_ARTHA - totalArthaMinted;
            uint256 accrued = raw;
            bool capped;
            if (accrued > remaining) {
                accrued = remaining;
                capped = true;
            }

            if (accrued != 0) {
                pos.earnedArtha += accrued;
                pos.totalEarnedArtha += accrued;
                totalArthaMinted += accrued;
                _vaultInfo[_vault].totalArthaEarned += accrued;
                emit Settled(_vault, _user, accrued);
            }
            if (capped) emit ArthaCapReached(accrued, totalArthaMinted);
        }

        _restampDebt(_vault, pos, _currentAcc(_vault));
    }

    // ═════════════════════════════ staking ══════════════════════════════════════

    /**
     * @notice Stake vault shares to start earning ARTHA. Anyone can stake FOR
     *         another user: shares are pulled from msg.sender but the position, and
     *         everything it earns, belongs to `user`.
     * @dev    Settle FIRST, then pull. The elapsed stretch belongs to the old balance.
     *
     *  Uses the BALANCE DELTA, not `amount`, to credit the stake. A share token with a
     *  transfer fee would deliver less than `amount`, and crediting the ask would let
     *  the books drift above what this contract actually custodies.
     */
    function stake(address vault, address user, uint256 amount) external nonReentrant whenNotPaused {
        require(_vaultInfo[vault].registered, "NOT_REGISTERED");
        require(user != address(0), "INVALID_USER");
        require(amount != 0, "INVALID_AMOUNT");

        _settle(vault, user);

        IERC20 shareToken = IERC20(_vaultInfo[vault].shareToken);
        uint256 before = shareToken.balanceOf(address(this));
        shareToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = shareToken.balanceOf(address(this)) - before;
        require(received == amount, "NO_SHARES_RECEIVED");

        Position storage pos = _position[vault][user];
        _addShares(vault, pos, received);

        emit Staked(vault, user, msg.sender, received, pos.shares);
    }

    /**
     * @notice Withdraw staked shares. Accrued ARTHA is banked, not forfeited.
     * @dev    Only the position owner can unstake -- a stake placed for `user` by
     *         someone else is `user`'s alone from that point on. Does NOT auto-claim.
     */
    function unstake(address vault, uint256 amount) external nonReentrant whenNotPaused {
        require(_vaultInfo[vault].registered, "NOT_REGISTERED");
        require(amount != 0, "INVALID_AMOUNT");

        _settle(vault, msg.sender);

        Position storage pos = _position[vault][msg.sender];
        require(pos.shares >= amount, "INSUFFICIENT_STAKE");
        _removeShares(vault, pos, amount);

        IERC20(_vaultInfo[vault].shareToken).safeTransfer(msg.sender, amount);
        emit Unstaked(vault, msg.sender, amount, pos.shares);
    }

    /**
     * @notice Withdraw the caller's ENTIRE stake without touching the accrual math.
     *         The escape hatch: staked principal is never hostage to the reward index.
     *
     * @dev    Deliberately does not call `_settle`, does not read `_currentAcc`, and is
     *         not `whenNotPaused` — those are exactly the things that can be wedged.
     *         Unsettled accrual is FORFEITED (already-settled `earnedArtha` stays
     *         claimable); leaving `rewardDebt` stale is safe because `_accruedSince`
     *         returns 0 once `shares` is 0, and any future `stake()` re-stamps it.
     */
    function emergencyUnstake(address vault) external nonReentrant {
        Position storage pos = _position[vault][msg.sender];
        uint256 amount = pos.shares;
        require(amount != 0, "NO_STAKE");

        _removeShares(vault, pos, amount);

        IERC20(_vaultInfo[vault].shareToken).safeTransfer(msg.sender, amount);
        emit Unstaked(vault, msg.sender, amount, 0);
    }

    // ═════════════════════════════ claiming ═════════════════════════════════════

    /// @notice Claim all ARTHA earned by the caller's own position in `vault`.
    function claimArtha(address vault) external nonReentrant whenNotPaused {
        require(_vaultInfo[vault].registered, "NOT_REGISTERED");

        _settle(vault, msg.sender);

        Position storage pos = _position[vault][msg.sender];
        uint256 owed = pos.earnedArtha;
        require(owed != 0, "NOTHING_TO_CLAIM");

        uint256 bal = arthaToken.balanceOf(address(this));
        uint256 grant = owed <= bal ? owed : bal;
        require(grant != 0, "NO_ARTHA_LIQUIDITY");

        pos.earnedArtha = owed - grant;
        pos.totalClaimedArtha += grant;

        _vaultInfo[vault].totalArthaClaimed += grant;
        totalArthaClaimed += grant;
        userTotalArthaClaimed[msg.sender] += grant;

        arthaToken.safeTransfer(msg.sender, grant);
        emit ArthaClaimed(vault, msg.sender, grant);
    }

    // ═════════════════════════════ admin ════════════════════════════════════════

    /**
     * @notice Register a vault and open its emission.
     * @param  rewardRate_ ARTHA per share per second, 1e18 fixed point.
     */
    function registerVault(address vault, address shareToken, uint256 rewardRate_) external onlyUserRewardManager {
        require(vault != address(0) && shareToken != address(0), "INVALID_PARAMS");
        require(!_vaultInfo[vault].registered, "ALREADY_REGISTERED");

        _vaultInfo[vault] =
            VaultInfo({registered: true, shareToken: shareToken, totalArthaEarned: 0, totalArthaClaimed: 0});
        _setRewardRate(vault, rewardRate_);

        registeredVaults.push(vault);
        emit VaultRegistered(vault, shareToken, rewardRate_);
    }

    /// @notice Change a vault's reward rate. ADMIN ONLY.
    /// @dev    _setRewardRate banks the OLD rate's contribution into the rate index
    ///         before overwriting it (see UserRewardSystem._advanceAcc), so every
    ///         position -- settled or not -- is still charged the old rate for time
    ///         before this call and the new rate only from here on.
    function setRewardRate(address vault, uint256 rewardRate_) external onlyUserRewardManager {
        require(_vaultInfo[vault].registered, "NOT_REGISTERED");
        _setRewardRate(vault, rewardRate_);
    }

    /**
     * @dev Sweeping ARTHA is bounded by what is OWED to stakers. Sweeping a registered
     *      vault's SHARE token is forbidden outright -- every share here belongs to a
     *      staker, none of it is ever excess, and a rescue that can reach it is a rug.
     */
    function rescue(address token, address to, uint256 amount) external onlyUserRewardManager {
        require(to != address(0) && amount != 0, "INVALID_PARAMS");
        require(!_isRegisteredShareToken(token), "CANNOT_RESCUE_SHARES");

        if (token == address(arthaToken)) {
            uint256 owed = outstandingArtha();
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 excess = bal > owed ? bal - owed : 0;
            require(amount <= excess, "EXCEEDS_EXCESS");
        }

        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ═════════════════════════════ views ════════════════════════════════════════

    function arthaRemaining() external view returns (uint256) {
        return MAX_ARTHA - totalArthaMinted;
    }

    /// @notice What this contract still owes stakers — SETTLED debt plus accrual that
    ///         has been earned but not yet banked by a `_settle`.
    ///
    ///  The unsettled half matters: a staker who simply holds a position earns real
    ///  ARTHA continuously, and `totalArthaMinted` only moves when they touch the
    ///  contract. Counting only the settled half would report zero owed for a vault
    ///  full of long-term stakers, and `rescue` would happily withdraw the ARTHA that
    ///  is about to be claimed.
    ///
    ///  The unsettled figure is clamped to the programme's remaining budget, because
    ///  that is exactly the clamp `_settle` will apply when it banks it.
    function outstandingArtha() public view returns (uint256) {
        uint256 settled = totalArthaMinted - totalArthaClaimed;

        uint256 unsettled;
        uint256 n = registeredVaults.length;
        for (uint256 i; i < n; ++i) {
            unsettled += _unsettledAccrual(registeredVaults[i]);
        }

        uint256 budgetLeft = MAX_ARTHA - totalArthaMinted;
        if (unsettled > budgetLeft) unsettled = budgetLeft;

        return settled + unsettled;
    }

    function vaultInfo(address vault) external view returns (VaultInfo memory) {
        return _vaultInfo[vault];
    }

    /// @notice Settled + unsettled ARTHA for a user in a vault. Cap-aware.
    function pendingArtha(address vault, address user) public view returns (uint256) {
        Position storage pos = _position[vault][user];
        uint256 total = pos.earnedArtha;

        uint256 raw = _accruedSince(vault, user);
        if (raw != 0) {
            uint256 remaining = MAX_ARTHA - totalArthaMinted;
            if (raw > remaining) raw = remaining;
            total += raw;
        }
        return total;
    }

    /**
     * @notice Everything the front-end needs about one position, in one call.
     * @return stakedShares_      Shares currently staked.
     * @return pendingArtha_      Settled + unsettled ARTHA.
     * @return totalEarnedArtha_  Lifetime ARTHA ever earned here (includes claimed).
     * @return totalClaimedArtha_ Lifetime ARTHA ever withdrawn from here.
     * @return rewardRate_        ARTHA per share per second for this vault.
     */
    function getInfo(address vault, address user)
        external
        view
        returns (
            uint256 stakedShares_,
            uint256 pendingArtha_,
            uint256 totalEarnedArtha_,
            uint256 totalClaimedArtha_,
            uint256 rewardRate_
        )
    {
        Position storage pos = _position[vault][user];

        stakedShares_ = pos.shares;
        pendingArtha_ = pendingArtha(vault, user);
        totalEarnedArtha_ = pos.totalEarnedArtha;
        totalClaimedArtha_ = pos.totalClaimedArtha;
        rewardRate_ = _emission[vault].rewardRate;
    }

    /// @notice Programme-wide totals. Keep this contract's ARTHA balance at or above
    ///         `outstanding` or claims will start partial-filling on liquidity.
    function globalBooks()
        external
        view
        returns (
            uint256 arthaMinted,
            uint256 arthaClaimed,
            uint256 outstanding,
            uint256 arthaLeftInBudget,
            uint256 arthaBalance
        )
    {
        return (
            totalArthaMinted,
            totalArthaClaimed,
            outstandingArtha(),
            MAX_ARTHA - totalArthaMinted,
            arthaToken.balanceOf(address(this))
        );
    }

    function registeredVaultsCount() external view returns (uint256) {
        return registeredVaults.length;
    }

    // ─────────────────────────────── internal ───────────────────────────────────

    function _isRegisteredShareToken(address _token) internal view returns (bool) {
        uint256 n = registeredVaults.length;
        for (uint256 i = 0; i < n; i++) {
            if (_vaultInfo[registeredVaults[i]].shareToken == _token) return true;
        }
        return false;
    }
}
