// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "./ReferralSystem.sol";

/**
 * @title  ReferralVault
 * @notice Holds ARTHA and pays code OWNERS on: HOW MUCH referred capital, HOW LONG
 *         it stays, WHICH vault it sits in, and WHICH tier the code is on.
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault (deployed)
 *
 *  ─────────────────────────────────────────────────────────────────────────────
 *  REWARD FORMULA
 *      rewardPerYear = (amountNorm * tierRatio * rewardRatio) / 1e36     [ARTHA/yr]
 *      accrued       = rewardPerYear * elapsed / YEAR                   [ARTHA]
 *    amountNorm  = raw principal * 10^(18-decimals)   (USDC*1e12, DAI/WETH*1)
 *    rewardRatio = per-VAULT rate, 0..1e18       (USDC 1e18, WETH 5e17, ...)
 *    tierRatio   = per-TIER rate, 0..1e18       (tier1 1e17, tier2 3e17, tier3 1e18)
 *    YEAR        = 360 days  (protocol convention)
 *    Both ratios cap at 1e18 -> max reward = 100% of principal per year.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE CODE IS BOUND TO THE POSITION, NOT TO AN ADDRESS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `positionCode[vault][tokenId]` is the code that referred a given position. It
 *  is bound ONCE, on that position's first referred deposit, and is immutable for
 *  the life of the position. The Artha vault stores the code in its own position
 *  storage and passes it in on every hook.
 *
 *  This replaces the old `traderToCode[investor]` lookup, which was BROKEN because
 *  anyone may deposit into anyone's position but only the OWNER may withdraw --
 *  so the deposit hook and the withdraw hook resolved DIFFERENT codes, and the
 *  books could never close. A depositor's code kept a referral balance alive
 *  forever after the position was emptied and closed. See ReferralSystem's
 *  contract-level comment for the full walkthrough of that failure.
 *
 *      ┌────────────────────────────────────────────────────────────┐
 *      │  DEPOSIT  credits positionCode[vault][id].                 │
 *      │  WITHDRAW debits  positionCode[vault][id].                 │
 *      │  SAME KEY. ALWAYS.                                         │
 *      │                                                            │
 *      │  balanceNorm[code] is therefore the exact sum of the live  │
 *      │  principal of every position bound to that code. It cannot │
 *      │  be stranded and cannot underflow.                        │
 *      └────────────────────────────────────────────────────────────┘
 *
 *  WHY IMMUTABLE ONCE BOUND. If a position could re-bind to a new code, a user
 *  could park capital under code A for a year, then re-point it at code B they
 *  also control -- or worse, front-run a tier promotion. Binding once, at first
 *  deposit, means the referrer who brought the position in keeps it. This is the
 *  same reasoning that made the old `setTraderCode` set-once; we have simply moved
 *  the binding to the correct object.
 *
 *  NFT TRANSFER. The code does NOT move and does NOT reset. Bob referred the
 *  POSITION; if the position changes hands, the capital Bob introduced is still
 *  in the vault, so Bob still earns on it. Resetting on transfer would let anyone
 *  wash the referral off by selling to an alt. Nothing accrues to the buyer's
 *  referrer, because the buyer never made a referred deposit.
 *
 *  ─────────────────────────────────────────────────────────────────────────────
 *  WHY THIS SCALES TO MANY (uint64) VAULTS
 *
 *  The rate for a (vault V, tier t) position is rewardRatio[V]*tierRatio[t] — a
 *  PRODUCT of two independently-governed rates. A naive per-(V,t) accumulator would
 *  have to be advanced for EVERY vault whenever a tier ratio changes (fan-out
 *  over vaults) — impossible at uint64 scale. So we SPLIT it:
 *
 *    • accTierSeconds[t] = ∫ tierRatio[t](τ) dτ          (one integral per tier)
 *        A tier-ratio change advances THIS integral only — O(1), no vault touch.
 *        It literally stores "old ratio up to the change timestamp, new after":
 *        tierLastUpdate[t] is the boundary; the integral banks the old ratio up to
 *        it; everything after uses the new ratio.
 *
 *    • lane[V][t].acc    = ARTHA per normalised token for that (V,t) pair
 *        acc += rewardRatio[V] * Δ(accTierSeconds[t]) * ACC / (1e36 * YEAR)
 *        Valid because rewardRatio[V] is held CONSTANT across the window: a
 *        reward-ratio change advances every registered tier lane of V FIRST
 *        (fan-out over TIERS ≤ 8 — trivial), then writes the new ratio.
 *
 *  Cost:  tier ratio change O(1);  vault ratio change O(#tiers ≤ 8);
 *         code promotion O(#vaults-the-code-uses).  No loop over the global
 *         vault set anywhere -> vaults may number up to type(uint64).max.
 *
 *  ZERO RETROACTIVITY & PERMISSIONLESS SYNC
 *    Every ratio change banks the old rate at the change instant, so late settlers
 *    get the old rate up to the change and the new rate after — never the new rate
 *    on old time. If a code owner does not settle, ANYONE may call sync()/syncAll()
 *    to convert that code's PENDING into CLAIMABLE `earned` WITHOUT claiming.
 *
 *  DOUBLE-SYNC SAFETY
 *    _settle() sets rewardDebt = accumulated AFTER banking; an immediate second
 *    settle computes pending = accumulated - rewardDebt = 0. No path pays twice.
 *
 *  PER-VAULT BOOKS: live referred principal (raw + normalised) and cumulative
 *  ARTHA earned/claimed, per vault — see VaultMeta and vaultBooks().
 *
 *  FUNDING: does NOT mint. Fund with ARTHA up front; claims pay from balance.
 */
