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
 *  Mirrors the referral stack:
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY SPLIT LOGIC FROM MONEY
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *    AUDIT     "Where can ARTHA leave this system?" With the split, the answer
 *              is: `claim()` and `claimAll()` and `rescue()`, in this file, and
 *              nowhere else. Without it, you read 800 lines of accrual math to
 *              be sure.
 *
 *    UPGRADE   An accrual bug is fixed by redeploying the System. The Vault --
 *              and the ARTHA pool sitting in it -- never moves. If they were one
 *              contract, every logic fix would mean migrating the treasury.
 *
 *    CAP       The hard cap is enforced at exactly ONE line, at exactly ONE
 *              boundary (`_credit`). Not scattered through accrual code.
 *
 *    SYMMETRY  Two reward programmes, one shape. Learn it once.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE ACCOUNTING SPLIT: PRINCIPAL BY ID, ARTHA BY USER
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  This is the resolution of the whole design problem, and the two halves must
 *  be read together:
 *
 *    PRINCIPAL is keyed by (vault, tokenId)   <- lives in UserRewardSystem
 *      Because ANYONE may deposit into a position but only the OWNER may
 *      withdraw. Keying principal by depositor address would let a withdrawal
 *      underflow one address's balance while leaving phantom principal on
 *      another's -- ARTHA accruing forever on capital that already left.
 *      Deposits and withdrawals hit the SAME id key, so the books always close.
 *
 *    EARNED / CLAIMED are keyed by USER ADDRESS   <- live HERE
 *      Because ARTHA belongs to whoever owned the position while it accrued.
 *      A user with 5 positions across 3 vaults has ONE claimable balance and
 *      claims in ONE transaction.
 *
 *  Worked example -- the exact scenario that motivated this design:
 *
 *    day 0    user-1 mints id-1, deposits 1,000 USDC.  (vault ratio 50%/yr)
 *               principalNorm[vault][id-1] = 1,000e18
 *
 *    day 90    user-2 deposits 1,000 USDC into id-1 (a gift to user-1).
 *               -> settle FIRST: banks 50% x 1,000 x 90/360 = 125 ARTHA
 *                  to USER-1 (the OWNER -- user-2 gets nothing, it was a gift)
 *               -> principalNorm[vault][id-1] = 2,000e18
 *
 *    day 180   user-1 withdraws the full 2,000 USDC.
 *               -> settle FIRST: banks 50% x 2,000 x 90/360 = 250 ARTHA
 *                  to USER-1
 *               -> principalNorm[vault][id-1] = 2,000e18 - 2,000e18 = 0  EXACTLY
 *
 *    Totals:  earned[user-1] = 375 ARTHA.  earned[user-2] = 0.
 *             principal closes to zero with NO underflow and NO phantom.
 *
 *  And on transfer:
 *
 *    day 90    user-1 sells id-1 to carol.
 *               -> settle(user-1) FIRST: banks their 125 ARTHA
 *               -> principal does NOT move (it is on the id, not the address)
 *               -> carol accrues from her block 1
 *               -> earned[user-1] = 125 is UNTOUCHABLE by carol
 *               -> claimed[] is per-user, so their ledgers never intersect
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE HARD CAP
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `totalDistributed` can never exceed `maxDistributable`. When the pool is dry,
 *  `_credit` silently returns 0: accrual continues (the accumulator keeps
 *  advancing) but pays nothing. It does NOT queue debt to be paid later.
 *
 *  This is the correct failure mode. The alternative -- reverting -- would brick
 *  every deposit and withdrawal in every registered vault the moment the pool
 *  emptied, because the notify* hooks are called inside those flows. A reward
 *  programme running out must never be able to freeze the protocol.
 *
 *  To stop cleanly, governance calls `stopAll(vaults)` to zero every ratio, then
 *  `rescue()` sweeps the remainder to the treasury.
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
     *  ONE balance per user. This is what makes claimAll() a single transaction
     *  regardless of how many positions they hold.
     */
    mapping(address => uint256) public totalEarned;

    /// @notice user => lifetime ARTHA claimed. Claimable = totalEarned - claimed.
    mapping(address => uint256) public claimed;

    /// @notice vault => user => ARTHA credited from that vault. Attribution only.
    mapping(address => mapping(address => uint256)) public earnedByVault;

    /// @notice vault => tokenId => ARTHA ever credited via that position.
    /// @dev    Pure analytics: "how much has id-1 produced, across all owners?"
    mapping(address => mapping(uint256 => uint256)) public earnedByPosition;

    // ─────────────────────────── events ─────────────────────────────────────────

    event Credited(address indexed vault, uint256 indexed tokenId, address indexed owner, uint256 amount);
    event CreditCapped(address indexed vault, uint256 indexed tokenId, uint256 requested, uint256 credited);
    event Claimed(address indexed user, address indexed to, uint256 amount);
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
     *  The cap can never be lowered below what has already been credited --
     *  that would mean owing users ARTHA the cap says does not exist.
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
     * @dev    The contract's ARTHA balance should always be >= this. If it is not,
     *         someone under-funded the pool relative to the cap.
     */
    function outstandingLiability() external view returns (uint256) {
        return totalDistributed - totalClaimed;
    }

    /// @notice True if the pool holds enough ARTHA to honour every credit made.
    function isSolvent() external view returns (bool) {
        return artha.balanceOf(address(this)) >= (totalDistributed - totalClaimed);
    }

    // ═══════════════════════════ the credit hook ════════════════════════════════

    /**
     * @dev THE CAP BOUNDARY. Called by UserRewardSystem._settle().
     *
     *  Credits `_owner` (the position's owner at settle time), capped by the
     *  remaining pool. Returns what was actually credited.
     *
     *  Silently returning 0 when dry -- rather than reverting -- is deliberate.
     *  These hooks run inside vault deposit/withdraw. A reverting reward system
     *  would freeze the whole protocol the instant the pool emptied.
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

    // ═══════════════════════════ claims ═════════════════════════════════════════

    /**
     * @notice Settle every position you own, then claim everything, in one tx.
     *
     *  This is the payoff of splitting the keys. Principal is tracked per
     *  position (so the books close), but ARTHA lands in ONE per-user balance
     *  (so claiming is one transaction). A user with 5 positions across 3 vaults
     *  calls this once.
     *
     * @param _to Where to send the ARTHA.
     */
    function claimAll(address _to) external nonReentrant whenNotPaused returns (uint256 amount) {
        require(_to != address(0), "ZERO_ADDR");

        _settleCallerPositions();

        amount = totalEarned[msg.sender] - claimed[msg.sender];
        require(amount > 0, "NOTHING_TO_CLAIM");

        claimed[msg.sender] += amount;
        totalClaimed += amount;

        _bookVaultClaims(msg.sender, amount);

        artha.safeTransfer(_to, amount);
        emit Claimed(msg.sender, _to, amount);
    }

    /**
     * @notice Claim a specific amount (partial claims / gas control).
     */
    function claim(address _to, uint256 _amount) external nonReentrant whenNotPaused {
        require(_to != address(0), "ZERO_ADDR");
        require(_amount != 0, "ZERO_AMOUNT");

        _settleCallerPositions();

        uint256 owed = totalEarned[msg.sender] - claimed[msg.sender];
        require(_amount <= owed, "EXCEEDS_EARNED");

        claimed[msg.sender] += _amount;
        totalClaimed += _amount;

        _bookVaultClaims(msg.sender, _amount);

        artha.safeTransfer(_to, _amount);
        emit Claimed(msg.sender, _to, _amount);
    }

    /**
     * @dev Settle every position the caller currently owns, banking pending into
     *      `totalEarned` before we read it.
     *
     *      `msg.sender` is passed as the owner: they are claiming, so by
     *      definition they are the one the vault would name as owner. A stale
     *      entry (a position they since sold) settles with them as `_owner`,
     *      which would be wrong -- so `notifyTransfer` MUST be wired up on the
     *      vault side. Without it, a seller could keep accruing on a position
     *      they no longer own. See the test suite for the case that proves this.
     */
    function _settleCallerPositions() internal {
        PositionRef[] storage list = userPositions[msg.sender];
        for (uint256 i; i < list.length; i++) {
            _settle(list[i].vault, list[i].tokenId, msg.sender);
        }
    }

    /**
     * @dev Attribute a claim across the vaults the user earned from, so
     *      `vaultMeta[v].totalArthaClaimed` stays meaningful.
     *
     *      Proportional to each vault's share of the user's lifetime earnings.
     *      This is bookkeeping only -- it never affects how much is paid out.
     */
    function _bookVaultClaims(address _user, uint256 _amount) internal {
        PositionRef[] storage list = userPositions[_user];
        uint256 lifetime = totalEarned[_user];
        if (lifetime == 0) return;

        for (uint256 i; i < list.length; i++) {
            address v = list[i].vault;
            uint256 fromVault = earnedByVault[v][_user];
            if (fromVault == 0) continue;
            // share = amount * (this vault's contribution / lifetime total)
            uint256 share = (_amount * fromVault) / lifetime;
            if (share != 0) vaultMeta[v].totalArthaClaimed += share;
        }
    }

    /// @notice ARTHA `_user` can claim right now, including un-banked pending.
    function claimable(address _user) external view returns (uint256) {
        return (totalEarned[_user] - claimed[_user]) + pendingRewardAll(_user);
    }

    /// @notice Only the already-banked portion (excludes live pending).
    function claimableBanked(address _user) external view returns (uint256) {
        return totalEarned[_user] - claimed[_user];
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
            uint256 liability = totalDistributed - totalClaimed;
            uint256 balance = artha.balanceOf(address(this));
            uint256 free = balance > liability ? balance - liability : 0;
            require(_amount <= free, "WOULD_BREAK_LIABILITY");
        }

        IERC20(_token).safeTransfer(_to, _amount);
        emit Rescued(_token, _to, _amount);
    }
}
