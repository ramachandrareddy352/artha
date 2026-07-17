// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "./ReferralSystem.sol";
import "./interfaces/IReferralVault.sol";

/**
 * @title  ReferralVault
 * @notice Splits a vault's PERFORMANCE FEE between the protocol and the referrer,
 *         rebates part of the referrer's cut to the trader, and credits ARTHA on
 *         top -- all in ONE call, at the moment the fee is charged.
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault (deployed)
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE SPLIT
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  A trader deposits 1,000 USDC and withdraws with 100 USDC of profit. The vault's
 *  performance fee is 10%, so 10 USDC is charged. That 10 USDC -- and ONLY that 10
 *  USDC -- is what the referral programme touches. Principal is never at risk and
 *  the trader's 90 USDC of profit is never reduced.
 *
 *      performanceFee = 10 USDC                        (charged by the vault)
 *
 *      ownerGross     = fee * tierRewardRatio[V][t] / RATIO_ONE
 *                     = 10 * 20_000 / 100_000  =  2 USDC        (tier-2, 20%)
 *      protocol       = fee - ownerGross        =  8 USDC
 *
 *      discount       = ownerGross * codeDiscount[c] / RATIO_ONE
 *                     = 2 * 10_000 / 100_000   =  0.2 USDC      (10% rebate)
 *      ownerNet       = ownerGross - discount   =  1.8 USDC
 *
 *  With NO referral (trader never bound a code, or bound one that is now dead),
 *  ownerGross is zero and the protocol keeps the ENTIRE 10 USDC. The referral
 *  contract is never called and never holds a cent.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ARTHA IS PRICED ON THE GROSS, NOT THE NET
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  ARTHA is credited on `ownerGross` (2 USDC), NOT on `ownerNet` (1.8 USDC). If it
 *  were priced on the net, generosity would be punished twice -- an owner who
 *  rebates 50% to win traders would lose half his ARTHA as well, so every rational
 *  owner would set discount = 0 and the lever would be dead on arrival. Pricing on
 *  the gross makes the discount a pure choice about base tokens: rebate as hard as
 *  you like, your ARTHA is untouched.
 *
 *  CONVERSION.  gross (raw, 6..18dp)
 *                 -> norm18   = gross * scale                   [18dp]
 *                 -> usd18    = norm18 * price / 1e8            [18dp USD]
 *                 -> artha    = usd18 * arthaRatio[V] / 1e18    [18dp ARTHA]
 *
 *  `arthaRatio[V]` is "ARTHA per 1 USD of commission", 18dp, per VAULT:
 *      USDC vault => 1e18  -> 2 USDC of commission = 2 USD  ->  2 ARTHA
 *      WETH vault => 1e19  -> 2 USD of WETH commission      -> 20 ARTHA
 *  Same dollar, different reward -- the knob that makes thin/strategic vaults worth
 *  referring into. The oracle returns USD in 8dp, so a $3,000 WETH price is 3000e8.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE GLOBAL ARTHA CAP IS A HARD CEILING, AND IT PAYS PARTIAL
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  MAX_ARTHA (10,000,000e18) is the programme's entire lifetime budget. When a
 *  credit would cross it we grant EXACTLY the remainder and book that -- never the
 *  full ask, never zero:
 *
 *      minted = 9,999,999e18,  request = 5e18
 *        -> remaining = 1e18 -> grant 1e18, totalArthaMinted = MAX_ARTHA. Done.
 *
 *  Granting the full ask would let the last settler mint past the cap and leave the
 *  contract insolvent against `totalEarnedArtha`. Granting zero would silently burn
 *  a real, earned claim at the boundary. Partial is the only honest answer, and it
 *  is why `_creditArtha` returns the GRANTED amount and every caller books THAT --
 *  the books track what was actually credited, so the solvency check in rescue()
 *  stays exact right up to the final wei.
 *
 *  Crossing the cap NEVER reverts a withdraw. The base-token commission is a real
 *  contractual obligation; the ARTHA bonus is a budgeted incentive. A depleted
 *  budget must not brick the vault's withdraw path -- so ARTHA simply goes to zero
 *  and base keeps flowing.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   INTEGRATION
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Inside the vault's withdraw path, once the performance fee is known:
 *
 *      (, uint256 ownerNet, uint256 discount, , ,) =
 *          referralVault.getInfo(address(this), trader, perfFee);
 *
 *      if (ownerNet + discount != 0) {
 *          base.forceApprove(address(referralVault), ownerNet + discount);
 *          referralVault.settlePerformanceFee(address(this), trader, perfFee);
 *      }
 *      // the vault retains `protocolAmount` = perfFee - ownerGross.
 *
 *  settlePerformanceFee PULLS `ownerNet + discount` via transferFrom and forwards
 *  the discount to the trader in the same transaction. It recomputes the identical
 *  split internally through the SAME `_split` helper getInfo uses, so the view and
 *  the state change can never disagree -- there is one formula, in one place, and
 *  both paths call it.
 *
 *  FUNDING: this contract does NOT mint ARTHA. Fund it up front; claims pay from
 *  balance. Base tokens are pulled per-settlement, so no base float is held beyond
 *  what is owed.
 */
