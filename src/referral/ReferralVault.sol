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

    uint8   public constant MAX_TIERS = 8;     // tiers 1..8

    IERC20 public immutable artha;

    /// @notice Config + running books for one vault (across all tiers).
    struct VaultMeta {
        bool    registered;
        uint8   decimals;          // base-token decimals (for reference)
        uint256 rewardRatio;       // per-vault rate, 0..1e18
        uint256 scale;             // 10^(18 - decimals); raw -> 18dp
        uint256 totalPrincipalRaw; // live referred principal, raw base-token units
        uint256 totalReferredNorm; // live referred principal, normalised 18dp
        uint256 totalArthaEarned;  // cumulative ARTHA credited for this vault
        uint256 totalArthaClaimed; // cumulative ARTHA claimed from this vault
    }

    /// @notice ARTHA-per-normalised-token accumulator for one (vault, tier).
    struct Lane {
        bool    init;             // false until first touch (no back-pay before then)
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
    event Referred(address indexed vault, uint64 indexed code, uint256 rawPrincipal, uint256 balanceNorm);
    event Unreferred(address indexed vault, uint64 indexed code, uint256 rawPrincipal, uint256 balanceNorm);
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
        if (last == 0) { tierLastUpdate[t] = nowTs; return; }
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
        unchecked { vaultCount += 1; }
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

    /// @notice A referred deposit into `vault`. Code read from traderToCode.
    function notifyDeposit(address vault, address investor, uint256 rawPrincipal)
        external
        onlyCaller
        whenNotPaused
    {
        require(vaultMeta[vault].registered, "NOT_REGISTERED");
        if (rawPrincipal == 0) return;

        uint64 code = traderToCode[investor];
        if (code == uint64(0)) return;
        address owner = codeOwner[code];
        if (owner == address(0) || owner == investor) return; // deactivated / self-referral

        _settle(vault, code); // bank at OLD balance
        uint256 addNorm = rawPrincipal * vaultMeta[vault].scale;
        CodeAccount storage a = codeAccount[vault][code];
        a.balanceNorm += addNorm;

        VaultMeta storage m = vaultMeta[vault];
        m.totalPrincipalRaw += rawPrincipal;
        m.totalReferredNorm += addNorm;

        a.rewardDebt = (a.balanceNorm * lane[vault][codeTier[code]].acc) / ACC; // re-checkpoint

        if (!codeHasVault[code][vault]) {
            codeHasVault[code][vault] = true;
            codeVaults[code].push(vault);
        }
        emit Referred(vault, code, rawPrincipal, a.balanceNorm);
    }

    /// @notice A referred position in `vault` shrinks or fully exits.
    function notifyWithdraw(address vault, address investor, uint256 rawPrincipal)
        external
        onlyCaller
        whenNotPaused
    {
        require(vaultMeta[vault].registered, "NOT_REGISTERED");
        if (rawPrincipal == 0) return;

        uint64 code = traderToCode[investor];
        if (code == uint64(0)) return;

        CodeAccount storage a = codeAccount[vault][code];
        if (a.balanceNorm == 0) return;

        _settle(vault, code); // bank up to now first

        uint256 scale = vaultMeta[vault].scale;
        uint256 decNorm = rawPrincipal * scale;
        if (decNorm > a.balanceNorm) decNorm = a.balanceNorm; // clamp (defensive)
        uint256 decRaw = decNorm / scale;
        a.balanceNorm -= decNorm;

        VaultMeta storage m = vaultMeta[vault];
        m.totalReferredNorm -= decNorm;
        m.totalPrincipalRaw = m.totalPrincipalRaw >= decRaw ? m.totalPrincipalRaw - decRaw : 0;

        a.rewardDebt = (a.balanceNorm * lane[vault][codeTier[code]].acc) / ACC;
        emit Unreferred(vault, code, decRaw, a.balanceNorm);
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