contract ReferralVault is ReferralSystem, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---- fixed-point constants ----
    uint256 public constant ACC = 1e18;        // accumulator precision
    uint256 public constant YEAR = 360 days;   // 360-day year (protocol convention)
    uint256 public constant RATIO_ONE = 1e18;  // "1.0" and the cap for any ratio
    uint256 public constant RATIO_SQ = 1e36;   // RATIO_ONE * RATIO_ONE

    uint8 public constant MAX_TIERS = 8;       // tiers 1..8

    IERC20 public immutable artha;

    /// @notice Config + running books for one vault (across all tiers).
    struct VaultMeta {
        bool registered;
        uint8 decimals;            // base-token decimals (for reference)
        uint256 rewardRatio;       // per-vault rate, 0..1e18
        uint256 scale;             // 10^(18 - decimals); raw -> 18dp
        uint256 totalPrincipalRaw; // live referred principal, raw base-token units
        uint256 totalReferredNorm; // live referred principal, normalised 18dp
        uint256 totalArthaEarned;  // cumulative ARTHA credited for this vault
        uint256 totalArthaClaimed; // cumulative ARTHA claimed from this vault
    }

    /// @notice ARTHA-per-normalised-token accumulator for one (vault, tier).
    struct Lane {
        bool init;                // false until first touch (no back-pay before then)
        uint256 acc;              // scaled by ACC
        uint256 tierSecondsMark;  // accTierSeconds[tier] snapshot at last advance
    }

    /// @notice Per (vault, code) account.
    struct CodeAccount {
        uint256 balanceNorm; // live referred principal, 18dp
        uint256 rewardDebt;  // balanceNorm * lane.acc / ACC at last settle
        uint256 earned;      // settled, claimable ARTHA
        uint256 claimed;     // lifetime claimed ARTHA (tracking)
    }

    // ---- vault config / books ----
    mapping(address => VaultMeta) public vaultMeta;
    uint64 public vaultCount; // registered vaults (uint64 space)

    // ---- tiers: global ratio-seconds integrals ----
    mapping(uint8 => uint256) public tierRatio;      // tier => ratio 0..1e18
    mapping(uint8 => uint256) public accTierSeconds; // tier => ∫ tierRatio dτ
    mapping(uint8 => uint256) public tierLastUpdate; // tier => last advance ts (change boundary)
    uint8[] public registeredTiers;                  // ≤ MAX_TIERS
    mapping(uint8 => bool) private _tierKnown;

    // ---- per-(vault,tier) lanes and per-(vault,code) accounts ----
    mapping(address => mapping(uint8 => Lane)) public lane;
    mapping(address => mapping(uint64 => CodeAccount)) public codeAccount;

    /**
     * @notice vault => tokenId => the code that referred this position.
     *
     *  THE CORE MAPPING OF THE FIX. Bound once on the position's first referred
     *  deposit; immutable thereafter. Zero means "this position was never
     *  referred" -- its deposits and withdrawals are no-ops for the referral book.
     *
     *  Both notifyDeposit and notifyWithdraw resolve the code from HERE, so they
     *  can never disagree.
     */
    mapping(address => mapping(uint256 => uint64)) public positionCode;

    /// @notice vault => tokenId => live referred principal of that POSITION, 18dp.
    /// @dev    Σ positionPrincipalNorm[v][id] over a code's positions
    ///         == codeAccount[v][code].balanceNorm. Enables exact per-position
    ///         debits and makes the invariant checkable on-chain.
    mapping(address => mapping(uint256 => uint256)) public positionPrincipalNorm;

    // ---- per-code footprint (bounds claimAll / deactivate / pendingAll / syncAll) ----
    mapping(uint64 => address[]) public codeVaults;
    mapping(uint64 => mapping(address => bool)) public codeHasVault;

    // ---- vault-wide totals (rescue safety) ----
    uint256 public totalEarnedArtha;
    uint256 public totalClaimedArtha;

    event VaultRegistered(address indexed vault, uint8 decimals, uint256 scale, uint256 rewardRatio);
    event RewardRatioUpdated(address indexed vault, uint256 oldRatio, uint256 newRatio, uint256 atTimestamp);
    event TierRatioUpdated(uint8 indexed tier, uint256 oldRatio, uint256 newRatio, uint256 atTimestamp);
    event CodeTierChanged(uint64 indexed code, uint8 oldTier, uint8 newTier);
    event PositionBound(address indexed vault, uint256 indexed tokenId, uint64 indexed code);
    event Referred(address indexed vault, uint64 indexed code, uint256 indexed tokenId, uint256 rawPrincipal, uint256 balanceNorm);
    event Unreferred(address indexed vault, uint64 indexed code, uint256 indexed tokenId, uint256 rawPrincipal, uint256 balanceNorm);
    event RewardSettled(address indexed vault, uint64 indexed code, uint256 pending);
    event RewardClaimed(address indexed vault, uint64 indexed code, address indexed owner, address to, uint256 amount);
    event Rescued(address indexed token, address to, uint256 amount);

    constructor(address _artha, address _admin) ReferralSystem(_admin) {
        require(_artha != address(0), "INVALID_ARTHA");
        artha = IERC20(_artha);

        // default tiers (governance may change any ratio and add tiers up to 8)
        _initTier(1, 1e17); // 0.1
        _initTier(2, 3e17); // 0.3
        _initTier(3, 1e18); // 1.0
    }

    // ─────────────────────── tier ratio-seconds integral ─────────────────────────

    /// @dev Advance accTierSeconds[t] to now using CURRENT tierRatio[t]. Storing the
    ///      integral IS storing "old ratio up to tierLastUpdate, new after".
    function _syncTier(uint8 t) internal {
        uint256 nowTs = block.timestamp;
        uint256 last = tierLastUpdate[t];
        if (last == 0) {
            tierLastUpdate[t] = nowTs;
            return;
        }
        if (nowTs > last) {
            accTierSeconds[t] += tierRatio[t] * (nowTs - last);
            tierLastUpdate[t] = nowTs;
        }
    }

    // ─────────────────────────── lane accrual core ──────────────────────────────

    /// @dev Advance one (vault, tier) lane. rewardRatio[V] is constant across the
    ///      window (setRewardRatio advances every tier lane of V before changing it).
    function _updateLane(address vault, uint8 tier) internal {
        _syncTier(tier);
        Lane storage L = lane[vault][tier];
        if (!L.init) {
            L.init = true;
            L.tierSecondsMark = accTierSeconds[tier];
            return;
        }
        uint256 dts = accTierSeconds[tier] - L.tierSecondsMark;
        if (dts != 0) {
            uint256 rr = vaultMeta[vault].rewardRatio;
            if (rr != 0) {
                L.acc += (rr * dts * ACC) / (RATIO_SQ * YEAR);
            }
            L.tierSecondsMark = accTierSeconds[tier];
        }
    }

    /// @dev Bank a code's accrued reward in one vault into `earned`, then refresh
    ///      its checkpoint. Idempotent within a block (double-settle banks nothing).
    function _settle(address vault, uint64 code) internal {
        uint8 tier = codeTier[code];
        _updateLane(vault, tier);
        CodeAccount storage a = codeAccount[vault][code];
        uint256 accumulated = (a.balanceNorm * lane[vault][tier].acc) / ACC;
        uint256 pending = accumulated - a.rewardDebt; // acc monotonic -> never underflows
        if (pending != 0) {
            a.earned += pending;
            vaultMeta[vault].totalArthaEarned += pending;
            totalEarnedArtha += pending;
            emit RewardSettled(vault, code, pending);
        }
        a.rewardDebt = accumulated;
    }

    // ───────────────────────────── configuration ────────────────────────────────

    /// @notice Register a vault so referred balances in it earn reward.
    function registerVault(address vault, uint8 decimals, uint256 rewardRatio_)
        external
        onlyReferralVaultManager
    {
        require(vault != address(0), "INVALID_VAULT");
        require(!vaultMeta[vault].registered, "ALREADY_REGISTERED");
        require(decimals <= 18, "DECIMALS_GT_18");
        require(rewardRatio_ <= RATIO_ONE, "RATIO_GT_ONE");
        require(vaultCount < type(uint64).max, "TOO_MANY_VAULTS");

        uint256 scale = 10 ** (18 - decimals);
        vaultMeta[vault] = VaultMeta({
            registered: true,
            decimals: decimals,
            rewardRatio: rewardRatio_,
            scale: scale,
            totalPrincipalRaw: 0,
            totalReferredNorm: 0,
            totalArthaEarned: 0,
            totalArthaClaimed: 0
        });
        unchecked {
            vaultCount += 1;
        }
        emit VaultRegistered(vault, decimals, scale, rewardRatio_);
    }

    /// @notice Change a vault's reward ratio. Advances EVERY tier lane of this
    ///         vault first (≤8) so the change is not retroactive.
    function setRewardRatio(address vault, uint256 newRatio) external onlyReferralVaultManager {
        require(vaultMeta[vault].registered, "NOT_REGISTERED");
        require(newRatio <= RATIO_ONE, "RATIO_GT_ONE");
        uint256 n = registeredTiers.length;
        for (uint256 i = 0; i < n; i++) {
            _updateLane(vault, registeredTiers[i]); // bank old rate into each lane
        }
        uint256 old = vaultMeta[vault].rewardRatio;
        vaultMeta[vault].rewardRatio = newRatio;
        emit RewardRatioUpdated(vault, old, newRatio, block.timestamp);
    }

    /// @notice Set a tier's ratio. O(1): advances ONLY this tier's ratio-seconds
    ///         integral (banking the old ratio up to now), then writes the new ratio.
    ///         Vault lanes pick up the correct old/new split on next advance.
    function setTierRatio(uint8 tier, uint256 newRatio) external onlyReferralVaultManager {
        require(tier != 0, "INVALID_TIER");
        require(newRatio <= RATIO_ONE, "RATIO_GT_ONE");
        _syncTier(tier); // bank old ratio up to the change boundary
        uint256 old = tierRatio[tier];
        tierRatio[tier] = newRatio;
        if (!_tierKnown[tier]) {
            require(registeredTiers.length < MAX_TIERS, "TOO_MANY_TIERS");
            _tierKnown[tier] = true;
            if (tierLastUpdate[tier] == 0) tierLastUpdate[tier] = block.timestamp;
            registeredTiers.push(tier);
        }
        emit TierRatioUpdated(tier, old, newRatio, block.timestamp);
    }

    /// @notice Promote/demote a code's tier. Banks the code at its OLD tier lane in
    ///         each vault it uses, switches the tier, then re-checkpoints in the
    ///         NEW tier lane — accrual before the change keeps the old tier's rate.
    function setCodeTier(uint64 code, uint8 newTier) external onlyReferralVaultManager {
        require(codeOwner[code] != address(0), "CODE_DOES_NOT_EXIST");
        require(_tierKnown[newTier], "TIER_NOT_SET");

        address[] storage list = codeVaults[code];
        uint256 n = list.length;

        // 1) bank everything at the current (old) tier.
        for (uint256 i = 0; i < n; i++) {
            _settle(list[i], code);
        }
        // 2) switch the tier (registry write in ReferralSystem).
        uint8 oldTier = codeTier[code];
        _setCodeTier(code, newTier);
        // 3) re-checkpoint against the new tier lane so future accrual uses it.
        for (uint256 i = 0; i < n; i++) {
            address v = list[i];
            _updateLane(v, newTier);
            CodeAccount storage a = codeAccount[v][code];
            a.rewardDebt = (a.balanceNorm * lane[v][newTier].acc) / ACC;
        }
        emit CodeTierChanged(code, oldTier, newTier);
    }

    // ─────────────────────────────── hooks ──────────────────────────────────────

    /**
     * @notice A deposit landed in `tokenId`. Grow the POSITION's referred balance.
     *
     *  ┌──────────────────────────────────────────────────────────────────────┐
     *  │  THE CODE COMES FROM THE POSITION, NOT FROM THE DEPOSITOR.           │
     *  │                                                                      │
     *  │  On the FIRST referred deposit we BIND `_code` to the position and   │
     *  │  it is immutable forever. On every later deposit -- by ANYONE, for   │
     *  │  ANY reason -- we IGNORE the passed `_code` and use the bound one.   │
     *  │                                                                      │
     *  │  That is what kills the phantom. If user-2 (holding Carol's code)    │
     *  │  gifts capital into user-1's Bob-referred position, the capital      │
     *  │  joins BOB's balance. Carol gets nothing -- correctly, since she     │
     *  │  referred nothing. And when the OWNER later withdraws, we debit      │
     *  │  BOB, the same key we credited. The books close.                     │
     *  └──────────────────────────────────────────────────────────────────────┘
     *
     * @param _vault        The calling vault. MUST equal msg.sender.
     * @param _tokenId      The position the money went into.
     * @param _owner        ownerOf(_tokenId) right now. Used for the self-referral
     *                      check at bind time only.
     * @param _code         The code to bind, IF this position is not yet bound.
     *                      Ignored otherwise. Pass 0 for an unreferred deposit.
     * @param _rawPrincipal NET base token credited (after the vault's entry fee).
     */
    function notifyDeposit(
        address _vault,
        uint256 _tokenId,
        address _owner,
        uint64 _code,
        uint256 _rawPrincipal
    ) external onlyCaller(_vault) whenNotPaused {
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");
        if (_rawPrincipal == 0) return;

        uint64 code = positionCode[_vault][_tokenId];

        // ── first touch: bind the code to the POSITION, once, forever ──
        if (code == uint64(0)) {
            if (_code == uint64(0)) return;               // unreferred position
            address owner = codeOwner[_code];
            if (owner == address(0)) return;              // code deactivated/nonexistent
            if (owner == _owner) return;                  // self-referral blocked
            code = _code;
            positionCode[_vault][_tokenId] = code;
            emit PositionBound(_vault, _tokenId, code);
        }
        // else: ALREADY BOUND. `_code` is ignored entirely -- the position's code
        // wins. This is what makes deposit and withdraw agree.

        if (codeOwner[code] == address(0)) return;        // bound code since deactivated

        _settle(_vault, code); // bank at OLD balance

        uint256 addNorm = _rawPrincipal * vaultMeta[_vault].scale;
        CodeAccount storage a = codeAccount[_vault][code];
        a.balanceNorm += addNorm;
        positionPrincipalNorm[_vault][_tokenId] += addNorm;

        VaultMeta storage m = vaultMeta[_vault];
        m.totalPrincipalRaw += _rawPrincipal;
        m.totalReferredNorm += addNorm;

        a.rewardDebt = (a.balanceNorm * lane[_vault][codeTier[code]].acc) / ACC; // re-checkpoint

        if (!codeHasVault[code][_vault]) {
            codeHasVault[code][_vault] = true;
            codeVaults[code].push(_vault);
        }
        emit Referred(_vault, code, _tokenId, _rawPrincipal, a.balanceNorm);
    }

    /**
     * @notice Principal left `tokenId`. Shrink the POSITION's referred balance.
     *
     *  The code is read from `positionCode[_vault][_tokenId]` -- the SAME source
     *  notifyDeposit credited. There is no `investor` parameter and no address
     *  lookup, because the withdrawer's identity is irrelevant: the money left the
     *  POSITION, so the POSITION's code is debited.
     *
     *  The debit is clamped to the position's OWN principal, not the code's total,
     *  so one position can never eat another position's referred balance even if
     *  the vault reports a wrong number.
     *
     * @param _rawPrincipal The COST BASIS consumed by this withdrawal, raw units.
     *                      The vault MUST pass basisUsed, NOT the current value --
     *                      reward principal tracks deposited capital, not value.
     */
    function notifyWithdraw(address _vault, uint256 _tokenId, uint256 _rawPrincipal)
        external
        onlyCaller(_vault)
        whenNotPaused
    {
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");
        if (_rawPrincipal == 0) return;

        uint64 code = positionCode[_vault][_tokenId]; // <- SAME KEY AS DEPOSIT
        if (code == uint64(0)) return;                // unreferred position

        uint256 posNorm = positionPrincipalNorm[_vault][_tokenId];
        if (posNorm == 0) return;

        CodeAccount storage a = codeAccount[_vault][code];
        if (a.balanceNorm == 0) return;

        _settle(_vault, code); // bank up to now first

        uint256 scale = vaultMeta[_vault].scale;
        uint256 decNorm = _rawPrincipal * scale;

        // clamp to THIS POSITION's principal -- never another position's
        if (decNorm > posNorm) decNorm = posNorm;
        if (decNorm > a.balanceNorm) decNorm = a.balanceNorm; // defensive

        uint256 decRaw = decNorm / scale;

        positionPrincipalNorm[_vault][_tokenId] = posNorm - decNorm;
        a.balanceNorm -= decNorm;

        VaultMeta storage m = vaultMeta[_vault];
        m.totalReferredNorm -= decNorm;
        m.totalPrincipalRaw = m.totalPrincipalRaw >= decRaw ? m.totalPrincipalRaw - decRaw : 0;

        a.rewardDebt = (a.balanceNorm * lane[_vault][codeTier[code]].acc) / ACC;
        emit Unreferred(_vault, code, _tokenId, decRaw, a.balanceNorm);
    }

    /**
     * @notice The position's NFT changed hands.
     *
     *  THE CODE DOES NOT MOVE AND DOES NOT RESET. Bob referred the POSITION and the
     *  capital he introduced is still in the vault, so Bob keeps earning on it.
     *
     *  Resetting the code on transfer would be an obvious wash: deposit under no
     *  code, then transfer to yourself to re-bind under a code you own. Moving it
     *  to the buyer's referrer would be worse -- it would pay someone who had
     *  nothing to do with the capital entering the protocol.
     *
     *  This hook exists so the vault has ONE uniform integration shape across both
     *  reward stacks, and so we can settle at the boundary for clean accounting.
     *  It is a no-op for balances.
     */
    function notifyTransfer(address _vault, uint256 _tokenId, address _from, address _to)
        external
        onlyCaller(_vault)
        whenNotPaused
    {
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");
        if (_from == _to) return;

        uint64 code = positionCode[_vault][_tokenId];
        if (code == uint64(0)) return; // unreferred position: nothing to do

        // Settle at the boundary so `earned` is exact as of the transfer.
        // Balances are untouched: the code stays bound to the position.
        _settle(_vault, code);
    }

    // ───────────────────────── permissionless sync ──────────────────────────────

    /// @notice Anyone may bank a code's PENDING -> CLAIMABLE in one vault without
    ///         claiming. Safe to call repeatedly (double-sync banks nothing extra).
    function sync(address vault, uint64 code) public {
        require(vaultMeta[vault].registered, "NOT_REGISTERED");
        _settle(vault, code);
    }

    /// @notice Anyone may bank a code across every vault it uses.
    function syncAll(uint64 code) external {
        address[] storage list = codeVaults[code];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) _settle(list[i], code);
    }

    // ─────────────────────────────── claiming ───────────────────────────────────

    /// @notice The code's CURRENT owner withdraws its ARTHA from one vault.
    function claim(address vault, uint64 code, address to, uint256 amount)
        public
        nonReentrant
        whenNotPaused
    {
        require(vaultMeta[vault].registered, "NOT_REGISTERED");
        require(to != address(0) && amount != 0, "INVALID_PARAMS");
        require(codeOwner[code] == msg.sender, "NOT_CODE_OWNER");

        _settle(vault, code);
        CodeAccount storage a = codeAccount[vault][code];
        require(a.earned >= amount, "INSUFFICIENT_REWARDS");

        a.earned -= amount;
        a.claimed += amount;
        vaultMeta[vault].totalArthaClaimed += amount;
        totalClaimedArtha += amount;
        artha.safeTransfer(to, amount);
        emit RewardClaimed(vault, code, msg.sender, to, amount);
    }

    /// @notice Claim the full earned balance across every vault the code uses.
    function claimAll(uint64 code, address to) external {
        require(codeOwner[code] == msg.sender, "NOT_CODE_OWNER");
        address[] storage list = codeVaults[code];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            address v = list[i];
            _settle(v, code);
            uint256 amt = codeAccount[v][code].earned;
            if (amt != 0) claim(v, code, to, amt);
        }
    }

    /// @notice Deactivate a code once fully wound down (zero balance and zero
    ///         unclaimed) in every vault it used.
    function deactivateCode(uint64 code) external {
        address[] storage list = codeVaults[code];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            address v = list[i];
            _settle(v, code);
            CodeAccount storage a = codeAccount[v][code];
            require(a.balanceNorm == 0, "HAS_ACTIVE_BALANCE");
            require(a.earned == 0, "HAS_UNCLAIMED_REWARDS");
        }
        _deactivateCode(code);
    }

    // ─────────────────────────────── rescue ─────────────────────────────────────

    function rescue(address token, address to, uint256 amount) external onlyReferralVaultManager {
        require(to != address(0) && amount != 0, "INVALID_PARAMS");
        if (token == address(artha)) {
            uint256 owed = totalEarnedArtha - totalClaimedArtha;
            uint256 bal = artha.balanceOf(address(this));
            uint256 excess = bal > owed ? bal - owed : 0;
            require(amount <= excess, "EXCEEDS_EXCESS");
        }
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ─────────────────────────────── views ──────────────────────────────────────

    /// @notice Live claimable reward for a code in one vault (settled + accruing).
    function pendingReward(address vault, uint64 code) public view returns (uint256) {
        uint8 tier = codeTier[code];

        uint256 ats = accTierSeconds[tier];
        uint256 last = tierLastUpdate[tier];
        if (last != 0 && block.timestamp > last) {
            ats += tierRatio[tier] * (block.timestamp - last);
        }

        Lane storage L = lane[vault][tier];
        uint256 accNow = L.acc;
        if (L.init) {
            uint256 dts = ats - L.tierSecondsMark;
            uint256 rr = vaultMeta[vault].rewardRatio;
            if (dts != 0 && rr != 0) accNow += (rr * dts * ACC) / (RATIO_SQ * YEAR);
        }

        CodeAccount storage a = codeAccount[vault][code];
        uint256 accumulated = (a.balanceNorm * accNow) / ACC;
        return a.earned + (accumulated - a.rewardDebt);
    }

    /// @notice Total live claimable for a code across every vault it uses.
    function pendingRewardAll(uint64 code) external view returns (uint256 total) {
        address[] storage list = codeVaults[code];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) total += pendingReward(list[i], code);
    }

    /// @notice Per-vault books: live principal (raw + normalised) and ARTHA flows.
    function vaultBooks(address vault)
        external
        view
        returns (
            uint256 rewardRatio_,
            uint256 principalRaw,
            uint256 principalNorm,
            uint256 arthaEarned,
            uint256 arthaClaimed,
            uint256 arthaOutstanding
        )
    {
        VaultMeta storage m = vaultMeta[vault];
        return (
            m.rewardRatio,
            m.totalPrincipalRaw,
            m.totalReferredNorm,
            m.totalArthaEarned,
            m.totalArthaClaimed,
            m.totalArthaEarned - m.totalArthaClaimed
        );
    }

    /// @notice Live referred principal of one position, in raw base-token units.
    function positionPrincipalRaw(address vault, uint256 tokenId) external view returns (uint256) {
        return positionPrincipalNorm[vault][tokenId] / vaultMeta[vault].scale;
    }

    function codeVaultsCount(uint64 code) external view returns (uint256) {
        return codeVaults[code].length;
    }

    function tiersCount() external view returns (uint256) {
        return registeredTiers.length;
    }

    // ─────────────────────────────── internal ───────────────────────────────────

    function _initTier(uint8 tier, uint256 ratio) private {
        tierRatio[tier] = ratio;
        tierLastUpdate[tier] = block.timestamp; // start the integral clock now
        _tierKnown[tier] = true;
        registeredTiers.push(tier);
    }
}