contract ReferralVault is ReferralSystem, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────── constants ──────────────────────────────────

    /// @notice Lifetime ARTHA budget for the entire referral programme.
    uint256 public constant MAX_ARTHA = 10_000_000e18;

    /// @dev Oracle prices are 8dp; ARTHA and the normalised base are 18dp.
    uint256 private constant PRICE_ONE = 1e8;
    uint256 private constant WAD = 1e18;

    IERC20 public immutable arthaToken;

    // ─────────────────────────────── types ──────────────────────────────────────

    /// @notice Config + lifetime books for one registered vault.
    struct VaultData {
        bool registered;             // if not active set to false again, and the vault is ignored
        address baseAsset;           // the vault's single base token
        uint256 scale;               // 10^(18 - decimals); raw -> 18dp
        uint256 arthaRatio;          // ARTHA (18dp) per 1 USD of commission
        uint256 totalCommissionBase; // lifetime base paid as referral commission (gross)
        uint256 totalDiscountBase;   // lifetime base rebated to traders
        uint256 totalProtocolBase;   // lifetime base retained by the protocol
        uint256 totalArthaEarned;    // lifetime ARTHA credited from this vault
    }

    /// @notice Per (code, vault) earnings ledger for the code OWNER.
    struct Earning {
        uint256 totalEarnedBase;  // lifetime base commission, net of discount
        uint256 claimedBase;      // lifetime base claimed
        uint256 totalEarnedArtha; // lifetime ARTHA credited
        uint256 claimedArtha;     // lifetime ARTHA claimed
    }

    /// @notice Per (code, vault) trader-side rebate ledger.
    struct UserData {
        uint256 totalDiscountBase; // lifetime base rebated to traders under this code
        uint256 totalVolumeBase;   // lifetime gross commission generated under this code
    }

    /**
     * @notice One priced performance fee. Carried in MEMORY, not on the stack.
     * @dev    The split has five outputs plus the resolved code, and settlement
     *         needs all six alive at once alongside the token handles and storage
     *         pointers -- which overflows the EVM's 16-slot reachable stack. Bundling
     *         them into one memory struct is a structural fix, so the contract
     *         compiles WITHOUT `--via-ir` and integrators are not forced onto it.
     */
    struct Split {
        uint64 code;             // resolved active code (0 => unreferred)
        uint256 ownerGross;      // referrer's cut of the fee, BEFORE discount
        uint256 ownerNet;        // what the referrer banks (gross - discount)
        uint256 discountAmount;  // rebated to the trader
        uint256 protocolAmount;  // retained by the vault (fee - ownerGross)
        uint256 arthaAmount;     // ARTHA priced on ownerGross, capped by budget
    }

    // ─────────────────────────────── events ─────────────────────────────────────

    event VaultRegistered(address indexed vault, address indexed baseAsset, uint256 arthaRatio);
    event ArthaRatioUpdated(address indexed vault, uint256 oldRatio, uint256 newRatio);
    event TierRewardRatioUpdated(address indexed vault, uint8 indexed tier, uint256 oldRatio, uint256 newRatio);
    event OracleUpdated(address oldOracle, address newOracle);
    event CommissionSettled(
        address indexed vault,
        uint64 indexed code,
        address indexed trader,
        uint256 performanceFee,
        uint256 ownerGross,
        uint256 ownerNet,
        uint256 discountAmount,
        uint256 protocolAmount,
        uint256 arthaAmount
    );
    event BaseClaimed(address indexed vault, uint64 indexed code, address indexed to, uint256 amount);
    event ArthaClaimed(address indexed vault, uint64 indexed code, address indexed to, uint256 amount);
    event ArthaCapReached(uint256 requested, uint256 granted, uint256 totalMinted);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ─────────────────────────────── storage ────────────────────────────────────

    IOracle public oracle;

    /// @notice Lifetime ARTHA credited across all vaults. Never exceeds MAX_ARTHA.
    uint256 public totalArthaMinted;

    /// @notice Lifetime base commission credited (net of discount), all vaults.
    uint256 public totalEarnedBase;
    /// @notice Lifetime base commission claimed, all vaults.
    uint256 public totalClaimedBase;
    /// @notice Lifetime ARTHA claimed, all vaults.
    uint256 public totalClaimedArtha;

    /// @notice vault => config + lifetime books.
    mapping(address => VaultData) private _vaultData;

    /// @notice vault => tier => the referrer's share of the performance fee.
    ///         1_000 = 1%, 100_000 = 100%. Set per vault: a deep, high-margin vault
    ///         can afford a bigger profit share than a thin one.
    mapping(address => mapping(uint8 => uint256)) public tierRewardRatio;

    /// @notice vault => code => the owner's earnings ledger.
    mapping(address => mapping(uint64 => Earning)) private _earning;

    /// @notice vault => code => the trader-side rebate ledger.
    mapping(address => mapping(uint64 => UserData)) private _userData;

    /// @notice vault => lifetime base claimed out of that vault's book. Tracked
    ///         incrementally so rescue() can bound itself without walking every code.
    mapping(address => uint256) public vaultClaimedBase;

    // ---- per-code footprint (bounds claimAll / deactivateCode) ----
    mapping(uint64 => address[]) public codeVaults;
    mapping(uint64 => mapping(address => bool)) public codeHasVault;

    // ---- registered vault set ----
    address[] public registeredVaults;

    constructor(address _artha, address _oracle, address _admin) ReferralSystem(_admin) {
        require(_artha != address(0), "INVALID_ARTHA");
        require(_oracle != address(0), "INVALID_ORACLE");
        arthaToken = IERC20(_artha);
        oracle = IOracle(_oracle);
    }

    function artha() external view returns (address) {
        return address(arthaToken);
    }

    // ═══════════════════════════ the split, in one place ════════════════════════

    /**
     * @dev THE single source of truth for the commission math -- code resolution
     *      included. Both getInfo() (view) and settlePerformanceFee() (state) route
     *      through here and do NOTHING else, so a divergence between what the vault
     *      is quoted and what it is charged is impossible.
     *
     *  Ordering matters and is deliberate:
     *    1. resolve the trader's ACTIVE code (dead code => unreferred).
     *    2. ownerGross from the (vault, tier) ratio.
     *    3. protocol = fee - ownerGross  <- SUBTRACTION. Absorbs all rounding dust,
     *       guaranteeing ownerGross + protocol == fee to the wei.
     *    4. discount carved out of ownerGross (the OWNER's money, not the protocol's).
     *    5. ARTHA priced on ownerGross (see the contract comment: never on the net).
     *
     *  Every early-out returns the SAME shape: the protocol keeps the whole fee and
     *  the referral programme takes nothing. `s.code == 0 || s.ownerGross == 0` is
     *  the caller's "unreferred" signal.
     */
    function _split(address _vault, address _trader, uint256 _fee)
        internal
        view
        returns (Split memory s)
    {
        s.protocolAmount = _fee; // the default in every early-out below

        if (!_vaultData[_vault].registered || _fee == 0) return s;

        uint64 code = activeTraderCode(_trader);
        if (code == uint64(0)) return s;

        // Defense-in-depth: the registry blocks binding your OWN code, but the admin
        // could transfer a code TO someone who had already bound it as a trader.
        // Re-check at settlement so a code can never pay its own owner.
        if (codeOwner[code] == _trader) return s;

        uint256 ratio = tierRewardRatio[_vault][codeTier[code]];
        if (ratio == 0) return s; // vault never opened this tier -> no commission

        s.code = code;
        s.ownerGross = (_fee * ratio) / RATIO_ONE;  // ratio is capped less than max always
        s.protocolAmount = _fee - s.ownerGross;

        uint32 disc = codeDiscount[code];
        s.discountAmount = disc == 0 ? 0 : (s.ownerGross * disc) / RATIO_ONE;
        s.ownerNet = s.ownerGross - s.discountAmount;

        s.arthaAmount = _quoteArtha(_vault, s.ownerGross);
    }

    /**
     * @dev Convert a GROSS base commission into ARTHA, clamped to what is left of
     *      the global budget.
     *
     *      raw -> norm18 (x scale) -> usd18 (x price / 1e8) -> artha (x ratio / 1e18)
     */
    function _quoteArtha(address _vault, uint256 _grossRaw) internal view returns (uint256) {
        if (_grossRaw == 0) return 0;

        VaultData storage v = _vaultData[_vault];
        uint256 ratio = v.arthaRatio;
        if (ratio == 0) return 0;

        uint256 remaining = MAX_ARTHA - totalArthaMinted;
        if (remaining == 0) return 0;

        uint256 price = oracle.getPrice(v.baseAsset); // 8dp USD
        if (price == 0) return 0;

        uint256 norm18 = _grossRaw * v.scale;          // 18dp base
        uint256 usd18 = (norm18 * price) / PRICE_ONE;  // 18dp USD
        uint256 amount = (usd18 * ratio) / WAD;        // 18dp ARTHA

        // Partial-fill at the cap -- never over, never silently zero.
        return amount > remaining ? remaining : amount;
    }

    /**
     * @dev Credit ARTHA under the global cap and return what was ACTUALLY granted.
     *      Callers MUST book the return value, not their request: the books have to
     *      mirror reality for rescue()'s solvency check to stay exact at the boundary.
     */
    function _creditArtha(address _vault, uint64 _code, uint256 _requested)
        internal
        returns (uint256 granted)
    {
        if (_requested == 0) return 0;

        uint256 remaining = MAX_ARTHA - totalArthaMinted;
        if (remaining == 0) return 0;

        granted = _requested > remaining ? remaining : _requested;

        totalArthaMinted += granted;
        _earning[_vault][_code].totalEarnedArtha += granted;
        _vaultData[_vault].totalArthaEarned += granted;

        if (granted < _requested) {
            emit ArthaCapReached(_requested, granted, totalArthaMinted);
        }
    }

    /// @dev Record that `code` has a book in `vault`, so claimAll/deactivate can
    ///      enumerate it without an unbounded scan of the global vault set.
    function _touchCodeVault(uint64 _code, address _vault) internal {
        if (!codeHasVault[_code][_vault]) {
            codeHasVault[_code][_vault] = true;
            codeVaults[_code].push(_vault);
        }
    }

    // ═══════════════════════════ vault integration ══════════════════════════════

    /**
     * @notice Price a performance fee split WITHOUT mutating state. Call this from
     *         the vault's withdraw path to learn how much to approve, and how much
     *         of the fee to keep for the treasury.
     * @param  vault           The vault paying the fee (its own address).
     * @param  trader          The position owner the fee was charged to.
     * @param  performanceFee  The full performance fee, raw base-token units.
     * @return ownerGross      Referrer's commission BEFORE the trader discount.
     * @return ownerNet        What the referrer actually banks (gross - discount).
     * @return discountAmount  Base rebated to the trader.
     * @return protocolAmount  Base the vault retains (performanceFee - ownerGross).
     * @return arthaAmount     ARTHA credited to the referrer, priced on ownerGross.
     * @return code            The trader's active code (0 => no referral at all).
     */
    function getInfo(address vault, address trader, uint256 performanceFee)
        external
        view
        returns (
            uint256 ownerGross,
            uint256 ownerNet,
            uint256 discountAmount,
            uint256 protocolAmount,
            uint256 arthaAmount,
            uint64 code
        )
    {
        Split memory s = _split(vault, trader, performanceFee);
        return (s.ownerGross, s.ownerNet, s.discountAmount, s.protocolAmount, s.arthaAmount, s.code);
    }

    /**
     * @notice Execute the split. Pulls `ownerNet + discountAmount` of base from the
     *         calling vault (which must have approved at least that much) and
     *         forwards `discountAmount` to the trader in the same transaction.
     * @dev    onlyCaller(vault): msg.sender MUST equal `vault`.
     */
    function settlePerformanceFee(address vault, address trader, uint256 performanceFee)
        external
        nonReentrant
        whenNotPaused
        onlyCaller(vault)
        returns (
            uint256 ownerGross,
            uint256 ownerNet,
            uint256 discountAmount,
            uint256 protocolAmount,
            uint256 arthaAmount
        )
    {
        require(_vaultData[vault].registered, "NOT_REGISTERED");

        Split memory s = _split(vault, trader, performanceFee);

        // Unreferred (or dead code, or tier not opened): nothing moves, nothing is
        // pulled, and the vault keeps the entire fee.
        if (s.ownerGross == 0) {
            return (0, 0, 0, performanceFee, 0);
        }

        _bookCommission(vault, s);

        emit CommissionSettled(
            vault,
            s.code,
            trader,
            performanceFee,
            s.ownerGross,
            s.ownerNet,
            s.discountAmount,
            s.protocolAmount,
            s.arthaAmount
        );

        return (s.ownerGross, s.ownerNet, s.discountAmount, s.protocolAmount, s.arthaAmount);
    }

    /**
     * @dev Write the books for one priced split and pull ONLY what stays here.
     *
     *  ┌──────────────────────────────────────────────────────────────────────┐
     *  │  THE DISCOUNT NEVER ENTERS THIS CONTRACT.                            │
     *  │                                                                      │
     *  │  The rebate is the trader's money, the vault already holds the base, │
     *  │  and the vault is paying that same trader out on this very call. So  │
     *  │  the vault nets it into the trader's payout directly:                │
     *  │                                                                      │
     *  │      payout = principal + profit - protocolAmount - ownerNet         │
     *  │                                                                      │
     *  │  which is algebraically identical to paying the trader the discount  │
     *  │  separately -- one transfer instead of two, and no float parked here │
     *  │  that was never ours. We pull ONLY `ownerNet`: the referrer's        │
     *  │  claimable balance is the only thing this contract must custody.     │
     *  │                                                                      │
     *  │  `totalDiscountBase` is still booked in full. It is an accounting    │
     *  │  fact about what the code owner gave up, not a claim on any balance  │
     *  │  here -- which is exactly why _outstandingBase subtracts it.         │
     *  └──────────────────────────────────────────────────────────────────────┘
     */
    function _bookCommission(address vault, Split memory s) internal {
        VaultData storage v = _vaultData[vault];

        // Pull ONLY the referrer's net. The discount stays in the vault and is
        // netted into the trader's payout there.
        if (s.ownerNet != 0) {
            IERC20(v.baseAsset).safeTransferFrom(vault, address(this), s.ownerNet);
        }

        Earning storage e = _earning[vault][s.code];
        e.totalEarnedBase += s.ownerNet;

        UserData storage u = _userData[vault][s.code];
        u.totalVolumeBase += s.ownerGross;

        v.totalCommissionBase += s.ownerGross;
        v.totalProtocolBase += s.protocolAmount;
        totalEarnedBase += s.ownerNet;

        if (s.discountAmount != 0) {
            u.totalDiscountBase += s.discountAmount;
            v.totalDiscountBase += s.discountAmount;
        }

        // ── ARTHA leg ── book what was GRANTED, not what was quoted.
        s.arthaAmount = _creditArtha(vault, s.code, s.arthaAmount);

        _touchCodeVault(s.code, vault);
    }

    // ═════════════════════════════ claiming ═════════════════════════════════════

    function claimBase(address vault, uint64 code, address to, uint256 amount)
        public
        nonReentrant
        whenNotPaused
    {
        require(_vaultData[vault].registered, "NOT_REGISTERED");
        require(to != address(0) && amount != 0, "INVALID_PARAMS");
        require(codeOwner[code] == msg.sender, "NOT_CODE_OWNER");

        Earning storage e = _earning[vault][code];
        uint256 avail = e.totalEarnedBase - e.claimedBase;
        require(avail >= amount, "INSUFFICIENT_BASE");

        e.claimedBase += amount;
        vaultClaimedBase[vault] += amount;
        totalClaimedBase += amount;

        IERC20(_vaultData[vault].baseAsset).safeTransfer(to, amount);
        emit BaseClaimed(vault, code, to, amount);
    }

    function claimArtha(address vault, uint64 code, address to, uint256 amount)
        public
        nonReentrant
        whenNotPaused
    {
        require(_vaultData[vault].registered, "NOT_REGISTERED");
        require(to != address(0) && amount != 0, "INVALID_PARAMS");
        require(codeOwner[code] == msg.sender, "NOT_CODE_OWNER");

        Earning storage e = _earning[vault][code];
        uint256 avail = e.totalEarnedArtha - e.claimedArtha;
        require(avail >= amount, "INSUFFICIENT_ARTHA");

        e.claimedArtha += amount;
        totalClaimedArtha += amount;

        arthaToken.safeTransfer(to, amount);
        emit ArthaClaimed(vault, code, to, amount);
    }

    function claimAll(uint64 code, address to) external {
        require(codeOwner[code] == msg.sender, "NOT_CODE_OWNER");
        address[] storage list = codeVaults[code];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            address v = list[i];
            Earning storage e = _earning[v][code];
            uint256 b = e.totalEarnedBase - e.claimedBase;
            if (b != 0) claimBase(v, code, to, b);
            uint256 a = e.totalEarnedArtha - e.claimedArtha;
            if (a != 0) claimArtha(v, code, to, a);
        }
    }

    /**
     * @dev Both legs must be empty in EVERY vault the code touched. Deactivation
     *      clears ownership, and `claimBase`/`claimArtha` gate on
     *      `codeOwner[code] == msg.sender` -- so a balance left behind at this point
     *      is unreachable forever, by anyone. Hence the hard requires rather than a
     *      convenience auto-claim: the owner must consciously take his money out
     *      first, and if he cannot, the code stays alive.
     */
    function deactivateCode(uint64 code) external {
        address[] storage list = codeVaults[code];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            Earning storage e = _earning[list[i]][code];
            require(e.totalEarnedBase == e.claimedBase, "UNCLAIMED_BASE");
            require(e.totalEarnedArtha == e.claimedArtha, "UNCLAIMED_ARTHA");
        }
        _deactivateCode(code);
    }

    // ═════════════════════════════ admin ════════════════════════════════════════

    function registerVault(address vault, address baseAsset, uint8 decimals, uint256 arthaRatio_)
        external
        onlyReferralVaultManager
    {
        require(vault != address(0) && baseAsset != address(0), "INVALID_PARAMS");
        require(!_vaultData[vault].registered, "ALREADY_REGISTERED");
        require(decimals >= 6 && decimals <= 18, "BAD_DECIMALS");

        _vaultData[vault] = VaultData({
            registered: true,
            baseAsset: baseAsset,
            scale: 10 ** (18 - decimals),
            arthaRatio: arthaRatio_,
            totalCommissionBase: 0,
            totalDiscountBase: 0,
            totalProtocolBase: 0,
            totalArthaEarned: 0
        });
        registeredVaults.push(vault);

        emit VaultRegistered(vault, baseAsset, arthaRatio_);
    }

    function setArthaRatio(address vault, uint256 arthaRatio_) external onlyReferralVaultManager {
        require(_vaultData[vault].registered, "NOT_REGISTERED");
        uint256 old = _vaultData[vault].arthaRatio;
        _vaultData[vault].arthaRatio = arthaRatio_;
        emit ArthaRatioUpdated(vault, old, arthaRatio_);
    }

    /**
     * @dev The tier ladder for one vault. Higher tier => bigger slice of the
     *      performance fee. Capped at RATIO_ONE so the referrer can never be owed
     *      more than 100% of the fee (which would make `protocol = fee - gross`
     *      underflow, and would mean paying out money the vault never charged).
     */
    function setTierRewardRatio(address vault, uint8 tier, uint256 ratio)
        external
        onlyReferralVaultManager
    {
        require(_vaultData[vault].registered, "NOT_REGISTERED");
        require(tier != 0 && tier <= MAX_TIERS, "INVALID_TIER");
        require(ratio <= RATIO_ONE, "RATIO_GT_ONE");

        uint256 old = tierRewardRatio[vault][tier];
        tierRewardRatio[vault][tier] = ratio;
        emit TierRewardRatioUpdated(vault, tier, old, ratio);
    }

    /**
     * @notice Promote/demote a code. ADMIN ONLY.
     * @dev    No settlement dance is needed. Commission is priced per-fee at call
     *         time and banked immediately, so there is no accrued position sitting
     *         at the old rate to bank first -- the new tier simply applies from the
     *         next performance fee onward. (The old time-accrual design DID need
     *         this, which is why setCodeTier there had to walk every vault.)
     */
    function setCodeTier(uint64 code, uint8 newTier) external onlyReferralVaultManager {
        _setCodeTier(code, newTier);
    }

    function setOracle(address newOracle) external onlyReferralVaultManager {
        require(newOracle != address(0), "INVALID_ORACLE");
        emit OracleUpdated(address(oracle), newOracle);
        oracle = IOracle(newOracle);
    }

    /**
     * @dev Sweeping ARTHA is bounded by what is OWED to code owners, and sweeping a
     *      registered vault's base token is bounded by unclaimed commission. A rescue
     *      must never be able to take money that is already someone's.
     */
    function rescue(address token, address to, uint256 amount) external onlyReferralVaultManager {
        require(to != address(0) && amount != 0, "INVALID_PARAMS");

        uint256 owed;
        if (token == address(arthaToken)) {
            owed = totalArthaMinted - totalClaimedArtha;
        } else {
            owed = _outstandingBase(token);
        }

        if (owed != 0) {
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

    function vaultData(address vault) external view returns (VaultData memory) {
        return _vaultData[vault];
    }

    function earningOf(address vault, uint64 code) external view returns (Earning memory) {
        return _earning[vault][code];
    }

    function userDataOf(address vault, uint64 code) external view returns (UserData memory) {
        return _userData[vault][code];
    }

    /// @notice Unclaimed base + ARTHA for a code in one vault.
    function pendingOf(address vault, uint64 code)
        public
        view
        returns (uint256 pendingBase, uint256 pendingArtha)
    {
        Earning storage e = _earning[vault][code];
        pendingBase = e.totalEarnedBase - e.claimedBase;
        pendingArtha = e.totalEarnedArtha - e.claimedArtha;
    }

    /// @notice Unclaimed ARTHA for a code across every vault it earned in, plus the
    ///         per-vault base breakdown (base cannot be summed -- different tokens).
    function pendingAll(uint64 code)
        external
        view
        returns (address[] memory vaults, uint256[] memory baseAmounts, uint256 totalPendingArtha)
    {
        address[] storage list = codeVaults[code];
        uint256 n = list.length;
        vaults = new address[](n);
        baseAmounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            vaults[i] = list[i];
            (uint256 b, uint256 a) = pendingOf(list[i], code);
            baseAmounts[i] = b;
            totalPendingArtha += a;
        }
    }

    /**
     * @notice Everything the front-end needs about a CODE, in one call.
     * @return owner_        Current owner (address(0) => deactivated).
     * @return tier          Current tier id.
     * @return discountBps   The owner's rebate setting, 1_000 = 1%.
     * @return active        Whether the code can still be used.
     * @return vaultCount    How many vaults this code has earned in.
     * @return pendingArtha  Unclaimed ARTHA across all of them.
     */
    function codeInfo(uint64 code)
        external
        view
        returns (
            address owner_,
            uint8 tier,
            uint32 discountBps,
            bool active,
            uint256 vaultCount,
            uint256 pendingArtha
        )
    {
        owner_ = codeOwner[code];
        tier = codeTier[code];
        discountBps = codeDiscount[code];
        active = isCodeActive(code);

        address[] storage list = codeVaults[code];
        vaultCount = list.length;
        for (uint256 i = 0; i < vaultCount; i++) {
            (, uint256 a) = pendingOf(list[i], code);
            pendingArtha += a;
        }
    }

    /**
     * @notice Everything the front-end needs about a TRADER, in one call.
     * @return code          The code they bound (may be dead -- see `active`).
     * @return referrer      Who owns it now.
     * @return tier          Its tier.
     * @return discountBps   The rebate they receive on the referrer's commission.
     * @return active        False => they are treated as unreferred and may rebind.
     */
    function traderInfo(address trader)
        external
        view
        returns (uint64 code, address referrer, uint8 tier, uint32 discountBps, bool active)
    {
        code = traderCode[trader];
        referrer = codeOwner[code];
        tier = codeTier[code];
        discountBps = codeDiscount[code];
        active = isCodeActive(code);
    }

    /// @notice Lifetime base rebated to traders under `code` in `vault`, and the
    ///         gross commission that rebate was carved out of.
    function userInfo(address vault, uint64 code)
        external
        view
        returns (uint256 totalDiscountBase, uint256 totalVolumeBase)
    {
        UserData storage u = _userData[vault][code];
        return (u.totalDiscountBase, u.totalVolumeBase);
    }

    /**
     * @notice A vault's full referral books.
     * @return baseAsset          The vault's base token.
     * @return arthaRatio_        ARTHA per 1 USD of commission, 18dp.
     * @return commissionBase     Lifetime gross commission paid under this vault.
     * @return discountBase       Lifetime base rebated to traders.
     * @return protocolBase       Lifetime base retained by the protocol.
     * @return arthaEarned        Lifetime ARTHA credited from this vault.
     */
    function vaultBooks(address vault)
        external
        view
        returns (
            address baseAsset,
            uint256 arthaRatio_,
            uint256 commissionBase,
            uint256 discountBase,
            uint256 protocolBase,
            uint256 arthaEarned
        )
    {
        VaultData storage v = _vaultData[vault];
        return (
            v.baseAsset,
            v.arthaRatio,
            v.totalCommissionBase,
            v.totalDiscountBase,
            v.totalProtocolBase,
            v.totalArthaEarned
        );
    }

    /// @notice Programme-wide totals. `outstandingArtha` is what this contract still
    ///         owes code owners; keep its ARTHA balance at or above it.
    function globalBooks()
        external
        view
        returns (
            uint256 arthaMinted,
            uint256 arthaClaimed,
            uint256 outstandingArtha,
            uint256 arthaLeftInBudget,
            uint256 baseEarned,
            uint256 baseClaimed
        )
    {
        return (
            totalArthaMinted,
            totalClaimedArtha,
            totalArthaMinted - totalClaimedArtha,
            MAX_ARTHA - totalArthaMinted,
            totalEarnedBase,
            totalClaimedBase
        );
    }

    function codeVaultsCount(uint64 code) external view returns (uint256) {
        return codeVaults[code].length;
    }

    function registeredVaultsCount() external view returns (uint256) {
        return registeredVaults.length;
    }

    /// @notice All vaults a code has earned in.
    function codeVaultList(uint64 code) external view returns (address[] memory) {
        return codeVaults[code];
    }

    // ─────────────────────────────── internal ───────────────────────────────────

    /**
     * @dev Unclaimed commission denominated in `token`, summed across every
     *      registered vault that uses it as its base asset. Bounds rescue().
     *
     *      net earned for a vault == gross commission - what was rebated to traders
     *      (the rebate left the building at settlement time and was never owed to
     *      the code owner). Subtract what has already been claimed to get the debt.
     *
     *      O(#vaults), view-only, admin path only.
     */
    function _outstandingBase(address token) internal view returns (uint256 owed) {
        uint256 n = registeredVaults.length;
        for (uint256 i = 0; i < n; i++) {
            address vaultAddr = registeredVaults[i];
            VaultData storage v = _vaultData[vaultAddr];
            if (v.baseAsset != token) continue;

            uint256 netEarned = v.totalCommissionBase - v.totalDiscountBase;
            uint256 claimed = vaultClaimedBase[vaultAddr];
            if (netEarned > claimed) owed += netEarned - claimed;
        }
    }
}
