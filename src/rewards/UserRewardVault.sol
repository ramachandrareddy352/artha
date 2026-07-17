// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "./UserRewardSystem.sol";
import "./interfaces/IUserRewardVault.sol";

/**
 * @title  UserRewardVault
 * @notice Custodies staked vault shares, accrues ARTHA on their USD value per second,
 *         and pays it out on claim.
 *
 *             UserRewardManager  <-  UserRewardSystem  <-  UserRewardVault (deployed)
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHAT A USER ACTUALLY GETS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  A user holds 100 USDC worth of USDC-vault shares. Holding them earns vault yield
 *  and nothing else. STAKING them here earns ARTHA on top, at the vault's rate:
 *
 *      rewardRate[USDC vault] = 10_000  (10% APR)
 *
 *      stake 100 USDC of shares, wait one year
 *        -> ~10 USD accrued  -> x arthaRatio  -> ~10 ARTHA
 *        -> shares still theirs, still earning vault yield, unstake any time
 *
 *  Now the WETH vault at the SAME 10% rate, with 1 WETH = $1,000:
 *
 *      stake 1 WETH of shares, wait one year
 *        -> ~100 USD accrued -> x arthaRatio -> ~100 ARTHA
 *
 *  Ten times the ARTHA off an identical rate, because the position is worth ten times
 *  as much. There is no per-vault rate tuning to make that happen and no re-tuning
 *  when ETH moves -- the oracle carries it. See UserRewardSystem for the math.
 *
 *  ARTHA accrued is slightly MORE than the headline rate suggests (10.25, not 10.00,
 *  in the USDC example) because pricePerShare rises over the year and rewards accrue
 *  on VALUE. That is intended: the reward tracks what the position is actually worth.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   arthaRatio: THE SECOND KNOB
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `rewardRate[V]` sets how fast USD accrues. `arthaRatio[V]` sets how many ARTHA one
 *  accrued USD converts into, 18dp -- the same knob, with the same meaning, as the
 *  referral stack's arthaRatio:
 *
 *      USDC vault => 1e18  -> 10 USD accrued  ->  10 ARTHA
 *      WETH vault => 1e19  -> 10 USD accrued  -> 100 ARTHA
 *
 *  Two knobs rather than one because they answer different questions. The rate is the
 *  user's APR and belongs in the marketing copy. The ratio is how expensive ARTHA is
 *  for that vault, and lets a thin or strategic vault pay a premium in token without
 *  quoting an APR that invites mercenary capital. Conversion happens at CLAIM, not at
 *  accrual -- the book is kept in USD, so re-pricing ARTHA does not require touching
 *  every user's balance.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE GLOBAL ARTHA CAP IS A HARD CEILING, AND IT PAYS PARTIAL
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  MAX_ARTHA (10,000,000e18) is this programme's entire lifetime budget, separate
 *  from the referral programme's. When a claim would cross it we grant EXACTLY the
 *  remainder and debit ONLY the USD that remainder was worth -- never the full ask,
 *  never zero:
 *
 *      minted = 9,999,999e18,  request = 5e18
 *        -> remaining = 1e18 -> grant 1e18, debit 1 ARTHA worth of USD.
 *        -> the other 4 ARTHA of USD STAYS in earnedUSD, still visible, still owed.
 *
 *  Granting the full ask would mint past the cap. Granting zero would burn a real
 *  earned claim. Zeroing earnedUSD on a partial grant would silently confiscate the
 *  shortfall -- which is why the debit is computed FROM the granted amount, not from
 *  the request. Raise the cap or fund the contract and the residual is still there.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ACCRUAL MUST NEVER BRICK A WITHDRAW
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  notifyShareChange() is called by the vault inside its own share-movement path. If
 *  it reverts, the vault's deposit and withdraw revert with it -- a stale oracle
 *  would freeze user funds. So the settle inside it is wrapped: on failure the
 *  reward book is left untouched, SettleFailed is emitted, and the vault proceeds.
 *
 *  The trade is explicit. A swallowed settle leaves the window open at the old share
 *  balance, so the next settle prices the whole window at the NEW balance -- over-
 *  paying on a deposit, under-paying on an unstake. It is bounded by feed downtime
 *  and is strictly better than locking withdrawals. Monitor SettleFailed.
 *
 *  claimArtha() does NOT swallow. Paying out on a stale price is worse than making
 *  the user retry in an hour.
 *
 *  FUNDING: this contract does NOT mint ARTHA. Fund it up front; claims pay from
 *  balance. Staked shares are custodied here and are never lent, staked onward, or
 *  touched by rescue().
 */
