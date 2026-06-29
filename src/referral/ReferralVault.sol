// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "./VaultManager.sol";
import "./interfaces/IReferralSystem.sol";

/*//////////////////////////////////////////////////////////////////////////
                               ReferralVault
//////////////////////////////////////////////////////////////////////////*/
/**
 * @title  ReferralVault
 * @notice Holds the ARTHA earmarked for referral rewards and pays it out based
 *         on HOW LONG referred capital actually stays in the protocol. This is
 *         what defeats the wash/flash-loan attack: a deposit held for ~0 seconds
 *         earns ~0 reward, because reward is proportional to time & size.
 *
 *  WHO CALLS WHAT (a normal external CALL, not delegatecall):
 *    - The Diamond's logic facets are the approved "pool" (see VaultManager).
 *      On a referred deposit they call `openPosition`. On add/withdraw they call
 *      `increasePosition` / `decreasePosition` / `closePosition`. Those calls
 *      SETTLE the time-based reward before changing the principal.
 *    - This vault reads code data (owner, discount, tier multiplier) from the
 *      standalone ReferralSystem registry via the IReferralSystem interface.
 *
 *  HOW A REWARD IS SIZED (per position, per settlement):
 *
 *     gross = principal(USDT) * arthaPerUsdtPerYear[pool] * dt(seconds) * tierMult
 *             ---------------------------------------------------------------------
 *                         1e6  *  SECONDS_PER_YEAR  *  PPM
 *
 *       where dt = (min(now, accrualEnd) - lastSettle)
 *
 *     Then it is SPLIT using the discount captured when the position opened:
 *       investorPart = gross * discountShare / PPM     -> back to the investor
 *       ownerPart    = gross - investorPart            -> to the code's owner
 *
 *  WORKED EXAMPLE:
 *     principal = 1,000 USDT, pool rate = 0.01 ARTHA per USDT per year,
 *     held 1 year, tier 1 (1.0x), discountShare 20%:
 *       gross        = 1,000 * 0.01 * 1.0 = 10 ARTHA
 *       investorPart = 10 * 20% = 2 ARTHA
 *       ownerPart    = 10 - 2   = 8 ARTHA
 *
 *  FIXED-TERM RULE: if a position has a term, `accrualEnd = start + term`. Once
 *  `now` passes `accrualEnd`, `dt` becomes 0 — so keeping funds in after the term
 *  ends generates NOTHING more (for either the investor or the owner). Normal
 *  positions have `accrualEnd = max`, so they accrue until withdrawal.
 *
 *  FUNDING & MINTING: this vault does NOT mint per claim. The protocol mints
 *  ARTHA into this vault up front; claims just transfer from the balance. The
 *  admin can sweep genuine excess ARTHA, or any token sent here by mistake, via
 *  one `rescue` function.
 */
