// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
                              ReferralFacet
//////////////////////////////////////////////////////////////////////////*/
/**
 * @title  ReferralFacet
 * @notice The referral logic for the Artha Diamond. It is a *facet* — one slice
 *         of code that runs inside the main Diamond contract. It pays rewards in
 *         ARTHA tokens, sized by (deposit amount × pool/risk multiplier × tier),
 *         and lets each code owner choose how much of that reward is handed back
 *         to the investor as a "discount" vs kept by the owner.
 *
 * @dev    READ THIS FIRST — how a facet differs from a normal contract:
 *
 *  1) NO CONSTRUCTOR FOR STATE. A facet's code is reached by the Diamond through
 *     `delegatecall`, which means the facet runs *using the Diamond's storage*,
 *     not its own. A constructor would write to the facet's own (unused) storage,
 *     so we never put state in a constructor. All configuration (tier rebates,
 *     pool multipliers, the referral budget) is set AFTER deployment by
 *     governance, through the setter functions below.
 *
 *  2) SHARED STORAGE (AppStorage). Every facet inherits `Modifiers`, which
 *     declares `AppStorage internal s;` as its first variable. Because of that,
 *     every facet sees the *same* storage layout starting at slot 0. So when this
 *     facet writes `s.codeOwner[code] = ...`, the PoolFacet, FeeFacet, etc. all
 *     see the same value. This is what lets the pieces work together while each
 *     stays independently upgradeable.
 *
 *  3) UNITS — "PPM" (parts per million). Percentages are stored as integers where
 *     1,000,000 == 100%. So 20% is 200,000 and 5% is 50,000. Solidity has no
 *     decimals, so this is how we represent fractions. (Same convention as your
 *     original ReferralSystem: `BASIS_POINTS = 100_0000` = 1,000,000.)
 *
 *  4) TOKEN DECIMALS. Deposits are in USDC, which has 6 decimals (1 USDC = 1e6).
 *     ARTHA has 18 decimals (1 ARTHA = 1e18). The reward math therefore scales the
 *     USDC-sized number up by 1e12 to land in ARTHA units. See `_computeReward`.
 *
 *  ----------------------------------------------------------------------------
 *  REWARD FORMULA (worked example, so the math is concrete):
 *
 *     Investor deposits 1,000 USDC into the HIGH pool.
 *     Pool multiplier (poolReferralMultPPM[HIGH]) = 50,000 PPM  = 5%
 *     Code is on tier 2,  tierRebates[2]          = 300,000 PPM = 30%
 *
 *     R_ref = 1,000 × 5% × 30% = 15 ARTHA      (the total referral reward)
 *
 *     Code owner set a discountShare of 200,000 PPM = 20%, meaning "give 20% of
 *     the reward back to the investor, I keep 80%":
 *
 *        investorReturn = 15 × 20% = 3  ARTHA   -> goes to the investor
 *        ownerReward    = 15 − 3   = 12 ARTHA   -> goes to the code owner
 *  ----------------------------------------------------------------------------
 *
 *  AppStorage fields this facet uses (these live in the shared AppStorage struct
 *  defined in LibAppStorage.sol — listed here so you know exactly what it touches):
 *
 *     mapping(uint16  => uint32)  tierRebates;          // tierId   => rebate (PPM)
 *     mapping(bytes32 => address) codeOwner;            // code     => owner
 *     mapping(bytes32 => uint16)  codeTier;             // code     => tierId
 *     mapping(bytes32 => uint32)  codeDiscountShare;    // code     => share to investor (PPM)
 *     mapping(address => bytes32) ownerToCode;          // owner    => their one code
 *     mapping(address => bytes32) traderToCode;         // investor => the code they use
 *     mapping(address => uint256) referralVolume;       // owner    => total USDC referred (drives tier promotion)
 *     mapping(address => uint256) referrerArthaEarned;  // owner    => lifetime ARTHA earned (analytics)
 *     mapping(address => uint256) pendingReferralArtha; // anyone   => claimable ARTHA balance   [APPENDED FIELD]
 *     mapping(uint256 => uint32)  poolReferralMultPPM;  // poolId   => pool/risk multiplier (PPM)
 *     uint256 referralBudgetCap;                        // max ARTHA ever payable via referrals    [APPENDED FIELD]
 *     uint256 referralEmitted;                          // ARTHA paid via referrals so far          [APPENDED FIELD]
 *     address artha;                                    // the ARTHA token (Diamond is its minter)
 */

