// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UserRewardManager.sol";

/**
 * @title  UserRewardSystem
 * @notice The user reward LOGIC + ACCOUNTING layer. It knows "which position holds
 *         how much principal", "what rate each vault pays", and "how much each
 *         position has accrued". It holds NO money. Second layer of the chain:
 *
 *             UserRewardManager  <-  UserRewardSystem  <-  UserRewardVault
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY KEYED BY (VAULT, POSITION ID) AND NOT BY (VAULT, USER ADDRESS)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  This is THE design decision in this contract. Read it before anything else.
 *
 *  The Artha vault allows ANYONE to deposit into ANY position, but only the
 *  position's OWNER may withdraw. That asymmetry breaks address-keyed accounting.
 *  Here is the exact failure:
 *
 *    day 0    user-1 mints position id-1 and deposits 1,000 USDC.
 *    day 90   user-2 deposits 1,000 USDC into id-1 (a gift to user-1).
 *    day 180  user-1 (the OWNER) withdraws the full 2,000 USDC.
 *
 *  ── ADDRESS-KEYED, crediting the DEPOSITOR ────────────────────────────────
 *      principal[user-1] = 1,000        (their own deposit)
 *      principal[user-2] = 1,000        (their gift)
 *
 *      user-1 withdraws 2,000. We must subtract 2,000 from... whom?
 *        - principal[user-1] is only 1,000  ->  UNDERFLOW. Clamp to 0.
 *        - principal[user-2] is still 1,000 ->  user-2 keeps accruing ARTHA
 *                                               on capital that HAS LEFT THE
 *                                               VAULT. Phantom principal.
 *
 *      Result: the vault holds 0, but the system thinks 1,000 is still earning.
 *      The pool bleeds ARTHA forever, to someone who has no capital at risk.
 *      THIS IS THE BUG.
 *
 *  ── ADDRESS-KEYED, crediting the OWNER ────────────────────────────────────
 *      principal[user-1] = 2,000        (both deposits credited to the owner)
 *      principal[user-2] = 0
 *
 *      user-1 withdraws 2,000 -> principal[user-1] = 0. Accounting closes.
 *
 *      This one *happens* to work -- but it is fragile. It relies on the vault
 *      always passing the OWNER, never the depositor. And it still cannot answer
 *      "how much principal does position id-1 hold?" without summing over every
 *      address that ever touched it. On NFT transfer you must MOVE principal
 *      between two address keys, which means reading the position's basis from
 *      the vault and trusting it. More moving parts, more to get wrong.
 *
 *  ── ID-KEYED (this contract) ──────────────────────────────────────────────
 *      principal[vault][id-1] = 2,000   (both deposits land on the POSITION)
 *
 *      user-1 withdraws 2,000 -> principal[vault][id-1] = 0. Closes exactly.
 *
 *      The invariant that makes this work:
 *
 *          ┌────────────────────────────────────────────────────────────┐
 *          │  DEPOSIT credits (vault, id).                              │
 *          │  WITHDRAW debits (vault, id).                              │
 *          │  SAME KEY. ALWAYS. Regardless of who called either one.    │
 *          │                                                            │
 *          │  => principal[vault][id] can NEVER underflow, because it   │
 *          │     is impossible to withdraw more from a position than    │
 *          │     was deposited into it.                                 │
 *          └────────────────────────────────────────────────────────────┘
 *
 *      The money went INTO the position, so the accounting lives ON the position.
 *      Depositor identity is irrelevant to the vault's books -- and so it is
 *      irrelevant here too.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHO GETS PAID: THE OWNER AT SETTLE TIME
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Principal is tracked per POSITION, but ARTHA is credited to the position's
 *  OWNER at the moment of settlement. The vault passes the current owner on every
 *  hook. This gives the correct semantics for both of the awkward cases:
 *
 *    - user-2 deposits into user-1's position:
 *        -> principal grows on id-1
 *        -> ARTHA accrues to id-1
 *        -> it is credited to user-1, the OWNER, because they are the one who
 *           can withdraw the capital. user-2 made a GIFT. Gifts do not earn.
 *
 *    - user-1 transfers id-1 to carol on day 90:
 *        -> the vault calls notifyTransfer(vault, id-1, user-1, carol)
 *        -> we settle FIRST, banking 90 days of ARTHA to user-1
 *        -> then the owner changes; carol accrues from her block 1
 *        -> user-1 KEEPS the 125 ARTHA they already earned; it is in their
 *           `earned` balance and carol can never touch it
 *
 *      Already-earned ARTHA never transfers with the NFT. It was earned by
 *      user-1's capital being at risk for user-1's time. Selling the position
 *      does not retroactively unearn it -- just as selling a stock does not
 *      claw back a dividend already paid.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE ACCUMULATOR
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Standard MasterChef accumulator, one per vault:
 *
 *      acc          += rewardRatio * dt * ACC / (RATIO_ONE * YEAR)
 *      accumulated   = principalNorm * acc / ACC
 *      pending       = accumulated - rewardDebt
 *
 *  Reward for a (vault, position) is:
 *      (principalNorm * rewardRatio[vault]) / 1e18 per YEAR, YEAR = 360 days,
 *      rewardRatio capped at 1e18 (= 100%/yr).
 *
 *  Caller sites (msg.sender must be an approved caller = the vault / Diamond):
 *     - deposit  -> notifyDeposit(vault, tokenId, owner, rawPrincipal)
 *     - withdraw -> notifyWithdraw(vault, tokenId, owner, rawPrincipal)
 *     - transfer -> notifyTransfer(vault, tokenId, from, to)
 *
 *  Anyone may sync()/syncAll() to bank a position's pending into claimable
 *  `earned` without claiming. Ratio changes are non-retroactive and never
 *  overpay, so correctness does not depend on who (if anyone) calls sync.
 */
