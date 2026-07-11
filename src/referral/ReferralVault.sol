// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "./ReferralSystem.sol";

/**
 * @title  ReferralVault
 * @notice Top layer — holds the ARTHA and pays code OWNERS based on HOW MUCH
 *         referred capital they bring, HOW LONG it stays, WHICH strategy it sits
 *         in, and WHICH tier the code is on.
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault (deployed)
 *
 *  ─────────────────────────────────────────────────────────────────────────────
 *  THE REWARD FORMULA (this is the whole product, in one line)
 *
 *      rewardPerYear = (amountNorm * tierRatio * rewardRatio) / 1e36        [ARTHA/yr]
 *      accrued       = rewardPerYear * elapsedSeconds / YEAR                [ARTHA]
 *
 *    where
 *      amountNorm  = referred principal normalised to 18 decimals
 *                    (raw * 10^(18 - tokenDecimals); USDC*1e12, DAI/WETH*1)
 *      rewardRatio = per-STRATEGY rate, set by governance, 0..1e18
 *                    (e.g. a USDC strategy 1e18, a WETH strategy 5e17)
 *      tierRatio   = per-TIER rate, set by governance, 0..1e18
 *                    (e.g. tier1 1e17, tier2 3e17, tier3 1e18)
 *      1e36        = 1e18 * 1e18 (normalises both ratios back out)
 *
 *    Because both ratios are capped at 1e18, their product is capped at 1e36, so
 *    the maximum reward is 100% of the referred principal per year, in ARTHA.
 *
 *  ─────────────────────────────────────────────────────────────────────────────
 *  KEYED BY STRATEGY ADDRESS, NOT BY TOKEN.
 *  All state is per `strategy` (the vault/strategy contract address). One base
 *  token can back several strategies, each with its own rewardRatio. A referred
 *  investor's balance is tracked per strategy, normalised to 18 dp on entry.
 *
 *  THE MECHANISM: MasterChef accumulators, one per (strategy, tier).
 *      acc[strategy][tier] += rewardRatio[strategy] * tierRatio[tier] * dt * ACC
 *                             / (1e36 * YEAR)
 *      earned(code,strategy) = balNorm(code,strategy) * acc[strategy][codeTier]/ACC
 *                              - rewardDebt
 *  Folding BOTH ratios into the accumulator (not applying tier at settle) keeps
 *  the design ZERO-RETROACTIVITY under every governance change:
 *    - changing rewardRatio[S] : we advance all tier lanes of S first,
 *    - changing tierRatio[t]   : we advance lane t of every strategy first,
 *    - promoting a code's tier : we bank it in the old lane, then re-checkpoint
 *                                it in the new lane.
 *  Old accrual always keeps the old rates; only future accrual uses new ones.
 *
 *  EVERYTHING IS VARIABLE. Investors deposit/withdraw any time. There is no lock,
 *  no fixed term. On every balance change the caller banks the code up to `now`
 *  first, so a shrinking position simply stops accruing on the part removed and
 *  the interest earned so far is already sitting in `earned`.
 *
 *  FUNDING: does NOT mint. Mint/transfer ARTHA into this contract up front; claims
 *  pay from balance. Governance can sweep genuine excess via rescue().
 */
