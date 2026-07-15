// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UserRewardSystem.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title  UserRewardVault
 * @notice The user reward MONEY layer. It holds the ARTHA, enforces the hard cap,
 *         and is the only place ARTHA can leave. THIRD and final layer:
 *
 *             UserRewardManager  <-  UserRewardSystem  <-  UserRewardVault
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY SPLIT LOGIC FROM MONEY
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *    AUDIT     "Where can ARTHA leave this system?" With the split the answer is
 *              claim() / claimAll() / claimFromVault() / claimFromPosition() /
 *              rescue(), in this file, and nowhere else. Without it you read 800
 *              lines of accrual math to be sure.
 *
 *    UPGRADE   An accrual bug is fixed by redeploying the System. The Vault --
 *              and the ARTHA pool sitting in it -- never moves. If they were one
 *              contract, every logic fix would mean migrating the treasury.
 *
 *    CAP       The hard cap is enforced at exactly ONE line, at ONE boundary
 *              (`_credit`). Not scattered through accrual code.
 *
 *    SYMMETRY  Two reward programmes, one shape. Learn it once.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE ACCOUNTING SPLIT: PRINCIPAL BY ID, ARTHA BY USER
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *    PRINCIPAL is keyed by (vault, tokenId)   <- lives in UserRewardSystem
 *      Because ANYONE may deposit into a position but only the OWNER may
 *      withdraw. Address-keying would let a withdrawal underflow one address's
 *      balance while leaving phantom principal on another's -- ARTHA accruing
 *      forever on capital that already left. Deposits and withdrawals hit the
 *      SAME id key, so the books always close.
 *
 *    EARNED / CLAIMED are keyed by USER ADDRESS   <- live HERE
 *      Because ARTHA belongs to whoever owned the position while it accrued.
 *      A user with 5 positions across 3 vaults has ONE claimable balance and
 *      claims in ONE transaction.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   CLAIM GRANULARITY -- everything the spec asks for
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *      claimAll(to)                        every vault, every position
 *      claim(to, amount)                   every vault, partial amount
 *      claimFromVault(vault, to)           ONE vault, all its positions
 *      claimFromPosition(vault, id, to)    ONE position
 *
 *  All four settle first, so `pending` is banked into `earned` before the read
 *  and the caller always gets everything they are owed at that instant.
 *
 *  ┌──────────────────────────────────────────────────────────────────────────┐
 *  │  A NOTE ON THE SCOPED CLAIMS.                                            │
 *  │                                                                          │
 *  │  `earned` is ONE per-user number. It has no per-vault or per-position     │
 *  │  compartments -- that is exactly what makes claimAll() a single tx.       │
 *  │  So claimFromVault / claimFromPosition settle only their own scope, then  │
 *  │  pay out MIN(what that scope produced for you, your total unclaimed).     │
 *  │                                                                          │
 *  │  They are a GAS/UX convenience -- "just pay me for this one position" --  │
 *  │  not a separate ledger. The money is fungible; the scoping is on the      │
 *  │  settle and on the amount, not on the balance.                            │
 *  └──────────────────────────────────────────────────────────────────────────┘
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE HARD CAP
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `totalDistributed` can never exceed `maxDistributable`. When the pool is dry,
 *  `_credit` silently returns 0: accrual continues (the accumulator keeps
 *  advancing) but pays nothing. It does NOT queue debt to be paid later.
 *
 *  That is the correct failure mode. Reverting instead would brick every deposit
 *  and withdrawal in every registered vault the moment the pool emptied, because
 *  the notify* hooks run inside those flows. A reward programme running out must
 *  never be able to freeze the protocol.
 *
 *  To stop cleanly: `stopAll(vaults)` zeroes every ratio, then `rescue()` sweeps
 *  the remainder to the treasury.
 */