contract ReferralVault is VaultManager, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint32  public constant PPM = 1_000_000; // 1,000,000 == 100% (== 1.0x)

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The ARTHA token this vault distributes.
    IERC20 public immutable artha;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The registry the vault reads code/owner/tier/discount from.
    IReferralSystem public referralSystem;

    /// @notice Per-pool reward rate: ARTHA (18 decimals) per 1 USDT of principal
    ///         per year. Example: 1e16 means "0.01 ARTHA per USDT per year".
    mapping(uint256 => uint256) public arthaPerUsdtPerYear;

    struct Position {
        address investor;     // the depositor (their share of the reward)
        bytes32 code;         // referral code used (owner earns from it)
        uint256 poolId;       // which pool (sets the rate)
        uint256 principal;    // referred USDT principal (6 decimals)
        uint64  startTime;    // when the position opened
        uint64  accrualEnd;   // start+term (fixed) or type(uint64).max (normal)
        uint64  lastSettle;   // last time rewards were credited
        uint32  discountShare;// captured at open (PPM) — investor's share of reward
        bool    active;
    }

    /// @notice Auto-incrementing id for positions (0 is never used / "none").
    uint256 public nextPositionId;

    /// @notice positionId => position data.
    mapping(uint256 => Position) public positions;

    /// @notice Claimable ARTHA for an investor (their discount returns).
    mapping(address => uint256) public investorReward;

    /// @notice Claimable ARTHA for a code (claimed by the code's CURRENT owner).
    mapping(bytes32 => uint256) public codeReward;

    /// @notice Lifetime ARTHA credited to an investor (for display/tracking).
    mapping(address => uint256) public investorEarned;

    /// @notice Lifetime ARTHA credited to a code (for display/tracking).
    mapping(bytes32 => uint256) public codeEarned;

    /// @notice Sum of all credited-but-unclaimed ARTHA. Used to protect owed
    ///         rewards from the admin `rescue` function.
    /// @dev    NOTE: this counts only *settled* rewards. ARTHA that will be owed
    ///         from positions still accruing is NOT reserved here, so the admin
    ///         must keep the vault funded above ongoing accrual, and only sweep
    ///         what is clearly excess.
    uint256 public totalUnclaimed;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ReferralSystemUpdated(address oldSystem, address newSystem);
    event PoolRateUpdated(uint256 indexed poolId, uint256 arthaPerUsdtPerYear);

    event PositionOpened(uint256 indexed id, address indexed investor, bytes32 indexed code, uint256 poolId, uint256 principal, uint64 accrualEnd);
    event PositionIncreased(uint256 indexed id, uint256 added, uint256 newPrincipal);
    event PositionDecreased(uint256 indexed id, uint256 removed, uint256 newPrincipal);
    event PositionClosed(uint256 indexed id);
    event RewardAccrued(uint256 indexed id, bytes32 indexed code, address indexed investor, uint256 investorPart, uint256 ownerPart);

    event InvestorRewardsClaimed(address indexed investor, address to, uint256 amount);
    event OwnerRewardsClaimed(bytes32 indexed code, address owner, address to, uint256 amount);
    event Rescued(address indexed token, address to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _artha, address _admin, address _referralSystem) VaultManager(_admin) {
        require(_artha != address(0), "INVALID_ARTHA");
        require(_referralSystem != address(0), "INVALID_REFERRAL_SYSTEM");
        artha = IERC20(_artha);
        referralSystem = IReferralSystem(_referralSystem);
    }

    /*//////////////////////////////////////////////////////////////
                    POSITION LIFECYCLE (called by the Diamond)
            onlyPool == the approved caller(s); see VaultManager.setPool
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Open a referral position for a referred deposit. Records the
     *         position and STARTS the clock — but credits NOTHING yet (rewards
     *         are only settled on later update/withdraw, per your design).
     * @param  _investor      The depositor.
     * @param  _poolId        Pool the deposit went into (sets the rate).
     * @param  _principal     Referred USDT principal (6 decimals).
     * @param  _termDuration  Lock length in seconds; pass 0 for a normal/flexible
     *                        position (accrues until withdrawal). For a fixed
     *                        deposit, pass its term so accrual stops at term end.
     * @param  _code          The referral code the investor used.
     * @return id             The new position id, or 0 if there is no valid
     *                        referral (empty/invalid code, or self-referral).
     */
    function openPosition(
        address _investor,
        uint256 _poolId,
        uint256 _principal,
        uint256 _termDuration,
        bytes32 _code
    ) external onlyPool whenNotPaused returns (uint256 id) {
        if (_code == bytes32(0) || _principal == 0) return 0; // no referral on this deposit

        (address owner,, uint32 discountShare) = referralSystem.getReferrerInfoByCode(_code);
        if (owner == address(0) || owner == _investor) return 0; // invalid code or self-referral

        id = ++nextPositionId;
        uint64 start = uint64(block.timestamp);
        uint64 end = _termDuration == 0 ? type(uint64).max : start + uint64(_termDuration);

        positions[id] = Position({
            investor: _investor,
            code: _code,
            poolId: _poolId,
            principal: _principal,
            startTime: start,
            accrualEnd: end,
            lastSettle: start,
            discountShare: discountShare, // captured now; later owner changes don't affect this position
            active: true
        });

        emit PositionOpened(id, _investor, _code, _poolId, _principal, end);
    }

    /// @notice Investor added more to this position. Settles old accrual first.
    function increasePosition(uint256 _id, uint256 _addPrincipal) external onlyPool whenNotPaused {
        Position storage p = positions[_id];
        require(p.active, "INACTIVE");
        _settle(_id);                  // credit accrual at the OLD principal
        p.principal += _addPrincipal;  // then grow
        emit PositionIncreased(_id, _addPrincipal, p.principal);
    }

    /// @notice Investor partially withdrew. Settles accrual, then shrinks principal.
    function decreasePosition(uint256 _id, uint256 _removePrincipal) external onlyPool whenNotPaused {
        Position storage p = positions[_id];
        require(p.active, "INACTIVE");
        _settle(_id);
        require(_removePrincipal <= p.principal, "EXCEEDS_PRINCIPAL");
        p.principal -= _removePrincipal;
        emit PositionDecreased(_id, _removePrincipal, p.principal);
    }

    /// @notice Investor fully withdrew. Settles final accrual and closes.
    function closePosition(uint256 _id) external onlyPool whenNotPaused {
        Position storage p = positions[_id];
        require(p.active, "INACTIVE");
        _settle(_id);
        p.active = false;
        p.principal = 0;
        emit PositionClosed(_id);
    }

    /// @notice Permissionless settle — anyone (e.g. the code owner) can push a
    ///         position's accrued reward into the claimable balances so it is
    ///         up to date before claiming. Cannot change the outcome.
    function settlePosition(uint256 _id) external {
        _settle(_id);
    }

    /*//////////////////////////////////////////////////////////////
                          CORE: TIME-BASED SETTLE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Credits the reward accrued since `lastSettle`, capped at `accrualEnd`
     *      (which is the fixed-term end, or "never" for normal positions). After
     *      `accrualEnd`, `dt` is 0, so no further reward is generated.
     */
    function _settle(uint256 _id) internal {
        Position storage p = positions[_id];
        if (!p.active) return;

        // End of the chargeable window for this settle: the earlier of now and term end.
        uint64 cap = block.timestamp < p.accrualEnd ? uint64(block.timestamp) : p.accrualEnd;
        if (cap <= p.lastSettle) return; // nothing new (e.g. already past term end)

        uint256 dt = uint256(cap) - uint256(p.lastSettle);
        p.lastSettle = cap; // advance the marker even if we end up crediting 0

        // Read the code's current owner and tier multiplier from the registry.
        (address owner, uint256 tierMultPPM) = referralSystem.getRewardConfig(p.code);
        if (owner == address(0)) return; // code deactivated -> accrual stops, nothing credited

        uint256 rate = arthaPerUsdtPerYear[p.poolId];
        if (rate == 0 || tierMultPPM == 0) return;

        // gross = principal * rate * dt * tierMult / (1e6 * SECONDS_PER_YEAR * PPM)
        // (multiply first, divide last; magnitudes are far below 2^256)
        uint256 gross = (p.principal * rate * dt * tierMultPPM) /
            (1e6 * SECONDS_PER_YEAR * uint256(PPM));
        if (gross == 0) return;

        // Split using the discount captured when the position opened.
        uint256 investorPart = (gross * uint256(p.discountShare)) / uint256(PPM);
        uint256 ownerPart = gross - investorPart;

        if (investorPart > 0) {
            investorReward[p.investor] += investorPart;
            investorEarned[p.investor] += investorPart;
        }
        if (ownerPart > 0) {
            codeReward[p.code] += ownerPart;
            codeEarned[p.code] += ownerPart;
        }
        totalUnclaimed += gross;

        emit RewardAccrued(_id, p.code, p.investor, investorPart, ownerPart);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Investor claims all of their accumulated discount returns.
    function claimInvestorRewards(address _to) external nonReentrant whenNotPaused returns (uint256 amount) {
        require(_to != address(0), "INVALID_TO");
        amount = investorReward[msg.sender];
        require(amount > 0, "NOTHING_TO_CLAIM");

        investorReward[msg.sender] = 0; // effect (checks-effects-interactions)
        totalUnclaimed -= amount;
        artha.safeTransfer(_to, amount); // interaction
        emit InvestorRewardsClaimed(msg.sender, _to, amount);
    }

    /**
     * @notice Code owner claims rewards earned by their code. Caller must be the
     *         CURRENT owner of the code in the registry (matches your Vault.sol).
     */
    function claimOwnerRewards(bytes32 _code, address _to, uint256 _amount) external nonReentrant whenNotPaused {
        require(_to != address(0) && _amount > 0, "INVALID_PARAMS");
        (address owner,,) = referralSystem.getReferrerInfoByCode(_code);
        require(owner == msg.sender, "NOT_REFERRAL_OWNER");

        uint256 bal = codeReward[_code];
        require(bal >= _amount, "INSUFFICIENT_BALANCE");

        codeReward[_code] = bal - _amount;
        totalUnclaimed -= _amount;
        artha.safeTransfer(_to, _amount);
        emit OwnerRewardsClaimed(_code, msg.sender, _to, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set a pool's reward rate (ARTHA per USDT per year, 18 decimals).
    function setPoolRate(uint256 _poolId, uint256 _arthaPerUsdtPerYear) external onlyVaultAdmin {
        arthaPerUsdtPerYear[_poolId] = _arthaPerUsdtPerYear;
        emit PoolRateUpdated(_poolId, _arthaPerUsdtPerYear);
    }

    /// @notice Repoint to a new referral registry.
    function setReferralSystem(address _newReferralSystem) external onlyVaultAdmin {
        require(_newReferralSystem != address(0), "INVALID_REFERRAL_SYSTEM");
        address old = address(referralSystem);
        referralSystem = IReferralSystem(_newReferralSystem);
        emit ReferralSystemUpdated(old, _newReferralSystem);
    }

    /**
     * @notice ONE function to recover funds the vault should not be holding:
     *           - excess ARTHA (anything above what is owed to users), or
     *           - any other token sent here by mistake.
     * @dev    For ARTHA, the amount is capped to `balance - totalUnclaimed`, so
     *         the admin can never touch rewards that have already been credited.
     *         (Keep a buffer above ongoing accrual; see the note on totalUnclaimed.)
     */
    function rescue(address _token, address _to, uint256 _amount) external onlyVaultAdmin {
        require(_to != address(0) && _amount > 0, "INVALID_PARAMS");

        if (_token == address(artha)) {
            uint256 bal = artha.balanceOf(address(this));
            uint256 excess = bal > totalUnclaimed ? bal - totalUnclaimed : 0;
            require(_amount <= excess, "EXCEEDS_EXCESS"); // protect owed rewards
        }

        IERC20(_token).safeTransfer(_to, _amount);
        emit Rescued(_token, _to, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Read a position.
    function getPosition(uint256 _id) external view returns (Position memory) {
        return positions[_id];
    }

    /// @notice Settled (claimable now) balances.
    function pendingInvestor(address _investor) external view returns (uint256) {
        return investorReward[_investor];
    }

    function pendingOwner(bytes32 _code) external view returns (uint256) {
        return codeReward[_code];
    }

    /**
     * @notice Preview a position's UN-settled accrual (what `_settle` would credit
     *         right now). Useful for UIs to show "live" pending rewards.
     */
    function previewPosition(uint256 _id) public view returns (uint256 investorPart, uint256 ownerPart) {
        Position memory p = positions[_id];
        if (!p.active) return (0, 0);

        uint64 cap = block.timestamp < p.accrualEnd ? uint64(block.timestamp) : p.accrualEnd;
        if (cap <= p.lastSettle) return (0, 0);

        (address owner, uint256 tierMultPPM) = referralSystem.getRewardConfig(p.code);
        uint256 rate = arthaPerUsdtPerYear[p.poolId];
        if (owner == address(0) || rate == 0 || tierMultPPM == 0) return (0, 0);

        uint256 dt = uint256(cap) - uint256(p.lastSettle);
        uint256 gross = (p.principal * rate * dt * tierMultPPM) /
            (1e6 * SECONDS_PER_YEAR * uint256(PPM));

        investorPart = (gross * uint256(p.discountShare)) / uint256(PPM);
        ownerPart = gross - investorPart;
    }

    /// @notice ARTHA the admin could currently rescue (balance minus owed).
    function rescuableArtha() external view returns (uint256) {
        uint256 bal = artha.balanceOf(address(this));
        return bal > totalUnclaimed ? bal - totalUnclaimed : 0;
    }
}