contract ReferralVault is ReferralSystem, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---- fixed-point constants ----
    uint256 public constant ACC = 1e18;        // accumulator precision
    uint256 public constant YEAR = 365 days;   // seconds per year
    uint256 public constant RATIO_ONE = 1e18;  // "1.0" for a ratio; also the cap
    uint256 public constant RATIO_SQ = 1e36;   // RATIO_ONE * RATIO_ONE

    // ---- loop-bound safety (keep claimAll / rate changes O(bounded)) ----
    uint256 public constant MAX_STRATEGIES = 64;
    uint256 public constant MAX_TIERS = 8;

    IERC20 public immutable artha;

    /// @notice Global config + running totals for one strategy (all tiers).
    struct StrategyMeta {
        bool registered;
        uint256 rewardRatio;       // per-strategy rate, 0..1e18
        uint256 scale;             // 10^(18 - tokenDecimals); normalises raw -> 18dp
        uint256 totalReferredNorm; // total active referred principal (18dp) in this strategy
    }

    /// @notice One MasterChef lane per (strategy, tier).
    struct Lane {
        uint256 accArthaPerToken; // accumulator, scaled by ACC
        uint256 lastUpdate;       // last time this lane advanced (0 = uninitialised)
    }

    /// @notice Per (strategy, code) account.
    struct CodeAccount {
        uint256 balanceNorm; // active referred principal, normalised to 18dp
        uint256 rewardDebt;  // balanceNorm * acc[strategy][codeTier]/ACC at last settle
        uint256 earned;      // settled, claimable ARTHA
        uint256 claimed;     // lifetime claimed ARTHA (tracking)
    }

    mapping(address => StrategyMeta) public strategyMeta;                 // strategy => meta
    mapping(address => mapping(uint8 => Lane)) public lane;               // strategy => tier => lane
    mapping(address => mapping(uint64 => CodeAccount)) public codeAccount; // strategy => code => account
    mapping(uint8 => uint256) public tierRatio;                          // tier => ratio 0..1e18

    address[] public registeredStrategies;
    uint8[] public registeredTiers;
    mapping(uint8 => bool) private _tierKnown;

    // ---- vault-wide totals (rescue safety) ----
    uint256 public totalEarnedArtha;
    uint256 public totalClaimedArtha;

    event StrategyRegistered(address indexed strategy, uint8 tokenDecimals, uint256 scale, uint256 rewardRatio);
    event RewardRatioUpdated(address indexed strategy, uint256 oldRatio, uint256 newRatio);
    event TierRatioUpdated(uint8 indexed tier, uint256 oldRatio, uint256 newRatio);
    event CodeTierChanged(uint64 indexed code, uint8 oldTier, uint8 newTier);
    event Referred(address indexed strategy, uint64 indexed code, uint256 rawPrincipal, uint256 balanceNorm);
    event Unreferred(address indexed strategy, uint64 indexed code, uint256 rawPrincipal, uint256 balanceNorm);
    event RewardSettled(address indexed strategy, uint64 indexed code, uint256 pending);
    event RewardClaimed(address indexed strategy, uint64 indexed code, address indexed owner, address to, uint256 amount);
    event Rescued(address indexed token, address to, uint256 amount);

    constructor(address _artha, address _admin) ReferralSystem(_admin) {
        require(_artha != address(0), "INVALID_ARTHA");
        artha = IERC20(_artha);

        // Sensible defaults for the first three tiers; governance can change any of
        // them later via setTierRatio(). Cap is 1e18 ("1.0").
        _initTier(1, 1e17); // 0.1
        _initTier(2, 3e17); // 0.3
        _initTier(3, 1e18); // 1.0
    }

    // ───────────────────────────── configuration ────────────────────────────────

    /// @notice Register a strategy/vault so referred balances in it earn reward.
    /// @param  strategy      The vault/strategy contract address (the reward key).
    /// @param  tokenDecimals Decimals of that strategy's base token (USDC 6, WETH 18).
    /// @param  rewardRatio_  Per-strategy rate, 0..1e18 (e.g. USDC 1e18, WETH 5e17).
    function registerStrategy(address strategy, uint8 tokenDecimals, uint256 rewardRatio_)
        external
        onlyReferralVaultManager
    {
        require(strategy != address(0), "INVALID_STRATEGY");
        require(!strategyMeta[strategy].registered, "ALREADY_REGISTERED");
        require(tokenDecimals <= 18, "DECIMALS_GT_18");
        require(rewardRatio_ <= RATIO_ONE, "RATIO_GT_ONE");
        require(registeredStrategies.length < MAX_STRATEGIES, "TOO_MANY_STRATEGIES");

        uint256 scale = 10 ** (18 - tokenDecimals);
        strategyMeta[strategy] = StrategyMeta({
            registered: true,
            rewardRatio: rewardRatio_,
            scale: scale,
            totalReferredNorm: 0
        });
        registeredStrategies.push(strategy);
        emit StrategyRegistered(strategy, tokenDecimals, scale, rewardRatio_);
    }

    /// @notice Change a strategy's reward ratio. Advances EVERY tier lane of this
    ///         strategy first, so the change is not retroactive.
    function setRewardRatio(address strategy, uint256 newRatio) external onlyReferralVaultManager {
        require(strategyMeta[strategy].registered, "NOT_REGISTERED");
        require(newRatio <= RATIO_ONE, "RATIO_GT_ONE");
        uint256 n = registeredTiers.length;
        for (uint256 i = 0; i < n; i++) {
            _updateLane(strategy, registeredTiers[i]);
        }
        uint256 old = strategyMeta[strategy].rewardRatio;
        strategyMeta[strategy].rewardRatio = newRatio;
        emit RewardRatioUpdated(strategy, old, newRatio);
    }

    /// @notice Set a tier's ratio. Advances lane `tier` of EVERY strategy first, so
    ///         the change is not retroactive. Adds the tier to the known set.
    function setTierRatio(uint8 tier, uint256 newRatio) external onlyReferralVaultManager {
        require(tier != 0, "INVALID_TIER");
        require(newRatio <= RATIO_ONE, "RATIO_GT_ONE");
        uint256 n = registeredStrategies.length;
        for (uint256 i = 0; i < n; i++) {
            _updateLane(registeredStrategies[i], tier);
        }
        uint256 old = tierRatio[tier];
        tierRatio[tier] = newRatio;
        if (!_tierKnown[tier]) {
            require(registeredTiers.length < MAX_TIERS, "TOO_MANY_TIERS");
            _tierKnown[tier] = true;
            registeredTiers.push(tier);
        }
        emit TierRatioUpdated(tier, old, newRatio);
    }

    /// @notice Promote/demote a code's tier. Banks the code at its OLD tier lane in
    ///         every strategy, switches the tier, then re-checkpoints in the NEW
    ///         lane — so accrual before the change keeps the old tier's rate.
    function setCodeTier(uint64 code, uint8 newTier) external onlyReferralVaultManager {
        require(codeOwner[code] != address(0), "CODE_DOES_NOT_EXIST");
        require(newTier != 0, "INVALID_TIER");

        uint256 n = registeredStrategies.length;
        // 1) bank everything at the current (old) tier.
        for (uint256 i = 0; i < n; i++) {
            _settle(registeredStrategies[i], code);
        }
        // 2) switch the tier (registry write).
        uint8 oldTier = codeTier[code];
        _setCodeTier(code, newTier);
        // 3) re-checkpoint against the new tier's lane so future accrual uses it.
        for (uint256 i = 0; i < n; i++) {
            address s = registeredStrategies[i];
            _updateLane(s, newTier);
            CodeAccount storage a = codeAccount[s][code];
            a.rewardDebt = (a.balanceNorm * lane[s][newTier].accArthaPerToken) / ACC;
        }
        emit CodeTierChanged(code, oldTier, newTier);
    }

    // ───────────────────────────── accrual core ─────────────────────────────────

    /// @dev Advance one (strategy, tier) lane at the CURRENT rates over [last, now].
    ///      Lazily initialises lastUpdate so an untouched lane never back-pays.
    function _updateLane(address strategy, uint8 tier) internal {
        Lane storage L = lane[strategy][tier];
        uint256 nowTs = block.timestamp;
        if (L.lastUpdate == 0) {
            L.lastUpdate = nowTs; // first touch: start the clock, accrue nothing
            return;
        }
        if (nowTs <= L.lastUpdate) return;

        uint256 rr = strategyMeta[strategy].rewardRatio;
        uint256 tr = tierRatio[tier];
        if (rr != 0 && tr != 0) {
            uint256 dt = nowTs - L.lastUpdate;
            // acc += rewardRatio * tierRatio * dt * ACC / (1e36 * YEAR)
            L.accArthaPerToken += (rr * tr * dt * ACC) / (RATIO_SQ * YEAR);
        }
        L.lastUpdate = nowTs;
    }

    /// @dev Bank a code's accrued reward in one strategy into `earned`, using the
    ///      code's CURRENT tier lane, then refresh its checkpoint.
    function _settle(address strategy, uint64 code) internal {
        uint8 tier = codeTier[code];
        _updateLane(strategy, tier);
        CodeAccount storage a = codeAccount[strategy][code];
        uint256 accumulated = (a.balanceNorm * lane[strategy][tier].accArthaPerToken) / ACC;
        uint256 pending = accumulated - a.rewardDebt; // monotonic acc => never underflows
        if (pending != 0) {
            a.earned += pending;
            totalEarnedArtha += pending;
            emit RewardSettled(strategy, code, pending);
        }
        a.rewardDebt = accumulated;
    }

    // ─────────────────────────────── hooks ──────────────────────────────────────

    /**
     * @notice A referred deposit into `strategy`. The code is read from the
     *         investor's stored traderToCode — the investor never resends it.
     * @param  strategy     The vault/strategy contract that custodies the principal.
     * @param  investor     The depositor.
     * @param  rawPrincipal Referred amount in the strategy's base-token decimals.
     */
    function notifyDeposit(address strategy, address investor, uint256 rawPrincipal)
        external
        onlyCaller
        whenNotPaused
    {
        require(strategyMeta[strategy].registered, "NOT_REGISTERED");
        if (rawPrincipal == 0) return;

        uint64 code = traderToCode[investor];
        if (code == uint64(0)) return;                         // investor set no code
        address owner = codeOwner[code];
        if (owner == address(0) || owner == investor) return;  // deactivated / self-referral

        _settle(strategy, code);                               // bank at OLD balance
        uint256 addNorm = rawPrincipal * strategyMeta[strategy].scale;
        CodeAccount storage a = codeAccount[strategy][code];
        a.balanceNorm += addNorm;
        strategyMeta[strategy].totalReferredNorm += addNorm;
        // re-checkpoint at the new balance in the code's current tier lane
        a.rewardDebt = (a.balanceNorm * lane[strategy][codeTier[code]].accArthaPerToken) / ACC;

        emit Referred(strategy, code, rawPrincipal, a.balanceNorm);
    }

    /**
     * @notice A referred position in `strategy` shrinks or fully exits.
     * @param  strategy     The vault/strategy contract.
     * @param  investor     The withdrawing depositor.
     * @param  rawPrincipal Amount leaving, in base-token decimals.
     */
    function notifyWithdraw(address strategy, address investor, uint256 rawPrincipal)
        external
        onlyCaller
        whenNotPaused
    {
        require(strategyMeta[strategy].registered, "NOT_REGISTERED");
        if (rawPrincipal == 0) return;

        uint64 code = traderToCode[investor];
        if (code == uint64(0)) return;

        CodeAccount storage a = codeAccount[strategy][code];
        if (a.balanceNorm == 0) return;

        _settle(strategy, code);                               // bank up to now first

        uint256 decNorm = rawPrincipal * strategyMeta[strategy].scale;
        if (decNorm > a.balanceNorm) decNorm = a.balanceNorm;  // clamp (defensive)
        a.balanceNorm -= decNorm;
        strategyMeta[strategy].totalReferredNorm -= decNorm;
        a.rewardDebt = (a.balanceNorm * lane[strategy][codeTier[code]].accArthaPerToken) / ACC;

        emit Unreferred(strategy, code, rawPrincipal, a.balanceNorm);
    }

    /// @notice Permissionless: bring a code's `earned` in one strategy up to date.
    function sync(address strategy, uint64 code) external {
        require(strategyMeta[strategy].registered, "NOT_REGISTERED");
        _settle(strategy, code);
    }

    // ─────────────────────────────── claiming ───────────────────────────────────

    /// @notice The code's CURRENT owner withdraws its ARTHA from one strategy.
    function claim(address strategy, uint64 code, address to, uint256 amount)
        public
        nonReentrant
        whenNotPaused
    {
        require(strategyMeta[strategy].registered, "NOT_REGISTERED");
        require(to != address(0) && amount != 0, "INVALID_PARAMS");
        require(codeOwner[code] == msg.sender, "NOT_CODE_OWNER");

        _settle(strategy, code);
        CodeAccount storage a = codeAccount[strategy][code];
        require(a.earned >= amount, "INSUFFICIENT_REWARDS");

        a.earned -= amount;               // checks-effects-interactions
        a.claimed += amount;
        totalClaimedArtha += amount;
        artha.safeTransfer(to, amount);
        emit RewardClaimed(strategy, code, msg.sender, to, amount);
    }

    /// @notice Claim the full earned balance across every registered strategy.
    function claimAll(uint64 code, address to) external {
        require(codeOwner[code] == msg.sender, "NOT_CODE_OWNER");
        uint256 n = registeredStrategies.length;
        for (uint256 i = 0; i < n; i++) {
            address s = registeredStrategies[i];
            _settle(s, code);
            uint256 amt = codeAccount[s][code].earned;
            if (amt != 0) claim(s, code, to, amt); // reuses owner check + nonReentrant
        }
    }

    /**
     * @notice Deactivate a code. Requires it to be fully wound down first in EVERY
     *         strategy: no active balance and no unclaimed rewards anywhere.
     *         Callable by the code owner or the admin.
     */
    function deactivateCode(uint64 code) external {
        uint256 n = registeredStrategies.length;
        for (uint256 i = 0; i < n; i++) {
            address s = registeredStrategies[i];
            _settle(s, code);
            CodeAccount storage a = codeAccount[s][code];
            require(a.balanceNorm == 0, "HAS_ACTIVE_BALANCE");
            require(a.earned == 0, "HAS_UNCLAIMED_REWARDS");
        }
        _deactivateCode(code);
    }

    // ─────────────────────────────── rescue ─────────────────────────────────────

    /**
     * @notice Recover funds the vault should not keep: excess ARTHA (above what is
     *         already settled-and-unclaimed) or any stray token.
     * @dev    For ARTHA the cap is `balance - (totalEarned - totalClaimed)`. Reward
     *         still accruing on active codes is NOT reserved here — keep the vault
     *         funded above ongoing accrual and only sweep clear excess.
     */
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

    /// @notice Live claimable reward for a code in one strategy (settled + accruing).
    function pendingReward(address strategy, uint64 code) public view returns (uint256) {
        uint8 tier = codeTier[code];
        Lane storage L = lane[strategy][tier];
        uint256 accNow = L.accArthaPerToken;
        uint256 rr = strategyMeta[strategy].rewardRatio;
        uint256 tr = tierRatio[tier];
        if (L.lastUpdate != 0 && block.timestamp > L.lastUpdate && rr != 0 && tr != 0) {
            uint256 dt = block.timestamp - L.lastUpdate;
            accNow += (rr * tr * dt * ACC) / (RATIO_SQ * YEAR);
        }
        CodeAccount storage a = codeAccount[strategy][code];
        uint256 accumulated = (a.balanceNorm * accNow) / ACC;
        return a.earned + (accumulated - a.rewardDebt);
    }

    /// @notice Total live claimable for a code across every registered strategy.
    function pendingRewardAll(uint64 code) external view returns (uint256 total) {
        uint256 n = registeredStrategies.length;
        for (uint256 i = 0; i < n; i++) {
            total += pendingReward(registeredStrategies[i], code);
        }
    }

    function strategiesCount() external view returns (uint256) {
        return registeredStrategies.length;
    }

    function tiersCount() external view returns (uint256) {
        return registeredTiers.length;
    }

    // ─────────────────────────────── internal ───────────────────────────────────

    function _initTier(uint8 tier, uint256 ratio) private {
        tierRatio[tier] = ratio;
        _tierKnown[tier] = true;
        registeredTiers.push(tier);
    }
}