contract UserRewardVault is UserRewardSystem, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────── the money ──────────────────────────────────────

    /// @notice The reward token. Immutable -- the pool can never be re-pointed.
    IERC20 public immutable artha;

    // ─────────────────────────── the cap ────────────────────────────────────────

    /// @notice THE HARD CAP. Sum of all credits can never exceed this.
    uint256 public maxDistributable;

    /// @notice Cumulative ARTHA credited across every user and vault.
    uint256 public totalDistributed;

    /// @notice Cumulative ARTHA actually transferred out.
    uint256 public totalClaimed;

    // ─────────────────────────── user ledgers ───────────────────────────────────

    /**
     * @notice user => lifetime ARTHA credited to them, across ALL vaults and ALL
     *         positions they owned at accrual time.
     *
     *  ONE balance per user -- what makes claimAll() a single transaction no
     *  matter how many positions they hold.
     *
     *  Also adjusted by the CASE B transfer flag: it goes DOWN for the seller and
     *  UP for the buyer by the same amount, so the sum across users always equals
     *  `totalDistributed`.
     */
    mapping(address => uint256) public totalEarned;

    /// @notice user => lifetime ARTHA claimed. Claimable = totalEarned - claimed.
    mapping(address => uint256) public claimed;

    /// @notice vault => user => ARTHA credited to them BY that vault.
    /// @dev    Attribution of where ARTHA was PRODUCED. A later CASE B gift does
    ///         not rewrite history, so this is not adjusted on a move.
    mapping(address => mapping(address => uint256)) public earnedByVault;

    /// @notice vault => tokenId => LIFETIME ARTHA this position ever produced,
    ///         across every owner it has had. Pure analytics.
    mapping(address => mapping(uint256 => uint256)) public earnedByPosition;

    // ─────────────────────────── events ─────────────────────────────────────────

    event Credited(address indexed vault, uint256 indexed tokenId, address indexed owner, uint256 amount);
    event CreditCapped(address indexed vault, uint256 indexed tokenId, uint256 requested, uint256 credited);
    event Claimed(address indexed user, address indexed to, uint256 amount);
    event EarnedMoved(address indexed vault, uint256 indexed tokenId, address indexed from, address to, uint256 amount);
    event CapSet(uint256 oldCap, uint256 newCap);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ─────────────────────────── constructor ────────────────────────────────────

    /**
     * @param _artha         The ARTHA token.
     * @param _rewardManager The admin. MUST be the Governance Timelock in prod.
     */
    constructor(address _artha, address _rewardManager) UserRewardSystem(_rewardManager) {
        require(_artha != address(0), "INVALID_ARTHA");
        artha = IERC20(_artha);
    }

    // ═══════════════════════════ cap management ═════════════════════════════════

    /**
     * @notice Set the hard cap. Fund the pool by transferring ARTHA to this
     *         contract, then set the cap to match.
     *
     *  The cap can never be lowered below what has already been credited -- that
     *  would mean owing users ARTHA the cap says does not exist.
     */
    function setCap(uint256 _cap) external onlyRewardManager {
        require(_cap >= totalDistributed, "CAP_LT_DISTRIBUTED");
        emit CapSet(maxDistributable, _cap);
        maxDistributable = _cap;
    }

    /// @notice ARTHA still available to be credited.
    function remainingPool() public view returns (uint256) {
        return maxDistributable - totalDistributed;
    }

    /**
     * @notice ARTHA credited but not yet claimed -- the protocol's live liability.
     * @dev    This contract's ARTHA balance should always be >= this. If it is
     *         not, the pool was under-funded relative to the cap.
     */
    function outstandingLiability() public view returns (uint256) {
        return totalDistributed - totalClaimed;
    }

    /// @notice True if the pool holds enough ARTHA to honour every credit made.
    function isSolvent() external view returns (bool) {
        return artha.balanceOf(address(this)) >= outstandingLiability();
    }

    // ═══════════════════════════ the money hooks ════════════════════════════════

    /**
     * @dev THE CAP BOUNDARY. Called by UserRewardSystem._settle().
     *
     *  Credits `_owner` (the position's owner at settle time), capped by the
     *  remaining pool. Returns what was actually credited.
     *
     *  Silently returning 0 when dry -- rather than reverting -- is deliberate.
     *  These hooks run inside vault deposit/withdraw/transfer. A reverting reward
     *  system would freeze the whole protocol the instant the pool emptied.
     */
    function _credit(address _vault, uint256 _tokenId, address _owner, uint256 _amount)
        internal
        override
        returns (uint256)
    {
        uint256 room = maxDistributable - totalDistributed;
        if (room == 0) {
            emit CreditCapped(_vault, _tokenId, _amount, 0);
            return 0;
        }

        uint256 give = _amount;
        if (give > room) {
            give = room;
            emit CreditCapped(_vault, _tokenId, _amount, give);
        }

        totalDistributed += give;
        totalEarned[_owner] += give; // ONE balance per user
        earnedByVault[_vault][_owner] += give;
        earnedByPosition[_vault][_tokenId] += give;

        emit Credited(_vault, _tokenId, _owner, give);
        return give;
    }

    /**
     * @dev CASE B. Move the ARTHA this position banked FOR `_from` into `_to`'s
     *      `earned`, where it is immediately claimable.
     *
     *  Called from notifyTransfer ONLY when `_from` set transferRewardsOnExit for
     *  this exact position, in their own transaction, beforehand.
     *
     *  ┌──────────────────────────────────────────────────────────────────────┐
     *  │  IT LANDS IN `earned`, NOT IN PENDING.                               │
     *  │                                                                      │
     *  │  `pending` is a pure function of principal x time x rate -- it is    │
     *  │  derived from the accumulator, not a balance anyone can write to.    │
     *  │  There is no way to "put ARTHA into pending", and it would be wrong  │
     *  │  anyway: the old owner ALREADY took the risk and ALREADY put in the  │
     *  │  time. That ARTHA is fully EARNED. So it goes straight to            │
     *  │  totalEarned[_to] and the buyer can claim it in the next call.       │
     *  └──────────────────────────────────────────────────────────────────────┘
     *
     *  ┌──────────────────────────────────────────────────────────────────────┐
     *  │  ACCOUNTING: THIS IS A RE-ATTRIBUTION, NOT A CREDIT.                 │
     *  │    - totalDistributed does NOT change (nothing new left the pool)    │
     *  │    - the cap is NOT touched (no new ARTHA was created)               │
     *  │    - totalEarned[from] DOWN, totalEarned[to] UP, same amount, so     │
     *  │      Sigma totalEarned == totalDistributed still holds               │
     *  │    - earnedByVault is NOT rewritten: it records where ARTHA was      │
     *  │      PRODUCED, and a later gift does not change that history         │
     *  └──────────────────────────────────────────────────────────────────────┘
     *
     *  DOUBLE-CAPPED, and both caps matter:
     *    1. by positionEarnedForOwner[v][id][from] -- so a seller can only give
     *       away what THIS position earned for THEM, never ARTHA from positions
     *       they are keeping, and never a previous owner's era
     *    2. by their actual unclaimed balance -- because they may have already
     *       claimed some or all of it (SEE CASE D: this is the front-run, and it
     *       is why the flag is a gift instruction, not an escrow)
     */
    function _moveEarned(address _vault, uint256 _tokenId, address _from, address _to)
        internal
        override
        returns (uint256)
    {
        uint256 amount = positionEarnedForOwner[_vault][_tokenId][_from];
        if (amount == 0) return 0;

        // CAP 2: they may have already claimed it (Case D front-run)
        uint256 unclaimed = totalEarned[_from] - claimed[_from];
        if (amount > unclaimed) amount = unclaimed;
        if (amount == 0) return 0;

        totalEarned[_from] -= amount;
        totalEarned[_to] += amount;

        // the seller's era on this position is closed out
        positionEarnedForOwner[_vault][_tokenId][_from] = 0;
        positionEarnedForOwner[_vault][_tokenId][_to] += amount;

        emit EarnedMoved(_vault, _tokenId, _from, _to, amount);
        return amount;
    }

    // ═══════════════════════════ claims ═════════════════════════════════════════

    /**
     * @notice Claim EVERYTHING: every vault, every position, one transaction.
     *
     *  The payoff of the key split. Principal is tracked per position (so the
     *  books close), but ARTHA lands in ONE per-user balance (so claiming is one
     *  call). A user with 5 positions across 3 vaults calls this once.
     *
     * @param _to Where to send the ARTHA.
     */
    function claimAll(address _to) external nonReentrant whenNotPaused returns (uint256 amount) {
        require(_to != address(0), "ZERO_ADDR");

        _settleUserPositions(msg.sender); // bank pending -> earned, everywhere

        amount = totalEarned[msg.sender] - claimed[msg.sender];
        require(amount > 0, "NOTHING_TO_CLAIM");

        _payOut(msg.sender, _to, amount);
    }

    /**
     * @notice Claim a specific amount, drawn from your whole balance.
     */
    function claim(address _to, uint256 _amount) external nonReentrant whenNotPaused {
        require(_to != address(0), "ZERO_ADDR");
        require(_amount != 0, "ZERO_AMOUNT");

        _settleUserPositions(msg.sender);

        uint256 owed = totalEarned[msg.sender] - claimed[msg.sender];
        require(_amount <= owed, "EXCEEDS_EARNED");

        _payOut(msg.sender, _to, _amount);
    }

    /**
     * @notice Claim what ONE vault produced for you, across all your positions
     *         in it. Cheaper than claimAll when you hold many positions
     *         elsewhere -- it only settles this vault's.
     */
    function claimFromVault(address _vault, address _to)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amount)
    {
        require(_to != address(0), "ZERO_ADDR");
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");

        _settleUserPositionsInVault(msg.sender, _vault);

        // what this vault produced for them, bounded by what they still hold
        amount = earnedByVault[_vault][msg.sender];
        uint256 owed = totalEarned[msg.sender] - claimed[msg.sender];
        if (amount > owed) amount = owed;
        require(amount > 0, "NOTHING_TO_CLAIM");

        _payOut(msg.sender, _to, amount);
    }

    /**
     * @notice Claim what ONE position produced for you. The finest granularity.
     *         Settles only that position.
     */
    function claimFromPosition(address _vault, uint256 _tokenId, address _to)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amount)
    {
        require(_to != address(0), "ZERO_ADDR");
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");

        _settle(_vault, _tokenId, msg.sender);

        // what this position earned FOR THEM, bounded by what they still hold
        amount = positionEarnedForOwner[_vault][_tokenId][msg.sender];
        uint256 owed = totalEarned[msg.sender] - claimed[msg.sender];
        if (amount > owed) amount = owed;
        require(amount > 0, "NOTHING_TO_CLAIM");

        _payOut(msg.sender, _to, amount);
    }

    /// @dev The single exit for ARTHA. Every claim path funnels through here.
    function _payOut(address _user, address _to, uint256 _amount) internal {
        claimed[_user] += _amount;
        totalClaimed += _amount;
        _bookVaultClaims(_user, _amount);
        artha.safeTransfer(_to, _amount);
        emit Claimed(_user, _to, _amount);
    }

    /**
     * @dev Attribute a claim across the vaults the user earned from, so
     *      `vaultMeta[v].totalArthaClaimed` stays meaningful.
     *
     *      Proportional to each vault's share of their lifetime earnings. This is
     *      bookkeeping only -- it never affects how much is paid out.
     */
    function _bookVaultClaims(address _user, uint256 _amount) internal {
        PositionRef[] storage list = userPositions[_user];
        uint256 lifetime = totalEarned[_user];
        if (lifetime == 0) return;

        for (uint256 i; i < list.length; i++) {
            address v = list[i].vault;
            uint256 fromVault = earnedByVault[v][_user];
            if (fromVault == 0) continue;
            uint256 share = (_amount * fromVault) / lifetime;
            if (share != 0) vaultMeta[v].totalArthaClaimed += share;
        }
    }

    // ═══════════════════════════ views ══════════════════════════════════════════

    /**
     * @notice TOTAL ARTHA owed to `_user`: banked plus still accruing.
     *
     *      claimable = (earned - claimed) + pending
     *
     *  THE headline number for a UI. Every claim path settles first, so calling
     *  claimAll() pays out exactly this. The split only matters if you read the
     *  state without settling.
     */
    function claimable(address _user) public view returns (uint256) {
        return (totalEarned[_user] - claimed[_user]) + pendingRewardAll(_user);
    }

    /// @notice Only the already-banked portion (excludes live pending).
    function claimableBanked(address _user) public view returns (uint256) {
        return totalEarned[_user] - claimed[_user];
    }

    /// @notice Total owed to `_user` from ONE vault: banked-from-it + pending-in-it.
    function claimableInVault(address _user, address _vault) external view returns (uint256) {
        uint256 banked = earnedByVault[_vault][_user];
        uint256 owed = totalEarned[_user] - claimed[_user];
        if (banked > owed) banked = owed;
        return banked + pendingRewardInVault(_user, _vault);
    }

    /// @notice Total owed to `_user` from ONE position: banked-from-it + pending-on-it.
    function claimableFromPosition(address _user, address _vault, uint256 _tokenId)
        external
        view
        returns (uint256)
    {
        uint256 banked = positionEarnedForOwner[_vault][_tokenId][_user];
        uint256 owed = totalEarned[_user] - claimed[_user];
        if (banked > owed) banked = owed;
        return banked + pendingReward(_vault, _tokenId);
    }

    /**
     * @notice EVERYTHING about one user, in a single call.
     *
     * @return livePrincipalNorm total principal currently invested, 18dp, summed
     *                           over every position they are linked to
     * @return earnedTotal       LIFETIME ARTHA credited to them (+ anything
     *                           gifted in via CASE B, - anything gifted out)
     * @return claimedTotal      LIFETIME ARTHA they have actually withdrawn
     * @return bankedUnclaimed   earned - claimed. Settled, sitting here, theirs.
     * @return pendingTotal      un-banked ARTHA accruing right now
     * @return claimableTotal    bankedUnclaimed + pendingTotal -- what they get
     *                           if they call claimAll() this second
     * @return positionCount     how many positions they are linked to
     */
    function userBooks(address _user)
        external
        view
        returns (
            uint256 livePrincipalNorm,
            uint256 earnedTotal,
            uint256 claimedTotal,
            uint256 bankedUnclaimed,
            uint256 pendingTotal,
            uint256 claimableTotal,
            uint256 positionCount
        )
    {
        uint256 pend = pendingRewardAll(_user);
        uint256 banked = totalEarned[_user] - claimed[_user];
        return (
            userPrincipalNorm(_user),
            totalEarned[_user],
            claimed[_user],
            banked,
            pend,
            banked + pend,
            userPositions[_user].length
        );
    }

    /**
     * @notice EVERYTHING about one user's stake in ONE vault.
     *
     * @return livePrincipalNorm their live principal in that vault, 18dp
     * @return earnedFromVault   LIFETIME ARTHA this vault credited them
     * @return pendingInVault    un-banked ARTHA accruing for them there
     * @return claimableInVault_ what they can get from it right now
     */
    function userVaultBooks(address _user, address _vault)
        external
        view
        returns (
            uint256 livePrincipalNorm,
            uint256 earnedFromVault,
            uint256 pendingInVault,
            uint256 claimableInVault_
        )
    {
        uint256 pend = pendingRewardInVault(_user, _vault);
        uint256 banked = earnedByVault[_vault][_user];
        uint256 owed = totalEarned[_user] - claimed[_user];
        if (banked > owed) banked = owed;
        return (userPrincipalNormInVault(_user, _vault), earnedByVault[_vault][_user], pend, banked + pend);
    }

    /**
     * @notice EVERYTHING about one position -- principal AND ARTHA.
     *
     * @return livePrincipalRaw    currently invested, raw base units
     * @return depositedRaw        LIFETIME ever deposited into this position
     * @return withdrawnRaw        LIFETIME ever withdrawn from this position
     * @return arthaProducedTotal  LIFETIME ARTHA this position generated, across
     *                             EVERY owner it has ever had. The number a
     *                             marketplace buyer actually wants. NOT a claim
     *                             on anything.
     * @return arthaForCurrentOwner ARTHA it banked for `_owner` specifically --
     *                             this is what a CASE B transfer would move
     * @return pendingArtha        un-banked ARTHA accruing on it right now
     */
    function positionArthaBooks(address _vault, uint256 _tokenId, address _owner)
        external
        view
        returns (
            uint256 livePrincipalRaw,
            uint256 depositedRaw,
            uint256 withdrawnRaw,
            uint256 arthaProducedTotal,
            uint256 arthaForCurrentOwner,
            uint256 pendingArtha
        )
    {
        PositionAccount storage a = positionAccount[_vault][_tokenId];
        return (
            positionPrincipalRaw(_vault, _tokenId),
            a.depositedRaw,
            a.withdrawnRaw,
            earnedByPosition[_vault][_tokenId],
            positionEarnedForOwner[_vault][_tokenId][_owner],
            pendingReward(_vault, _tokenId)
        );
    }

    // ═══════════════════════════ admin ══════════════════════════════════════════

    /**
     * @notice Sweep tokens out. Used to retire the programme: `stopAll()` every
     *         vault first, then sweep the remainder to the treasury.
     *
     *  ┌──────────────────────────────────────────────────────────────────────┐
     *  │  GUARDED: cannot sweep ARTHA that is owed to users.                  │
     *  │                                                                      │
     *  │  Admin can only take `balance - (totalDistributed - totalClaimed)`.  │
     *  │  Credited-but-unclaimed ARTHA is a liability and stays put, even for │
     *  │  the Timelock. Users who earned it can always claim it.              │
     *  └──────────────────────────────────────────────────────────────────────┘
     */
    function rescue(address _token, address _to, uint256 _amount) external onlyRewardManager {
        require(_to != address(0), "ZERO_ADDR");

        if (_token == address(artha)) {
            uint256 balance = artha.balanceOf(address(this));
            uint256 liability = outstandingLiability();
            uint256 free = balance > liability ? balance - liability : 0;
            require(_amount <= free, "WOULD_BREAK_LIABILITY");
        }

        IERC20(_token).safeTransfer(_to, _amount);
        emit Rescued(_token, _to, _amount);
    }
}