abstract contract UserRewardSystem is UserRewardManager {
    // ─────────────────────────── constants ──────────────────────────────────────

    /// @notice Accumulator fixed-point scale.
    uint256 public constant ACC = 1e18;

    /// @notice Protocol year. 360 days, matching the referral stack.
    uint256 public constant YEAR = 360 days;

    /// @notice 100% in ratio terms. rewardRatio is capped here.
    uint256 public constant RATIO_ONE = 1e18;

    // ─────────────────────────── vault config / books ───────────────────────────

    /**
     * @param registered          whether the vault is active
     * @param decimals            base-token decimals
     * @param rewardRatio         per-vault rate (0..1e18). ZERO => NO REWARDS.
     * @param scale               10^(18 - decimals), normalises principal to 18dp
     * @param accArthaPerPrincipal MasterChef accumulator, scaled by ACC
     * @param lastUpdate          timestamp the accumulator last advanced
     * @param totalPrincipalNorm  live principal across all positions, 18dp
     * @param totalArthaEarned    cumulative ARTHA credited for this vault
     * @param totalArthaClaimed   cumulative ARTHA claimed from this vault
     */
    struct VaultMeta {
        bool registered;
        uint8 decimals;
        uint256 rewardRatio;
        uint256 scale;
        uint256 accArthaPerPrincipal;
        uint256 lastUpdate;
        uint256 totalPrincipalNorm;
        uint256 totalArthaEarned;
        uint256 totalArthaClaimed;
    }

    /**
     * @param balanceNorm live principal for this (vault, tokenId), 18dp
     * @param rewardDebt  checkpoint = balanceNorm * acc / ACC at last settle
     */
    struct PositionAccount {
        uint256 balanceNorm;
        uint256 rewardDebt;
    }

    mapping(address => VaultMeta) public vaultMeta;
    uint64 public vaultCount;

    /// @notice vault => tokenId => accrual state. THE CORE MAPPING.
    mapping(address => mapping(uint256 => PositionAccount)) public positionAccount;

    // ─────────────────────────── per-position footprint ─────────────────────────

    /// @notice vault => list of tokenIds that have ever held principal.
    /// @dev    Used to bound syncAllPositions(vault). Append-only.
    mapping(address => uint256[]) public vaultPositions;
    mapping(address => mapping(uint256 => bool)) public vaultHasPosition;

    // ─────────────────────────── per-user footprint ─────────────────────────────

    /**
     * @notice user => list of (vault, tokenId) pairs they currently own that have
     *         ever held principal. Lets claimAll() settle everything in one tx.
     *
     *  Maintained on notifyDeposit (add to owner) and notifyTransfer (move from
     *  old owner to new). Entries are NOT removed on withdraw -- a zero-principal
     *  position settles to zero, which is harmless and keeps the code simple.
     */
    struct PositionRef {
        address vault;
        uint256 tokenId;
    }

    mapping(address => PositionRef[]) public userPositions;
    mapping(address => mapping(address => mapping(uint256 => bool))) public userHasPosition;

    // ─────────────────────────── events ─────────────────────────────────────────

    event VaultRegistered(address indexed vault, uint8 decimals, uint256 rewardRatio);
    event RewardRatioUpdated(address indexed vault, uint256 oldRatio, uint256 newRatio, uint256 at);
    event PrincipalIncreased(address indexed vault, uint256 indexed tokenId, address indexed owner, uint256 raw, uint256 newBalanceNorm);
    event PrincipalDecreased(address indexed vault, uint256 indexed tokenId, address indexed owner, uint256 raw, uint256 newBalanceNorm);
    event PositionTransferred(address indexed vault, uint256 indexed tokenId, address indexed from, address to, uint256 bankedToFrom);
    event Settled(address indexed vault, uint256 indexed tokenId, address indexed owner, uint256 amount);

    // ─────────────────────────── constructor ────────────────────────────────────

    constructor(address _rewardManager) UserRewardManager(_rewardManager) {}

    // ═══════════════════════════ accrual core ═══════════════════════════════════

    /**
     * @dev Advance a vault's accumulator to `block.timestamp`.
     *
     *  ┌──────────────────────────────────────────────────────────────────────┐
     *  │  rewardRatio == 0  =>  NOTHING ACCRUES.                              │
     *  │                                                                      │
     *  │  The `if (ratio != 0)` guard is not strictly necessary -- multiplying │
     *  │  by zero would add zero anyway. We keep it because:                   │
     *  │    1. it saves the arithmetic and makes the intent explicit           │
     *  │    2. it documents that ZERO IS THE OFF SWITCH                        │
     *  │                                                                      │
     *  │  lastUpdate still advances, so turning the ratio back on does NOT     │
     *  │  retroactively pay for the dark period. That is deliberate.           │
     *  └──────────────────────────────────────────────────────────────────────┘
     */
    function _updateAccumulator(address _vault) internal {
        VaultMeta storage m = vaultMeta[_vault];
        if (block.timestamp <= m.lastUpdate) return;

        uint256 ratio = m.rewardRatio;
        if (ratio != 0) {
            uint256 dt = block.timestamp - m.lastUpdate;
            m.accArthaPerPrincipal += (ratio * dt * ACC) / (RATIO_ONE * YEAR);
        }
        m.lastUpdate = block.timestamp;
    }

    /**
     * @dev Bank a position's accrued ARTHA to `_owner`, then re-checkpoint.
     *
     *  THE BANK-BEFORE-CHANGE RULE. This is the single most important pattern in
     *  the engine. Every caller must:
     *
     *      1. _settle(...)          <- bank at the OLD principal
     *      2. change the principal
     *      3. _recheckpoint(...)    <- re-mark at the NEW principal
     *
     *  Get the order wrong and you either pay the new rate on old time (theft
     *  from the pool) or wipe accrued rewards (theft from the user).
     *
     *  Idempotent: a second call in the same block banks zero, because
     *  `accumulated` will equal `rewardDebt`.
     *
     * @param _owner Who receives the banked ARTHA. The vault passes the CURRENT
     *               owner. On transfer, this is the OLD owner (settle first).
     */
    function _settle(address _vault, uint256 _tokenId, address _owner) internal returns (uint256 banked) {
        _updateAccumulator(_vault);

        VaultMeta storage m = vaultMeta[_vault];
        PositionAccount storage a = positionAccount[_vault][_tokenId];

        uint256 accumulated = (a.balanceNorm * m.accArthaPerPrincipal) / ACC;
        // acc is monotonically non-decreasing and balanceNorm only changes right
        // after a settle, so accumulated >= rewardDebt always. No underflow.
        uint256 pending = accumulated - a.rewardDebt;

        if (pending != 0 && _owner != address(0)) {
            // _credit is implemented by the Vault layer and is CAPPED. It may
            // return less than `pending` (or zero) if the pool is exhausted.
            uint256 credited = _credit(_vault, _tokenId, _owner, pending);
            m.totalArthaEarned += credited;
            banked = credited;
            emit Settled(_vault, _tokenId, _owner, credited);
        }

        // Always re-mark, even if the credit was capped short. Once the pool is
        // dry, accrual continues but pays nothing -- it does not queue up debt.
        a.rewardDebt = accumulated;
    }

    /// @dev Re-mark a position's checkpoint against the CURRENT accumulator.
    function _recheckpoint(address _vault, uint256 _tokenId) internal {
        PositionAccount storage a = positionAccount[_vault][_tokenId];
        a.rewardDebt = (a.balanceNorm * vaultMeta[_vault].accArthaPerPrincipal) / ACC;
    }

    /// @dev Track that this position exists, for syncAllPositions bounding.
    function _touchPosition(address _vault, uint256 _tokenId) internal {
        if (!vaultHasPosition[_vault][_tokenId]) {
            vaultHasPosition[_vault][_tokenId] = true;
            vaultPositions[_vault].push(_tokenId);
        }
    }

    /// @dev Track that `_user` owns this position, for claimAll bounding.
    function _linkUser(address _user, address _vault, uint256 _tokenId) internal {
        if (_user == address(0)) return;
        if (!userHasPosition[_user][_vault][_tokenId]) {
            userHasPosition[_user][_vault][_tokenId] = true;
            userPositions[_user].push(PositionRef({vault: _vault, tokenId: _tokenId}));
        }
    }

    // ═══════════════════════════ configuration ══════════════════════════════════

    /**
     * @notice Register a vault so it can report principal and accrue rewards.
     * @param _vault       The vault Diamond address.
     * @param _decimals    Base-token decimals (6 for USDC, 18 for WETH).
     * @param _rewardRatio Per-year rate, 0..1e18. Pass 0 to register a vault that
     *                     pays nothing (it can be switched on later).
     */
    function registerVault(address _vault, uint8 _decimals, uint256 _rewardRatio)
        external
        onlyRewardManager
    {
        require(_vault != address(0), "INVALID_VAULT");
        require(!vaultMeta[_vault].registered, "ALREADY_REGISTERED");
        require(_decimals <= 18, "DECIMALS_GT_18");
        require(_rewardRatio <= RATIO_ONE, "RATIO_GT_ONE");

        vaultMeta[_vault] = VaultMeta({
            registered: true,
            decimals: _decimals,
            rewardRatio: _rewardRatio,
            scale: 10 ** (18 - _decimals),
            accArthaPerPrincipal: 0,
            lastUpdate: block.timestamp,
            totalPrincipalNorm: 0,
            totalArthaEarned: 0,
            totalArthaClaimed: 0
        });

        unchecked {
            vaultCount += 1;
        }
        emit VaultRegistered(_vault, _decimals, _rewardRatio);
    }

    /**
     * @notice Change a vault's reward rate.
     *
     *  NON-RETROACTIVE: we advance the accumulator to `now` at the OLD rate
     *  BEFORE writing the new one. Everything earned up to this second is banked
     *  into the accumulator at the old rate; everything after accrues at the new
     *  one. Nobody is over- or under-paid, and no per-position loop is needed --
     *  the accumulator IS the record of "old rate until here, new rate after".
     *
     *  Setting `_newRatio = 0` is the clean OFF SWITCH (see _updateAccumulator).
     */
    function setRewardRatio(address _vault, uint256 _newRatio) external onlyRewardManager {
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");
        require(_newRatio <= RATIO_ONE, "RATIO_GT_ONE");

        _updateAccumulator(_vault); // bank the OLD rate up to NOW

        uint256 old = vaultMeta[_vault].rewardRatio;
        vaultMeta[_vault].rewardRatio = _newRatio;
        emit RewardRatioUpdated(_vault, old, _newRatio, block.timestamp);
    }

    /**
     * @notice Turn several vaults off in one call. The clean stop when the ARTHA
     *         budget is spent. Each is advanced at its old rate first, so no
     *         accrued reward is lost.
     */
    function stopAll(address[] calldata _vaults) external onlyRewardManager {
        for (uint256 i; i < _vaults.length; i++) {
            if (!vaultMeta[_vaults[i]].registered) continue;
            _updateAccumulator(_vaults[i]);
            uint256 old = vaultMeta[_vaults[i]].rewardRatio;
            vaultMeta[_vaults[i]].rewardRatio = 0;
            emit RewardRatioUpdated(_vaults[i], old, 0, block.timestamp);
        }
    }

    // ═══════════════════════════ hooks (vault only) ═════════════════════════════

    /**
     * @notice A deposit landed in `_tokenId`. Grow the POSITION's principal.
     *
     *  Called by the vault on EVERY deposit -- including when a third party
     *  deposits into someone else's position. The vault passes:
     *    - `_tokenId`: the position the money went into      <- principal key
     *    - `_owner`:   ownerOf(_tokenId) at this moment      <- who gets ARTHA
     *
     *  It does NOT pass the depositor, because the depositor is irrelevant. They
     *  made a gift; the position holds the capital; the owner can withdraw it.
     *
     * @param _rawPrincipal NET base token credited (after the vault's entry fee),
     *                      in raw token units (e.g. 6dp for USDC).
     */
    function notifyDeposit(address _vault, uint256 _tokenId, address _owner, uint256 _rawPrincipal)
        external
        onlyCaller(_vault)
        whenNotPaused
    {
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");
        if (_rawPrincipal == 0) return;

        // 1. BANK at the OLD principal, to the CURRENT owner
        _settle(_vault, _tokenId, _owner);

        // 2. CHANGE the principal -- on the POSITION
        uint256 addNorm = _rawPrincipal * vaultMeta[_vault].scale;
        PositionAccount storage a = positionAccount[_vault][_tokenId];
        a.balanceNorm += addNorm;
        vaultMeta[_vault].totalPrincipalNorm += addNorm;

        // 3. RE-CHECKPOINT at the new principal
        _recheckpoint(_vault, _tokenId);

        _touchPosition(_vault, _tokenId);
        _linkUser(_owner, _vault, _tokenId);

        emit PrincipalIncreased(_vault, _tokenId, _owner, _rawPrincipal, a.balanceNorm);
    }

    /**
     * @notice Principal left `_tokenId`. Shrink the POSITION's principal.
     *
     *  ┌──────────────────────────────────────────────────────────────────────┐
     *  │  THE VAULT MUST PASS `basisUsed`, NOT `assets`.                      │
     *  │                                                                      │
     *  │  Reward principal tracks DEPOSITED CAPITAL, not CURRENT VALUE. If a  │
     *  │  user withdraws 11,094 from a 9,970 cost basis, the reward principal │
     *  │  must drop by 9,970 -- what they actually put in.                    │
     *  │                                                                      │
     *  │  Passing `assets` (11,094) would drive principal negative on any     │
     *  │  profitable position. It clamps here, but the clamp is a symptom:    │
     *  │  the vault would be reporting the wrong number. This is the kind of  │
     *  │  bug that only appears after a bull run.                             │
     *  └──────────────────────────────────────────────────────────────────────┘
     *
     *  Because deposits and withdrawals hit the SAME (vault, tokenId) key, this
     *  can never underflow in correct operation: you cannot withdraw more basis
     *  from a position than was deposited into it. The clamp is belt-and-braces.
     *
     * @param _rawPrincipal The COST BASIS consumed by this withdrawal, raw units.
     */
    function notifyWithdraw(address _vault, uint256 _tokenId, address _owner, uint256 _rawPrincipal)
        external
        onlyCaller(_vault)
        whenNotPaused
    {
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");
        if (_rawPrincipal == 0) return;

        PositionAccount storage a = positionAccount[_vault][_tokenId];
        if (a.balanceNorm == 0) return;

        // 1. BANK at the OLD principal, to the CURRENT owner (who is withdrawing)
        _settle(_vault, _tokenId, _owner);

        // 2. CHANGE the principal
        uint256 decNorm = _rawPrincipal * vaultMeta[_vault].scale;
        if (decNorm > a.balanceNorm) decNorm = a.balanceNorm; // defensive clamp
        a.balanceNorm -= decNorm;
        vaultMeta[_vault].totalPrincipalNorm -= decNorm;

        // 3. RE-CHECKPOINT
        _recheckpoint(_vault, _tokenId);

        emit PrincipalDecreased(_vault, _tokenId, _owner, _rawPrincipal, a.balanceNorm);
    }

    /**
     * @notice The NFT changed hands. Settle to the OLD owner; the NEW owner
     *         accrues from now.
     *
     *  ┌──────────────────────────────────────────────────────────────────────┐
     *  │  PRINCIPAL DOES NOT MOVE. It is keyed by (vault, tokenId), and the    │
     *  │  tokenId did not change -- only its owner did. This is the single     │
     *  │  biggest simplification id-keying buys us: an address-keyed design    │
     *  │  would have to read the position's basis from the vault and move it   │
     *  │  between two address keys, banking BOTH sides. Here we bank one side  │
     *  │  and re-point the owner.                                             │
     *  │                                                                      │
     *  │  ALREADY-EARNED ARTHA STAYS WITH THE SELLER. It lives in `earned[]`   │
     *  │  in the Vault layer, keyed by user address. The buyer cannot touch    │
     *  │  it. `claimed[]` is likewise per-user, so there is no ambiguity about │
     *  │  who has claimed what -- the two users' ledgers never intersect.      │
     *  └──────────────────────────────────────────────────────────────────────┘
     *
     *  Sequence:
     *    1. settle(from)      -> banks every ARTHA the seller earned, to SELLER
     *    2. rewardDebt is now re-marked at the SAME principal
     *    3. buyer is linked to the position; from block N+1 all pending accrues
     *       to them, because the vault will pass `to` as `_owner` on the next hook
     *
     *  Mint (from == 0) and burn (to == 0) are both no-ops for accrual: a fresh
     *  position has zero principal, and a burned one has already been emptied by
     *  notifyWithdraw. We still link the new owner so claimAll() finds it.
     */
    function notifyTransfer(address _vault, uint256 _tokenId, address _from, address _to)
        external
        onlyCaller(_vault)
        whenNotPaused
    {
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");
        if (_from == _to) return;

        uint256 banked;
        if (_from != address(0)) {
            // Bank everything the SELLER earned, before the owner pointer moves.
            banked = _settle(_vault, _tokenId, _from);
        } else {
            // Mint: nothing to bank, but make sure the accumulator is current so
            // the new position's rewardDebt marks against an up-to-date acc.
            _updateAccumulator(_vault);
            _recheckpoint(_vault, _tokenId);
        }

        _linkUser(_to, _vault, _tokenId);
        emit PositionTransferred(_vault, _tokenId, _from, _to, banked);
    }

    // ═══════════════════════════ permissionless sync ════════════════════════════

    /**
     * @notice Bank one position's pending into claimable `earned`, without
     *         claiming. Anyone may call. Correctness never depends on this being
     *         called -- it is a convenience for UIs and accounting snapshots.
     * @param _owner The position's current owner. Callers should pass
     *               `IERC721(vault).ownerOf(tokenId)`.
     */
    function sync(address _vault, uint256 _tokenId, address _owner) public {
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");
        _settle(_vault, _tokenId, _owner);
    }

    /**
     * @notice Bank every position in a vault. Bounded by vaultPositions[vault].
     * @dev    O(n) over all positions ever created in the vault. Intended for
     *         off-chain/keeper use, not for a user tx. Provided for completeness.
     */
    function syncAllPositions(address _vault, address[] calldata _owners) external {
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");
        uint256[] storage ids = vaultPositions[_vault];
        require(_owners.length == ids.length, "OWNERS_LENGTH_MISMATCH");
        for (uint256 i; i < ids.length; i++) {
            _settle(_vault, ids[i], _owners[i]);
        }
    }

    // ═══════════════════════════ views ══════════════════════════════════════════

    /**
     * @notice Live pending (un-banked) ARTHA for one position.
     * @dev    Mirrors _settle's math WITHOUT writing. Must stay in sync with
     *         _updateAccumulator -- including the `rewardRatio == 0` guard.
     */
    function pendingReward(address _vault, uint256 _tokenId) public view returns (uint256) {
        VaultMeta storage m = vaultMeta[_vault];
        PositionAccount storage a = positionAccount[_vault][_tokenId];

        uint256 acc = m.accArthaPerPrincipal;
        if (block.timestamp > m.lastUpdate && m.rewardRatio != 0) {
            uint256 dt = block.timestamp - m.lastUpdate;
            acc += (m.rewardRatio * dt * ACC) / (RATIO_ONE * YEAR);
        }

        uint256 accumulated = (a.balanceNorm * acc) / ACC;
        return accumulated - a.rewardDebt;
    }

    /// @notice Total pending across every position `_user` currently owns.
    function pendingRewardAll(address _user) public view returns (uint256 total) {
        PositionRef[] storage list = userPositions[_user];
        for (uint256 i; i < list.length; i++) {
            total += pendingReward(list[i].vault, list[i].tokenId);
        }
    }

    /// @notice Convenience read of a vault's books.
    function vaultBooks(address _vault)
        external
        view
        returns (
            uint256 rewardRatio_,
            uint256 principalNorm,
            uint256 arthaEarned,
            uint256 arthaClaimed,
            uint256 arthaOutstanding
        )
    {
        VaultMeta storage m = vaultMeta[_vault];
        return (
            m.rewardRatio,
            m.totalPrincipalNorm,
            m.totalArthaEarned,
            m.totalArthaClaimed,
            m.totalArthaEarned - m.totalArthaClaimed
        );
    }

    /// @notice Live principal on a position, in raw base-token units.
    function positionPrincipalRaw(address _vault, uint256 _tokenId) external view returns (uint256) {
        return positionAccount[_vault][_tokenId].balanceNorm / vaultMeta[_vault].scale;
    }

    function vaultPositionsCount(address _vault) external view returns (uint256) {
        return vaultPositions[_vault].length;
    }

    function userPositionsCount(address _user) external view returns (uint256) {
        return userPositions[_user].length;
    }

    /// @notice Enumerate a user's positions (for UIs).
    function userPositionAt(address _user, uint256 _index)
        external
        view
        returns (address vault, uint256 tokenId)
    {
        PositionRef storage r = userPositions[_user][_index];
        return (r.vault, r.tokenId);
    }

    // ═══════════════════════════ money hook ═════════════════════════════════════

    /**
     * @dev Implemented by the Vault layer (UserRewardVault). Credits `_amount`
     *      ARTHA to `_owner`, CAPPED by the remaining pool. Returns the amount
     *      actually credited, which may be less than requested (or zero).
     *
     *      This is the ONLY seam between logic and money. The System never holds,
     *      transfers, or mints ARTHA -- it only decides who is owed what.
     */
    function _credit(address _vault, uint256 _tokenId, address _owner, uint256 _amount)
        internal
        virtual
        returns (uint256 credited);
}