import {Modifiers} from "../libraries/LibAppStorage.sol";
// Minimal interface for the ARTHA token. The Diamond must hold the minter role.
//   interface IArthaToken { function mint(address to, uint256 amount) external; }
import {IArthaToken} from "../interfaces/IArthaToken.sol";

contract ReferralFacet is Modifiers {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev 1,000,000 == 100%. All percentage-like values are in these units.
    uint32 internal constant PPM = 1_000_000;

    /// @dev Token decimals. USDC = 6, ARTHA = 18. If your chain's USDC uses a
    ///      different number of decimals, change USDC_DECIMALS accordingly.
    uint256 internal constant USDC_DECIMALS = 6;
    uint256 internal constant ARTHA_DECIMALS = 18;

    /// @dev Multiplier that converts a USDC-sized amount into ARTHA units.
    ///      18 − 6 = 12, so this is 1e12.
    uint256 internal constant ARTHA_SCALE = 10 ** (ARTHA_DECIMALS - USDC_DECIMALS);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    // Code lifecycle
    event CodeCreated(address indexed owner, bytes32 indexed code);
    event DiscountShareUpdated(address indexed owner, uint32 share);
    event CodeTransferred(bytes32 indexed code, address indexed oldOwner, address indexed newOwner);
    event CodeDeactivated(address indexed owner, bytes32 indexed code);

    // Investor (trader) linking
    event TraderCodeSet(address indexed trader, bytes32 indexed code);

    // Governance configuration
    event TierRebateUpdated(uint16 indexed tierId, uint32 totalRebatePPM);
    event ReferrerTierUpdated(address indexed referrer, uint16 oldTierId, uint16 newTierId);
    event PoolReferralMultUpdated(uint256 indexed poolId, uint32 multPPM);
    event ReferralBudgetUpdated(uint256 newCap);

    // Reward flow
    event ReferralAccrued(
        uint256 indexed poolId,
        address indexed investor,
        address indexed owner,
        bytes32 code,
        uint256 depositAmount,
        uint256 totalReward,
        uint256 investorReturn,
        uint256 ownerReward
    );
    event ReferralClaimed(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Restricts a function so ONLY the Diamond itself can call it.
     *
     *      When another facet (e.g. PoolFacet) calls this facet via
     *      `IReferralFacet(address(this)).accrueReferral(...)`, that is an
     *      external call whose `msg.sender` is the Diamond's address — i.e.
     *      `address(this)` from inside this facet. A random user calling
     *      `accrueReferral` directly would have their own address as msg.sender
     *      and would be rejected. This is what stops anyone from minting
     *      themselves free referral rewards.
     */
    modifier onlyInternal() {
        require(msg.sender == address(this), "REF: internal only");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          USER (REFERRER) FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create your own referral code so you can earn ARTHA when people
     *         invest using it.
     * @param  code           The code you want to own (e.g. keccak/bytes32 of a string).
     * @param  discountShare  How much of each reward to hand back to the investor,
     *                        in PPM (0 = keep everything, 200_000 = give 20% back).
     *
     * Checks:
     *  - code must be non-empty and not already owned by someone else
     *  - you must not already own a code (one code per owner keeps accounting clean)
     *  - discountShare cannot exceed 100%
     *  - tier 1 must be configured by governance first (new codes start on tier 1)
     */
    function registerCode(bytes32 code, uint32 discountShare) external {
        require(code != bytes32(0), "REF: invalid code");
        require(s.codeOwner[code] == address(0), "REF: code exists");
        require(s.ownerToCode[msg.sender] == bytes32(0), "REF: already has code");
        require(discountShare <= PPM, "REF: invalid share");
        require(s.tierRebates[1] > 0, "REF: default tier not set");

        s.codeOwner[code] = msg.sender;
        s.codeTier[code] = 1; // every new code starts at the default tier
        s.codeDiscountShare[code] = discountShare;
        s.ownerToCode[msg.sender] = code;

        emit CodeCreated(msg.sender, code);
    }

    /**
     * @notice Change how much of the reward you give back to investors.
     *         Higher discountShare = more attractive to investors, less for you.
     * @param  share New investor share in PPM (≤ 1,000,000).
     */
    function setDiscountShare(uint32 share) external {
        require(share <= PPM, "REF: invalid share");
        bytes32 code = s.ownerToCode[msg.sender];
        require(code != bytes32(0), "REF: not a referrer");

        s.codeDiscountShare[code] = share;
        emit DiscountShareUpdated(msg.sender, share);
    }

    /**
     * @notice Hand your code (and its tier/earning power) to another address.
     * @param  code     The code you own.
     * @param  newOwner Who receives it.
     *
     * @dev We require `newOwner` does not already own a code. Your original
     *      contract overwrote `ownerToCode[newOwner]` unconditionally, which
     *      could orphan a code the new owner already had — this guard prevents that.
     */
    function transferCodeOwnership(bytes32 code, address newOwner) external {
        require(newOwner != address(0), "REF: invalid address");
        require(s.codeOwner[code] == msg.sender, "REF: not code owner");
        require(s.ownerToCode[newOwner] == bytes32(0), "REF: new owner has code");

        s.codeOwner[code] = newOwner;
        s.ownerToCode[msg.sender] = bytes32(0); // old owner no longer linked
        s.ownerToCode[newOwner] = code;         // new owner linked

        emit CodeTransferred(code, msg.sender, newOwner);
    }

    /*//////////////////////////////////////////////////////////////
                            INVESTOR FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice As an investor, attach a referral code to yourself. From then on,
     *         your deposits credit that code's owner (and may give you a discount).
     * @param  code An existing referral code.
     *
     * @dev This is optional — investors can also pass a code directly into
     *      PoolFacet.requestDeposit, which will record it here on first use.
     *      A trader may re-point to a different code later; rewards are always
     *      computed against whatever code is set at the moment of deposit.
     */
    function setTraderCode(bytes32 code) external {
        require(code != bytes32(0), "REF: invalid code");
        require(s.codeOwner[code] != address(0), "REF: code does not exist");

        s.traderToCode[msg.sender] = code;
        emit TraderCodeSet(msg.sender, code);
    }

    /*//////////////////////////////////////////////////////////////
                           GOVERNANCE FUNCTIONS
                 (onlyGovernance == the Timelock; see Module 16)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configure the rebate for a tier. Tier 1 is the default tier that
     *         every new code starts on, so it MUST be set before codes are useful.
     * @param  tierId     Tier number (start at 1).
     * @param  rebatePPM  Rebate in PPM (e.g. 200_000 = 20%, 300_000 = 30%).
     */
    function setTierRebate(uint16 tierId, uint32 rebatePPM) external onlyGovernance {
        require(rebatePPM != 0 && rebatePPM <= PPM, "REF: invalid rebate");
        s.tierRebates[tierId] = rebatePPM;
        emit TierRebateUpdated(tierId, rebatePPM);
    }

    /**
     * @notice Promote (or change) a referrer's tier. This is how a code that
     *         brings in a lot of volume gets bumped to a higher-earning tier.
     *         Governance reads `referralVolume[referrer]` off-chain to decide.
     * @param  referrer  The code owner to re-tier.
     * @param  newTierId The tier to move them to (must already be configured).
     */
    function setReferrerTier(address referrer, uint16 newTierId) external onlyGovernance {
        require(referrer != address(0), "REF: invalid referrer");
        bytes32 code = s.ownerToCode[referrer];
        require(code != bytes32(0), "REF: not a referrer");
        require(s.tierRebates[newTierId] > 0, "REF: tier not configured");

        uint16 oldTier = s.codeTier[code];
        s.codeTier[code] = newTierId;
        emit ReferrerTierUpdated(referrer, oldTier, newTierId);
    }

    /**
     * @notice Set the per-pool referral multiplier. This encodes the "risk/pool
     *         based" rate from your spec: a riskier pool can reward referrals more.
     * @param  poolId  0 = LOW, 1 = MEDIUM, 2 = HIGH.
     * @param  multPPM Multiplier in PPM (e.g. 50_000 = 5%).
     */
    function setPoolReferralMult(uint256 poolId, uint32 multPPM) external onlyGovernance {
        require(multPPM <= PPM, "REF: invalid mult");
        s.poolReferralMultPPM[poolId] = multPPM;
        emit PoolReferralMultUpdated(poolId, multPPM);
    }

    /**
     * @notice Set the maximum total ARTHA that can ever be paid out via referrals.
     *         This is a hard ceiling so referral rewards can't inflate ARTHA beyond
     *         the budget you allocated for them (protects the tokenomics).
     * @param  cap New cap in ARTHA (18 decimals). Must be ≥ what has already been paid.
     */
    function setReferralBudget(uint256 cap) external onlyGovernance {
        require(cap >= s.referralEmitted, "REF: below already emitted");
        s.referralBudgetCap = cap;
        emit ReferralBudgetUpdated(cap);
    }

    /**
     * @notice Disable a code (e.g. abuse, or an owner who exited the protocol).
     *         After this, the code earns nothing until re-registered.
     * @param  code The code to deactivate.
     *
     * @dev In your original this was an `onlyHandler` (vault) action. Here the
     *      "handler" is governance, since the Diamond is the vault.
     */
    function deactivateCode(bytes32 code) external onlyGovernance {
        require(code != bytes32(0), "REF: invalid code");
        address owner = s.codeOwner[code];
        require(owner != address(0), "REF: already deactivated");
        require(s.ownerToCode[owner] == code, "REF: owner mismatch");

        s.codeOwner[code] = address(0);
        s.ownerToCode[owner] = bytes32(0);
        emit CodeDeactivated(owner, code);
    }

    /*//////////////////////////////////////////////////////////////
                         REWARD ACCRUAL (INTERNAL)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Credit referral rewards for a deposit. Called by the deposit flow,
     *         NOT by users directly (see `onlyInternal`).
     * @param  poolId        Which pool the deposit went into.
     * @param  investor      The depositor.
     * @param  depositAmount The deposited USDC (raw units, 6 decimals).
     * @param  code          The code passed at deposit time (may be empty, in which
     *                       case we fall back to the investor's stored code).
     *
     * Integration: PoolFacet.requestDeposit calls
     *     IReferralFacet(address(this)).accrueReferral(poolId, msg.sender, amount, refCode);
     *
     * Behaviour: this NEVER reverts the deposit. If there is no valid code, or it
     * is a self-referral, or the budget is exhausted, it simply credits nothing.
     * Rewards accumulate as a *claimable balance* (gas-cheap) and are minted later
     * when the user calls `claimReferralRewards`.
     */
    function accrueReferral(
        uint256 poolId,
        address investor,
        uint256 depositAmount,
        bytes32 code
    ) external onlyInternal {
        // 1) Decide which code applies: the one passed in, else the stored one.
        bytes32 effCode = code != bytes32(0) ? code : s.traderToCode[investor];
        if (effCode == bytes32(0)) return; // no referral on this deposit — fine

        // 2) Convenience: if a code was passed and the investor has none stored,
        //    remember it for next time (only if it's a real, owned code).
        if (
            code != bytes32(0) &&
            s.traderToCode[investor] == bytes32(0) &&
            s.codeOwner[code] != address(0)
        ) {
            s.traderToCode[investor] = code;
            emit TraderCodeSet(investor, code);
        }

        // 3) Compute the reward and its split.
        (uint256 rRef, uint256 investorReturn, uint256 ownerReward, address owner) =
            _computeReward(poolId, effCode, depositAmount);

        if (owner == address(0) || rRef == 0) return; // deactivated code / zero reward
        if (owner == investor) return;                // SELF-REFERRAL: not allowed

        // 4) Enforce the global referral budget cap. If only part of the reward
        //    fits, scale the payout down proportionally so the split stays correct.
        uint256 remaining =
            s.referralBudgetCap > s.referralEmitted ? s.referralBudgetCap - s.referralEmitted : 0;
        if (remaining == 0) return; // budget exhausted
        if (rRef > remaining) {
            investorReturn = (investorReturn * remaining) / rRef;
            ownerReward = remaining - investorReturn;
            rRef = remaining;
        }

        // 5) Effects: record everything in shared storage.
        s.referralEmitted += rRef;                  // count against the budget
        s.referralVolume[owner] += depositAmount;   // for tier promotion decisions
        s.referrerArthaEarned[owner] += ownerReward; // lifetime analytics

        if (investorReturn > 0) s.pendingReferralArtha[investor] += investorReturn;
        if (ownerReward > 0) s.pendingReferralArtha[owner] += ownerReward;

        emit ReferralAccrued(
            poolId, investor, owner, effCode, depositAmount, rRef, investorReturn, ownerReward
        );
    }

    /**
     * @notice Claim all referral ARTHA you have earned (as investor, owner, or both).
     * @return amount The ARTHA minted to you.
     *
     * @dev Follows Checks-Effects-Interactions: we zero your balance BEFORE minting,
     *      so even if the token did something unexpected on mint, it couldn't be
     *      re-entered to drain twice. (ARTHA is our own standard token with no
     *      callback, but we code defensively regardless.)
     */
    function claimReferralRewards() external returns (uint256 amount) {
        amount = s.pendingReferralArtha[msg.sender];
        require(amount > 0, "REF: nothing to claim");

        s.pendingReferralArtha[msg.sender] = 0;        // effect first
        IArthaToken(s.artha).mint(msg.sender, amount); // interaction last

        emit ReferralClaimed(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL MATH HELPER
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The single source of truth for the reward math. Used by both the
     *      accrual path and the `calculateReferralRewards` view so they can never
     *      disagree.
     *
     *  R_ref (ARTHA, 18 dec)
     *      = depositAmount (USDC, 6 dec)
     *        × poolMult / PPM        (pool/risk factor)
     *        × tierRebate / PPM      (tier factor)
     *        × ARTHA_SCALE           (6 → 18 decimal conversion = 1e12)
     *
     *  Written as one integer expression with the division LAST to preserve
     *  precision. The values are tiny relative to 2^256, so there is no overflow:
     *  e.g. 1e9 (deposit) × 1e6 × 1e6 × 1e12 = 1e33 << 1.16e77.
     *
     *  Split:
     *      investorReturn = R_ref × discountShare / PPM
     *      ownerReward    = R_ref − investorReturn
     */
    function _computeReward(uint256 poolId, bytes32 code, uint256 depositAmount)
        internal
        view
        returns (uint256 rRef, uint256 investorReturn, uint256 ownerReward, address owner)
    {
        owner = s.codeOwner[code];
        if (owner == address(0)) return (0, 0, 0, address(0)); // no/deactivated code

        uint32 tierRebate = s.tierRebates[s.codeTier[code]];
        uint32 poolMult = s.poolReferralMultPPM[poolId];
        if (tierRebate == 0 || poolMult == 0) return (0, 0, 0, owner); // nothing configured

        rRef =
            (depositAmount * uint256(poolMult) * uint256(tierRebate) * ARTHA_SCALE) /
            (uint256(PPM) * uint256(PPM));

        uint32 share = s.codeDiscountShare[code]; // fraction (PPM) returned to investor
        investorReturn = (rRef * uint256(share)) / uint256(PPM);
        ownerReward = rRef - investorReturn;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Look up the code (and its terms) currently attached to an investor.
    function getReferrerInfoByTrader(address trader)
        external
        view
        returns (bytes32 code, address owner, uint16 tier, uint32 discountShare)
    {
        code = s.traderToCode[trader];
        if (code == bytes32(0)) return (bytes32(0), address(0), 0, 0);
        return (code, s.codeOwner[code], s.codeTier[code], s.codeDiscountShare[code]);
    }

    /// @notice Look up a code's owner, tier, and discount share directly.
    function getReferrerInfoByCode(bytes32 code)
        external
        view
        returns (address owner, uint16 tier, uint32 discountShare)
    {
        return (s.codeOwner[code], s.codeTier[code], s.codeDiscountShare[code]);
    }

    /**
     * @notice Preview the reward split for a hypothetical deposit (e.g. to show in
     *         the UI before the user confirms).
     * @return investorReturn ARTHA that would go back to the investor.
     * @return ownerReward    ARTHA that would go to the code owner.
     *
     * @dev Returns the *uncapped* theoretical amounts. The actual payout in
     *      `accrueReferral` may be scaled down if the referral budget is nearly
     *      exhausted (a rare edge case).
     */
    function calculateReferralRewards(uint256 poolId, address trader, uint256 depositAmount)
        external
        view
        returns (uint256 investorReturn, uint256 ownerReward)
    {
        bytes32 code = s.traderToCode[trader];
        if (code == bytes32(0)) return (0, 0);

        address owner = s.codeOwner[code];
        if (owner == address(0) || owner == trader) return (0, 0); // deactivated or self-referral

        (, investorReturn, ownerReward, ) = _computeReward(poolId, code, depositAmount);
    }

    /// @notice How much ARTHA `user` can claim right now.
    function pendingReferral(address user) external view returns (uint256) {
        return s.pendingReferralArtha[user];
    }

    /// @notice Stats for a referrer: their code, total USDC referred, lifetime ARTHA earned.
    function referralStats(address referrer)
        external
        view
        returns (bytes32 code, uint256 volume, uint256 lifetimeEarned)
    {
        code = s.ownerToCode[referrer];
        return (code, s.referralVolume[referrer], s.referrerArthaEarned[referrer]);
    }

    /// @notice Global referral budget usage.
    function referralBudget() external view returns (uint256 cap, uint256 emitted, uint256 remaining) {
        cap = s.referralBudgetCap;
        emitted = s.referralEmitted;
        remaining = cap > emitted ? cap - emitted : 0;
    }
}