contract UserRewardVault is UserRewardSystem, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────── types ──────────────────────────────────────

    /// @notice Config + lifetime books for one registered vault.
    struct VaultData {
        bool registered;            // if set false again, the vault is ignored
        address shareToken;         // the vault's share token, custodied here when staked
        // 10^(18 - decimals). Recorded at registration but NOT used in the math:
        // ERC-4626 shares are 18dp, and pricePerShare already carries the base
        // token's decimals, so `shares * sharePriceUSD / WAD` lands on 18dp USD with
        // no scaling. Kept because a future non-18dp share token would need it, and
        // because registerVault validating decimals is worth the one slot.
        uint256 shareScale;
        uint256 arthaRatio;         // ARTHA (18dp) per 1 USD accrued
        uint256 totalStakedShares;  // shares currently staked in this vault
        uint256 totalEarnedUSD;     // lifetime USD accrued by this vault's stakers
        uint256 totalArthaEarned;   // lifetime ARTHA credited from this vault
        uint256 totalArthaClaimed;  // lifetime ARTHA claimed from this vault
    }

    /// @notice Per (vault, user) earnings ledger.
    struct Earning {
        uint256 totalEarnedUSD;   // lifetime USD accrued
        uint256 totalEarnedArtha; // lifetime ARTHA credited
        uint256 claimedArtha;     // lifetime ARTHA claimed
    }

    // ─────────────────────────────── constants ──────────────────────────────────

    /// @notice Lifetime ARTHA budget for the entire user-staking programme.
    uint256 public constant MAX_ARTHA = 10_000_000e18;

    IERC20 public immutable arthaToken;

    // ─────────────────────────────── events ─────────────────────────────────────

    event VaultRegistered(address indexed vault, address indexed shareToken, uint256 rateBps, uint256 arthaRatio);
    event ArthaRatioUpdated(address indexed vault, uint256 oldRatio, uint256 newRatio);
    event OracleUpdated(address oldOracle, address newOracle);
    event Staked(address indexed vault, address indexed user, uint256 amount, uint256 newShares);
    event Unstaked(address indexed vault, address indexed user, uint256 amount, uint256 newShares);
    event ArthaClaimed(address indexed vault, address indexed user, address to, uint256 usdDebited, uint256 arthaAmount);
    event ArthaCapReached(uint256 requested, uint256 granted, uint256 totalMinted);
    event SettleFailed(address indexed vault, address indexed user, bytes reason);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ─────────────────────────────── storage ────────────────────────────────────

    IOracle public oracle;

    /// @notice Lifetime ARTHA credited across all vaults. Never exceeds MAX_ARTHA.
    uint256 public totalArthaMinted;
    /// @notice Lifetime ARTHA claimed, all vaults.
    uint256 public totalClaimedArtha;
    /// @notice Lifetime USD accrued across all vaults, 18dp.
    uint256 public totalEarnedUSDGlobal;
    /// @notice Lifetime USD debited by claims, all vaults, 18dp.
    uint256 public totalClaimedUSDGlobal;
    /// @notice How many claims were cut short by the cap or by an empty balance.
    uint256 public partialClaimCount;

    /// @notice vault => config + lifetime books.
    mapping(address => VaultData) private _vaultData;

    /// @notice vault => user => earnings ledger.
    mapping(address => mapping(address => Earning)) private _earning;

    /// @notice user => lifetime ARTHA claimed across every vault.
    mapping(address => uint256) public userTotalArthaClaimed;

    // ---- per-user footprint (bounds claimAll) ----
    mapping(address => address[]) public userVaults;
    mapping(address => mapping(address => bool)) public userHasVault;

    // ---- registered vault set ----
    address[] public registeredVaults;

    constructor(address _artha, address _oracle, address _admin) UserRewardSystem(_admin) {
        require(_artha != address(0), "INVALID_ARTHA");
        require(_oracle != address(0), "INVALID_ORACLE");
        arthaToken = IERC20(_artha);
        oracle = IOracle(_oracle);
    }

    function artha() external view returns (address) {
        return address(arthaToken);
    }

    // ═══════════════════════════ pricing, in one place ══════════════════════════

    /**
     * @notice Share price in USD, 18dp.
     * @dev    THE single source of truth for valuation. Both the view path and the
     *         settle path route through here, so a quote and a credit can never
     *         disagree.
     *
     *         pricePerShare (18dp) x oracle price (8dp) / 1e8 -> 18dp USD.
     */
    function sharePriceUSD(address _vault) public view returns (uint256) {
        VaultData storage v = _vaultData[_vault];
        if (!v.registered) return 0;

        uint256 pps = IArthaVault(_vault).pricePerShare();
        if (pps == 0) return 0;

        uint256 price = oracle.getPrice(v.shareToken);
        if (price == 0) return 0;

        return (pps * price) / PRICE_ONE;
    }

    /// @dev Reverts rather than returning 0. Used on the settle path, where a silent
    ///      zero would not fail -- it would quietly accrue nothing for the window and
    ///      then anchor the next window's left endpoint at zero.
    function _sharePriceUSDStrict(address _vault) internal view returns (uint256 p) {
        p = sharePriceUSD(_vault);
        require(p != 0, "BAD_SHARE_PRICE");
    }

    /// @dev Accrued USD (18dp) -> ARTHA (18dp), clamped to what is left of the budget.
    function _quoteArtha(address _vault, uint256 _usd18) internal view returns (uint256) {
        if (_usd18 == 0) return 0;

        uint256 ratio = _vaultData[_vault].arthaRatio;
        if (ratio == 0) return 0;

        uint256 remaining = MAX_ARTHA - totalArthaMinted;
        if (remaining == 0) return 0;

        uint256 amount = (_usd18 * ratio) / WAD;
        return amount > remaining ? remaining : amount;
    }

    /// @dev Inverse of _quoteArtha. Given ARTHA actually granted, how much USD does
    ///      that represent? Used to debit exactly what was paid on a partial fill.
    function _arthaToUSD(address _vault, uint256 _artha) internal view returns (uint256) {
        uint256 ratio = _vaultData[_vault].arthaRatio;
        if (ratio == 0) return 0;
        return (_artha * WAD) / ratio;
    }

    /// @dev Record that `user` has a book in `vault`, so claimAll can enumerate it
    ///      without an unbounded scan of the global vault set.
    function _touchUserVault(address _user, address _vault) internal {
        if (!userHasVault[_user][_vault]) {
            userHasVault[_user][_vault] = true;
            userVaults[_user].push(_vault);
        }
    }

    // ═══════════════════════════ settlement ═════════════════════════════════════

    /**
     * @dev Close the user's open window at the CURRENT share balance and bank it.
     *
     *  Ordering is the whole ballgame, and it is why every caller settles BEFORE
     *  touching `shares`:
     *    1. read the price now (reverts if the oracle is dead).
     *    2. first touch ever -> anchor both endpoints, accrue nothing, return.
     *    3. accrue [lastAccrualAt, now] at the shares that were there the whole time.
     *    4. write lastAccrualAt AND lastSharePriceUSD unconditionally.
     *
     *  Step 4 is unconditional even when nothing accrued. lastSharePriceUSD is the
     *  left endpoint of the NEXT window; leave it stale and the next settle prices a
     *  window from a price that belongs to a different era.
     */
    function _settle(address _vault, address _user) internal {
        Stake storage s = _stake[_vault][_user];
        uint256 priceNow = _sharePriceUSDStrict(_vault);

        if (s.lastAccrualAt == 0) {
            s.lastAccrualAt = block.timestamp;
            s.lastSharePriceUSD = priceNow;
            if (s.stakedAt == 0) s.stakedAt = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - s.lastAccrualAt;
        uint256 accrued;
        if (elapsed != 0 && s.shares != 0) {
            accrued = _accrue(_vault, s.shares, s.lastAccrualAt, block.timestamp, s.lastSharePriceUSD, priceNow);
        }

        if (accrued != 0) {
            s.earnedUSD += accrued;
            _earning[_vault][_user].totalEarnedUSD += accrued;
            _vaultData[_vault].totalEarnedUSD += accrued;
            totalEarnedUSDGlobal += accrued;
        }

        emit Settled(_vault, _user, accrued, elapsed, s.lastSharePriceUSD, priceNow);

        s.lastAccrualAt = block.timestamp;
        s.lastSharePriceUSD = priceNow;
    }

    /// @notice Force-close a user's open window without moving any shares.
    /// @dev    Permissionless on purpose: a keeper calling this on volatile vaults
    ///         shortens each window and tightens the endpoint average. It can only
    ///         ever bank what the user already earned.
    function settle(address vault, address user) external whenNotPaused {
        require(_vaultData[vault].registered, "NOT_REGISTERED");
        _settle(vault, user);
    }

    // ═══════════════════════════ vault integration ══════════════════════════════

    /**
     * @notice Report a share movement the VAULT performed (transfer, mint, burn).
     * @dev    onlyCaller(vault): msg.sender MUST equal `vault`.
     *
     *  This is for vaults that move shares OUTSIDE stake()/unstake(). It settles at
     *  the recorded old balance, then writes the new one.
     *
     *  `oldShares` from the caller is IGNORED in favour of our own record. The vault
     *  is trusted to say WHO moved and to WHAT, but our book is the authority on what
     *  the balance was -- otherwise a buggy vault reporting an inflated oldShares
     *  would mint reward out of nothing.
     *
     *  The settle is wrapped: a dead oracle must not brick the vault's withdraw path.
     */
    function notifyShareChange(address vault, address user, uint256 oldShares, uint256 newShares)
        external
        nonReentrant
        onlyCaller(vault)
    {
        require(_vaultData[vault].registered, "NOT_REGISTERED");
        oldShares; // accepted for the vault's event symmetry; our record is authoritative

        Stake storage s = _stake[vault][user];
        uint256 recordedOld = s.shares;

        try this.settleExternal(vault, user) {
            // window closed cleanly at recordedOld
        } catch (bytes memory reason) {
            emit SettleFailed(vault, user, reason);
        }

        _applyShareDelta(vault, user, recordedOld, newShares);
        emit ShareChanged(vault, user, recordedOld, newShares);
    }

    /// @dev try/catch needs an external call. Self-call, gated to this contract.
    function settleExternal(address vault, address user) external {
        require(msg.sender == address(this), "ONLY_SELF");
        _settle(vault, user);
    }

    /// @dev Write the new balance and keep the vault-level total in step.
    function _applyShareDelta(address _vault, address _user, uint256 _old, uint256 _new) internal {
        VaultData storage v = _vaultData[_vault];
        Stake storage s = _stake[_vault][_user];

        if (_new > _old) {
            uint256 d = _new - _old;
            v.totalStakedShares += d;
            totalStakedShares[_vault] += d;
        } else if (_old > _new) {
            uint256 d = _old - _new;
            v.totalStakedShares -= d;
            totalStakedShares[_vault] -= d;
        }

        s.shares = _new;
        if (_new != 0 && s.stakedAt == 0) s.stakedAt = block.timestamp;

        _touchUserVault(_user, _vault);
    }

    /**
     * @notice Everything the front-end needs about a user's position, in one call.
     * @return stakedShares_ Shares currently staked here.
     * @return pendingUSD_   Settled + unsettled USD, 18dp.
     * @return pendingArtha_ What claiming right now would actually pay, cap included.
     * @return rateBps       The vault's rate in force now.
     * @return stakedAt_     First-ever stake timestamp.
     */
    function getInfo(address vault, address user)
        external
        view
        returns (uint256 stakedShares_, uint256 pendingUSD_, uint256 pendingArtha_, uint256 rateBps, uint256 stakedAt_)
    {
        Stake storage s = _stake[vault][user];
        (pendingUSD_, pendingArtha_) = pendingOf(vault, user);
        return (s.shares, pendingUSD_, pendingArtha_, currentRate(vault), s.stakedAt);
    }

    // ═════════════════════════════ staking ══════════════════════════════════════

    /**
     * @notice Stake vault shares to start earning ARTHA.
     * @dev    Settle FIRST, then pull. The open window belongs to the old balance.
     */
    function stake(address vault, uint256 amount) external nonReentrant whenNotPaused {
        require(_vaultData[vault].registered, "NOT_REGISTERED");
        require(amount != 0, "INVALID_AMOUNT");

        _settle(vault, msg.sender);

        uint256 old = _stake[vault][msg.sender].shares;
        IERC20(_vaultData[vault].shareToken).safeTransferFrom(msg.sender, address(this), amount);

        _applyShareDelta(vault, msg.sender, old, old + amount);
        emit Staked(vault, msg.sender, amount, old + amount);
    }

    /**
     * @notice Withdraw staked shares. Accrued ARTHA is banked, not forfeited.
     * @dev    Unstaking does NOT auto-claim. Claiming is a separate, explicit act:
     *         it can partial-fill against the cap, and a user exiting a position
     *         should not have that decision made for them mid-withdraw.
     */
    function unstake(address vault, uint256 amount) external nonReentrant whenNotPaused {
        require(_vaultData[vault].registered, "NOT_REGISTERED");
        require(amount != 0, "INVALID_AMOUNT");

        _settle(vault, msg.sender);

        uint256 old = _stake[vault][msg.sender].shares;
        require(old >= amount, "INSUFFICIENT_STAKE");

        _applyShareDelta(vault, msg.sender, old, old - amount);

        IERC20(_vaultData[vault].shareToken).safeTransfer(msg.sender, amount);
        emit Unstaked(vault, msg.sender, amount, old - amount);
    }

    // ═════════════════════════════ claiming ═════════════════════════════════════

    /**
     * @notice Claim ARTHA against accrued USD. Partial-fills at the cap.
     * @param  amount ARTHA to claim. Clamped down to the payable amount; pass
     *                type(uint256).max to take everything available.
     * @dev    Does NOT swallow oracle failures -- see the contract header.
     */
    function claimArtha(address vault, address to, uint256 amount) public nonReentrant whenNotPaused {
        require(_vaultData[vault].registered, "NOT_REGISTERED");
        require(to != address(0) && amount != 0, "INVALID_PARAMS");

        _settle(vault, msg.sender);
        _claimArtha(vault, msg.sender, to, amount);
    }

    /**
     * @dev The clamp ladder, in order. Each step can only reduce.
     *      1. what the user's USD is worth in ARTHA
     *      2. what they asked for
     *      3. what is left of the global budget
     *      4. what this contract actually holds
     *
     *      Then debit the USD that the GRANTED amount was worth -- not the ask, not
     *      the whole balance. The shortfall stays owed. `granted` capped by `owedUSD`
     *      guards the rounding edge where the inverse conversion overshoots.
     */
    function _claimArtha(address _vault, address _user, address _to, uint256 _amount) internal {
        Stake storage s = _stake[_vault][_user];
        uint256 owedUSD = s.earnedUSD;
        require(owedUSD != 0, "NOTHING_TO_CLAIM");

        uint256 ratio = _vaultData[_vault].arthaRatio;
        require(ratio != 0, "RATIO_NOT_SET");

        // What the whole USD balance is worth, before any clamping.
        uint256 want = (owedUSD * ratio) / WAD;
        require(want != 0, "NOTHING_TO_CLAIM");

        uint256 grant = want;
        bool partial;

        // 1. the global budget
        uint256 remaining = MAX_ARTHA - totalArthaMinted;
        require(remaining != 0, "ARTHA_CAP_EXHAUSTED");
        if (grant > remaining) {
            grant = remaining;
            partial = true;
        }

        // 2. what this contract actually holds
        uint256 bal = arthaToken.balanceOf(address(this));
        if (grant > bal) {
            grant = bal;
            partial = true;
        }
        require(grant != 0, "NO_ARTHA_LIQUIDITY");

        // 3. what the user asked for. A voluntary partial is NOT a cap event, so it
        //    must not trip `partial` -- that flag drives ArthaCapReached, and firing
        //    it on every routine part-claim would make the signal useless.
        if (_amount < grant) grant = _amount;

        uint256 debitUSD = _arthaToUSD(_vault, grant);
        if (debitUSD > owedUSD) debitUSD = owedUSD;

        s.earnedUSD = owedUSD - debitUSD;

        // `totalEarnedArtha` is credited ONLY here, at claim, because the book is kept
        // in USD and never in ARTHA until this moment. So earned == claimed by
        // construction on this path, and the ARTHA-side "outstanding" is always zero:
        // the real outstanding liability lives in earnedUSD and is computed from it in
        // _outstandingArtha(). Booking `grant` into both is correct, not a duplicate.
        Earning storage e = _earning[_vault][_user];
        e.totalEarnedArtha += grant;
        e.claimedArtha += grant;

        VaultData storage v = _vaultData[_vault];
        v.totalArthaEarned += grant;
        v.totalArthaClaimed += grant;

        totalArthaMinted += grant;
        totalClaimedArtha += grant;
        totalClaimedUSDGlobal += debitUSD;
        userTotalArthaClaimed[_user] += grant;

        if (partial) {
            unchecked { ++partialClaimCount; }
            emit ArthaCapReached(want, grant, totalArthaMinted);
        }

        arthaToken.safeTransfer(_to, grant);
        emit ArthaClaimed(_vault, _user, _to, debitUSD, grant);
    }

    /// @notice Claim every vault the caller has a book in. Bounded by userVaults.
    function claimAll(address to) external {
        address[] storage list = userVaults[msg.sender];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            address v = list[i];
            (, uint256 a) = pendingOf(v, msg.sender);
            if (a != 0) claimArtha(v, to, a);
        }
    }

    // ═════════════════════════════ admin ════════════════════════════════════════

    function registerVault(
        address vault,
        address shareToken,
        uint8 decimals,
        uint256 rateBps,
        uint256 arthaRatio_
    ) external onlyUserRewardManager {
        require(vault != address(0) && shareToken != address(0), "INVALID_PARAMS");
        require(!_vaultData[vault].registered, "ALREADY_REGISTERED");
        require(decimals >= 6 && decimals <= 18, "BAD_DECIMALS");

        _vaultData[vault] = VaultData({
            registered: true,
            shareToken: shareToken,
            shareScale: 10 ** (18 - decimals),
            arthaRatio: arthaRatio_,
            totalStakedShares: 0,
            totalEarnedUSD: 0,
            totalArthaEarned: 0,
            totalArthaClaimed: 0
        });

        _initRate(vault, rateBps);
        registeredVaults.push(vault);

        emit VaultRegistered(vault, shareToken, rateBps, arthaRatio_);
    }

    /**
     * @notice Change a vault's APR. ADMIN ONLY.
     * @dev    Appends an epoch; never rewrites history. Unlike the referral stack's
     *         setCodeTier -- which needs no settlement because commission is priced
     *         per-fee -- this DOES accrue over time, so open windows must keep the
     *         old rate for their old stretch. The epoch split in _accrue does that
     *         automatically, per user, on their next settle. No global walk needed.
     */
    function setRewardRate(address vault, uint256 rateBps) external onlyUserRewardManager {
        require(_vaultData[vault].registered, "NOT_REGISTERED");
        _setRewardRate(vault, rateBps);
    }

    function setArthaRatio(address vault, uint256 arthaRatio_) external onlyUserRewardManager {
        require(_vaultData[vault].registered, "NOT_REGISTERED");
        uint256 old = _vaultData[vault].arthaRatio;
        _vaultData[vault].arthaRatio = arthaRatio_;
        emit ArthaRatioUpdated(vault, old, arthaRatio_);
    }

    function setOracle(address newOracle) external onlyUserRewardManager {
        require(newOracle != address(0), "INVALID_ORACLE");
        emit OracleUpdated(address(oracle), newOracle);
        oracle = IOracle(newOracle);
    }

    /**
     * @dev Sweeping ARTHA is bounded by what is OWED to stakers. Sweeping a
     *      registered vault's SHARE token is forbidden outright -- every share here
     *      belongs to a staker, none of it is ever excess, and a rescue that can
     *      touch it is a rug. A rescue must never take money that is already
     *      someone's.
     */
    function rescue(address token, address to, uint256 amount) external onlyUserRewardManager {
        require(to != address(0) && amount != 0, "INVALID_PARAMS");
        require(!_isRegisteredShareToken(token), "CANNOT_RESCUE_SHARES");

        if (token == address(arthaToken)) {
            uint256 owed = _outstandingArtha();
            if (owed != 0) {
                uint256 bal = IERC20(token).balanceOf(address(this));
                uint256 excess = bal > owed ? bal - owed : 0;
                require(amount <= excess, "EXCEEDS_EXCESS");
            }
        }

        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ═════════════════════════════ views ════════════════════════════════════════

    function arthaRemaining() external view returns (uint256) {
        return MAX_ARTHA - totalArthaMinted;
    }

    function vaultData(address vault) external view returns (VaultData memory) {
        return _vaultData[vault];
    }

    function earningOf(address vault, address user) external view returns (Earning memory) {
        return _earning[vault][user];
    }

    /**
     * @notice Unclaimed USD and the ARTHA it would actually pay right now.
     * @dev    pendingArtha is the PAYABLE number, cap included -- not the theoretical
     *         one. A front-end that shows the theoretical figure and then pays less
     *         has lied to the user.
     */
    function pendingOf(address vault, address user)
        public
        view
        returns (uint256 pendingUSD, uint256 pendingArtha)
    {
        Stake storage s = _stake[vault][user];
        pendingUSD = s.earnedUSD;

        if (s.shares != 0 && s.lastAccrualAt != 0 && block.timestamp > s.lastAccrualAt) {
            uint256 p = sharePriceUSD(vault);
            if (p != 0) {
                pendingUSD += _accrue(vault, s.shares, s.lastAccrualAt, block.timestamp, s.lastSharePriceUSD, p);
            }
        }

        pendingArtha = _quoteArtha(vault, pendingUSD);
        uint256 bal = arthaToken.balanceOf(address(this));
        if (pendingArtha > bal) pendingArtha = bal;
    }

    /// @notice Unclaimed ARTHA for a user across every vault they staked in.
    function pendingAll(address user)
        external
        view
        returns (address[] memory vaults, uint256[] memory usdAmounts, uint256 totalPendingArtha)
    {
        address[] storage list = userVaults[user];
        uint256 n = list.length;
        vaults = new address[](n);
        usdAmounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            vaults[i] = list[i];
            (uint256 u, uint256 a) = pendingOf(list[i], user);
            usdAmounts[i] = u;
            totalPendingArtha += a;
        }
    }

    /**
     * @notice A vault's full staking books.
     * @return shareToken     The vault's share token, custodied here when staked.
     * @return rateBps        The APR in force now.
     * @return arthaRatio_    ARTHA per 1 USD accrued, 18dp.
     * @return stakedShares_  Shares currently staked.
     * @return earnedUSD      Lifetime USD accrued by this vault's stakers.
     * @return arthaIssued    Lifetime ARTHA issued from this vault.
     */
    function vaultBooks(address vault)
        external
        view
        returns (
            address shareToken,
            uint256 rateBps,
            uint256 arthaRatio_,
            uint256 stakedShares_,
            uint256 earnedUSD,
            uint256 arthaIssued
        )
    {
        VaultData storage v = _vaultData[vault];
        return (v.shareToken, currentRate(vault), v.arthaRatio, v.totalStakedShares, v.totalEarnedUSD, v.totalArthaEarned);
    }

    /// @notice Programme-wide totals. Keep this contract's ARTHA balance at or above
    ///         `outstandingArtha` or claims will start partial-filling on liquidity.
    function globalBooks()
        external
        view
        returns (
            uint256 arthaMinted,
            uint256 arthaClaimed,
            uint256 outstandingArtha,
            uint256 arthaLeftInBudget,
            uint256 usdEarned,
            uint256 usdClaimed
        )
    {
        return (
            totalArthaMinted,
            totalClaimedArtha,
            _outstandingArtha(),
            MAX_ARTHA - totalArthaMinted,
            totalEarnedUSDGlobal,
            totalClaimedUSDGlobal
        );
    }

    /// @notice ARTHA issued per vault, for dashboards.
    function arthaIssuedPerVault() external view returns (address[] memory vaults, uint256[] memory issued) {
        uint256 n = registeredVaults.length;
        vaults = new address[](n);
        issued = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            vaults[i] = registeredVaults[i];
            issued[i] = _vaultData[registeredVaults[i]].totalArthaEarned;
        }
    }

    function userVaultsCount(address user) external view returns (uint256) {
        return userVaults[user].length;
    }

    function userVaultList(address user) external view returns (address[] memory) {
        return userVaults[user];
    }

    function registeredVaultsCount() external view returns (uint256) {
        return registeredVaults.length;
    }

    // ─────────────────────────────── internal ───────────────────────────────────

    /**
     * @dev What this contract still owes stakers in ARTHA.
     *
     *  Every USD accrued is a live claim on ARTHA, whether it has been settled into
     *  earnedUSD or is still sitting in an open window. Bounding rescue() by minted-
     *  minus-claimed alone would ignore the settled-but-unclaimed USD entirely and
     *  let the admin sweep it. So: unclaimed USD converted at the current ratio, plus
     *  anything minted and not yet taken.
     *
     *  This is deliberately an UNDER-estimate of the true liability in one respect --
     *  it cannot see open windows without walking every staker. Keep a buffer.
     *
     *  O(#vaults), view-only, admin path only.
     */
    function _outstandingArtha() internal view returns (uint256 owed) {
        uint256 n = registeredVaults.length;
        for (uint256 i = 0; i < n; i++) {
            address vaultAddr = registeredVaults[i];
            VaultData storage v = _vaultData[vaultAddr];
            if (v.arthaRatio == 0 || v.totalEarnedUSD == 0) continue;

            // Everything this vault's stakers ever accrued, priced in ARTHA at today's
            // ratio, minus what they already took. ARTHA is only ever credited AT
            // claim, so totalArthaEarned == totalArthaClaimed on this path -- the
            // liability cannot be read off the ARTHA counters at all. It lives in the
            // USD book, which is exactly why this loop converts rather than subtracts.
            uint256 wouldBe = (v.totalEarnedUSD * v.arthaRatio) / WAD;
            uint256 taken = v.totalArthaClaimed;
            if (wouldBe > taken) owed += wouldBe - taken;
        }

        // Cap the claim on reality: nothing above the remaining budget can ever be
        // paid, so nothing above it is a real debt.
        uint256 payable_ = MAX_ARTHA - totalArthaMinted;
        if (owed > payable_) owed = payable_;
    }

    function _isRegisteredShareToken(address _token) internal view returns (bool) {
        uint256 n = registeredVaults.length;
        for (uint256 i = 0; i < n; i++) {
            if (_vaultData[registeredVaults[i]].shareToken == _token) return true;
        }
        return false;
    }
}
