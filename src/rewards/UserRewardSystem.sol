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
 *   WORKED EXAMPLES -- READ THESE FIRST. THEY ARE THE WHOLE SPEC.
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Setup for every case: USDC vault, rewardRatio = 5e17 (50%/yr), YEAR = 360d.
 *  ARTHA for principal P over D days = 0.5 * P * D / 360.
 *
 *  ─────────────────────────────────────────────────────────────────────────
 *   CASE A -- TRANSFER *WITHOUT* REWARDS       (the DEFAULT: flag = false)
 *  ─────────────────────────────────────────────────────────────────────────
 *
 *    day 0     user-1 mints id-1, deposits 1,000 USDC
 *                positionAccount[V][1].balanceNorm = 1,000e18
 *
 *    day 90    user-1 transfers id-1 -> carol.  flag FALSE (never set).
 *                notifyTransfer(V, 1, user-1, carol)
 *                  -> _settle(V, 1, user-1)
 *                       banks 0.5 * 1,000 * 90/360 = 125 ARTHA to USER-1
 *                  -> flag false: the 125 STAYS with user-1
 *                  -> balanceNorm UNCHANGED at 1,000e18
 *                     (principal lives on the ID -- there is nothing to move)
 *                  -> carol is linked to the position
 *
 *    day 180   anyone syncs. _settle(V, 1, carol)
 *                banks 0.5 * 1,000 * 90/360 = 125 ARTHA to CAROL
 *
 *    RESULT    earned[user-1] = 125     <- theirs. carol can never touch it.
 *              earned[carol]  = 125     <- hers, from her own 90 days.
 *              user-1 may still call claimAll() and collect their 125.
 *
 *  ─────────────────────────────────────────────────────────────────────────
 *   CASE B -- TRANSFER *WITH* REWARDS          (flag = true, set beforehand)
 *  ─────────────────────────────────────────────────────────────────────────
 *
 *    day 0     user-1 mints id-1, deposits 1,000 USDC
 *
 *    day 89    user-1 calls setTransferRewardsOnExit(V, 1, true)
 *                transferRewardsOnExit[user-1][V][1] = true
 *                (their OWN transaction, ahead of time -- the vault never
 *                 passes a bool, exactly as specified)
 *
 *    day 90    user-1 transfers id-1 -> carol
 *                notifyTransfer(V, 1, user-1, carol)
 *                  -> _settle(V, 1, user-1) banks 125 to user-1
 *                  -> flag TRUE:
 *                       move positionEarnedForOwner[V][1][user-1] = 125
 *                       out of user-1's earned  ->  into CAROL's EARNED
 *                  -> it lands in `earned`, NOT pending, so carol can claim it
 *                     in the very next call. Correct: user-1 already took the
 *                     risk and already put in the time. That ARTHA is fully
 *                     EARNED, not still accruing -- pending is a function of
 *                     principal x time and cannot be written to directly.
 *                  -> the flag is CONSUMED (reset false)
 *
 *    day 180   _settle(V, 1, carol) banks another 125 to carol
 *
 *    RESULT    earned[user-1] = 0
 *              earned[carol]  = 250     <- the historical 125 + her own 125
 *
 *  ─────────────────────────────────────────────────────────────────────────
 *   CASE C -- user-2 GIFTS into user-1's position, THEN a flagged transfer
 *  ─────────────────────────────────────────────────────────────────────────
 *
 *    day 0     user-1 mints id-1, deposits 1,000 USDC
 *
 *    day 90    user-2 deposits 1,000 USDC into id-1   <- A GIFT to user-1.
 *                notifyDeposit(V, 1, owner=USER-1, 1,000)
 *                                     ^^^^^^^^^^^^ the OWNER, not user-2
 *                  -> _settle FIRST: banks 125 to USER-1
 *                  -> balanceNorm = 2,000e18
 *
 *                user-2 earns NOTHING. They made a gift; gifts do not earn.
 *                Nothing of user-2's is at risk here, so nothing of user-2's
 *                can strand. (This is the whole reason principal is id-keyed --
 *                see the section below.)
 *
 *    day 180   user-1 sets the flag, transfers id-1 -> carol
 *                  -> _settle banks 0.5 * 2,000 * 90/360 = 250 more to user-1
 *                     (on the FULL 2,000 -- the gift is part of the position)
 *                  -> positionEarnedForOwner[V][1][user-1] = 125 + 250 = 375
 *                  -> flag TRUE: all 375 moves to CAROL's earned
 *
 *    RESULT    earned[user-1] = 0
 *              earned[user-2] = 0        <- the gifter never earns
 *              earned[carol]  = 375
 *              carol owns id-1 holding 2,000 principal
 *
 *  ─────────────────────────────────────────────────────────────────────────
 *   CASE D -- THE HOLE THE FLAG CANNOT CLOSE. READ BEFORE TRUSTING IT.
 *  ─────────────────────────────────────────────────────────────────────────
 *
 *    day 90    mallory has 125 banked on id-1 and sets the flag TRUE.
 *              She lists id-1: "NFT + 125 ARTHA included". A buyer pays.
 *
 *              SAME BLOCK, front-running the transfer, mallory calls
 *                  claimAll(mallory)     -> the 125 leaves the contract
 *
 *              Then the transfer executes. The flag fires, looks for mallory's
 *              banked balance, finds ZERO, and moves ZERO.
 *
 *    RESULT    the buyer paid for 125 ARTHA and received none.
 *
 *              ┌──────────────────────────────────────────────────────────┐
 *              │  THE FLAG IS A GIFT INSTRUCTION, NOT AN ESCROW.          │
 *              │                                                          │
 *              │  A seller can always drain their own banked balance in   │
 *              │  the same block. No on-chain flag can prevent that --    │
 *              │  the balance is theirs until the instant it is not.      │
 *              │                                                          │
 *              │  A marketplace buyer MUST price the NFT at               │
 *              │  `shares x pps` and treat any ARTHA as a bonus that may  │
 *              │  not arrive -- or use an atomic bundle / escrow that     │
 *              │  checks claimableBanked(seller) in the same transaction. │
 *              └──────────────────────────────────────────────────────────┘
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY PRINCIPAL IS KEYED BY (VAULT, POSITION ID) AND *NOT* BY USER ADDRESS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  This is THE design decision in this contract, and Case C is why.
 *
 *  The Artha vault allows ANYONE to deposit into ANY position, but only the
 *  position's OWNER may withdraw. That asymmetry breaks address-keyed
 *  accounting. The exact failure:
 *
 *    day 0    user-1 deposits 1,000 into id-1.
 *    day 90   user-2 deposits 1,000 into id-1.
 *    day 180  user-1 (the OWNER) withdraws the full 2,000.
 *
 *  ── ADDRESS-KEYED, crediting the DEPOSITOR ────────────────────────────────
 *      principal[user-1] = 1,000        principal[user-2] = 1,000
 *
 *      user-1 withdraws 2,000. Subtract it from... whom?
 *        - principal[user-1] is only 1,000  ->  UNDERFLOW. Clamp to 0.
 *        - principal[user-2] is still 1,000 ->  user-2 keeps accruing ARTHA
 *                                               on capital that HAS LEFT THE
 *                                               VAULT. Phantom principal.
 *
 *      The vault holds 0. The system thinks 1,000 is still earning. The pool
 *      bleeds forever, to someone with nothing at risk. THIS IS THE BUG.
 *
 *  ── ID-KEYED (this contract) ──────────────────────────────────────────────
 *      positionAccount[V][id-1].balanceNorm = 2,000
 *
 *      user-1 withdraws 2,000 -> balanceNorm = 0. Closes EXACTLY.
 *
 *          ┌────────────────────────────────────────────────────────────┐
 *          │  DEPOSIT credits (vault, id).                              │
 *          │  WITHDRAW debits (vault, id).                              │
 *          │  SAME KEY. ALWAYS. Regardless of who called either one.    │
 *          │                                                            │
 *          │  => balanceNorm can NEVER underflow and NEVER strand,      │
 *          │     because it is impossible to withdraw more from a       │
 *          │     position than was deposited into it.                   │
 *          └────────────────────────────────────────────────────────────┘
 *
 *  ┌──────────────────────────────────────────────────────────────────────────┐
 *  │  ON "SUBTRACT PRINCIPAL FROM THE OLD OWNER, ADD IT TO THE NEW OWNER".    │
 *  │                                                                          │
 *  │  There is no per-address principal balance to subtract from. The old      │
 *  │  owner never had one -- the POSITION holds the principal. Adding          │
 *  │  authoritative per-address mirrors and moving them on transfer would      │
 *  │  re-create the exact phantom bug above: deposit credits                   │
 *  │  owner-at-deposit-time, withdraw debits owner-at-withdraw-time, and the   │
 *  │  two disagree the moment ownership changes in between.                    │
 *  │                                                                          │
 *  │  The ATTRIBUTION does move, which is what actually matters: after the     │
 *  │  transfer the vault passes the NEW owner on every hook, so the new owner  │
 *  │  earns on that principal and the old owner does not. That is automatic    │
 *  │  and needs no bookkeeping.                                                │
 *  │                                                                          │
 *  │  Per-user principal totals are exposed as DERIVED VIEWS                   │
 *  │  (userPrincipalNorm / userPrincipalNormInVault) that sum the positions    │
 *  │  the user is linked to. Always exact, impossible to desync.               │
 *  └──────────────────────────────────────────────────────────────────────────┘
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE ACCUMULATOR
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *      acc          += rewardRatio * dt * ACC / (RATIO_ONE * YEAR)
 *      accumulated   = balanceNorm * acc / ACC
 *      pending       = accumulated - rewardDebt
 *
 *  Caller sites (msg.sender must be an approved caller AND equal `vault`):
 *     - deposit  -> notifyDeposit(vault, tokenId, owner, rawPrincipal)
 *     - withdraw -> notifyWithdraw(vault, tokenId, owner, basisUsed)
 *     - transfer -> notifyTransfer(vault, tokenId, from, to)
 *
 *  Anyone may sync() to bank a position's pending into claimable `earned`
 *  without claiming. Ratio changes are non-retroactive and never overpay, so
 *  correctness never depends on who (if anyone) calls sync.
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
     * @param registered           whether the vault is active
     * @param decimals             base-token decimals
     * @param rewardRatio          per-vault rate (0..1e18). ZERO => NO REWARDS.
     * @param scale                10^(18 - decimals), normalises principal to 18dp
     * @param accArthaPerPrincipal MasterChef accumulator, scaled by ACC
     * @param lastUpdate           timestamp the accumulator last advanced
     * @param totalPrincipalNorm   LIVE principal across all positions, 18dp
     * @param totalDepositedRaw    LIFETIME principal ever deposited, raw units
     * @param totalWithdrawnRaw    LIFETIME principal ever withdrawn, raw units
     * @param totalArthaEarned     cumulative ARTHA credited for this vault
     * @param totalArthaClaimed    cumulative ARTHA claimed from this vault
     */
    struct VaultMeta {
        bool registered;
        uint8 decimals;
        uint256 rewardRatio;
        uint256 scale;
        uint256 accArthaPerPrincipal;
        uint256 lastUpdate;
        uint256 totalPrincipalNorm;
        uint256 totalDepositedRaw;
        uint256 totalWithdrawnRaw;
        uint256 totalArthaEarned;
        uint256 totalArthaClaimed;
    }

    /**
     * @param balanceNorm  LIVE principal for this (vault, tokenId), 18dp
     * @param rewardDebt   checkpoint = balanceNorm * acc / ACC at last settle
     * @param depositedRaw LIFETIME principal ever deposited here, raw units
     * @param withdrawnRaw LIFETIME principal ever withdrawn here, raw units
     *
     *  INVARIANT: balanceNorm == (depositedRaw - withdrawnRaw) * scale
     *
     *  The lifetime counters are monotonic. They answer "how much has EVER gone
     *  in / out of this position", which balanceNorm alone cannot: a position at
     *  zero looks identical whether it never held anything or cycled a million
     *  through and closed.
     */
    struct PositionAccount {
        uint256 balanceNorm;
        uint256 rewardDebt;
        uint256 depositedRaw;
        uint256 withdrawnRaw;
    }

    mapping(address => VaultMeta) public vaultMeta;
    uint64 public vaultCount;

    /// @notice vault => tokenId => accrual state. THE CORE MAPPING.
    mapping(address => mapping(uint256 => PositionAccount)) public positionAccount;

    // ────────────────── the opt-in transfer flag (Cases A / B) ──────────────────

    /**
     * @notice user => vault => tokenId => "when I transfer this position, hand my
     *         banked ARTHA from it to the new owner too".
     *
     *  Set by the OWNER, in their OWN transaction, BEFORE they transfer. The
     *  vault passes no bool on the hook -- we read this standing instruction.
     *  The flag is CONSUMED when it fires, so it can never trigger twice or
     *  linger onto a future re-acquisition of the same tokenId.
     *
     *  Default FALSE: transferring an NFT does NOT give away your ARTHA. That is
     *  the safe default -- ARTHA you earned by putting your own capital at risk
     *  for your own time is yours. Selling the position does not unearn it, just
     *  as selling a stock does not claw back a dividend already paid.
     *
     *  SEE CASE D at the top. This is a gift instruction, not an escrow.
     */
    mapping(address => mapping(address => mapping(uint256 => bool))) public transferRewardsOnExit;

    /**
     * @notice vault => tokenId => owner => ARTHA this position has banked FOR
     *         THAT SPECIFIC OWNER since they acquired it.
     *
     *  This is the number the flag moves, and it has to be this precise:
     *
     *  Why not `totalEarned[user]`? It aggregates every vault and every position
     *  they hold. Moving it would hand the buyer ARTHA from positions the seller
     *  is KEEPING:
     *      user-1 holds id-1 (selling, produced 375), id-7 (keeping, 900),
     *      and a WETH position (keeping, 200).
     *          totalEarned[user-1]                  = 1,475   <- WRONG to move
     *          positionEarnedForOwner[V][1][user-1] =   375   <- RIGHT to move
     *
     *  Why not a lifetime per-position total? Because it would span owners. If
     *  carol later sells to dave with the flag on, dave would receive user-1's
     *  era too. Keying by owner keeps each era separate.
     *
     *  Zeroed for the old owner when the flag fires.
     */
    mapping(address => mapping(uint256 => mapping(address => uint256))) public positionEarnedForOwner;

    // ─────────────────────────── per-position footprint ─────────────────────────

    /// @notice vault => list of tokenIds that have ever held principal.
    /// @dev    Append-only. Bounds syncAllPositions(vault).
    mapping(address => uint256[]) public vaultPositions;
    mapping(address => mapping(uint256 => bool)) public vaultHasPosition;

    // ─────────────────────────── per-user footprint ─────────────────────────────

    /**
     * @notice user => list of (vault, tokenId) pairs they are linked to.
     *
     *  Lets claimAll() settle everything in one tx. Maintained on notifyDeposit
     *  (links the owner) and notifyTransfer (links the buyer). Entries are NOT
     *  removed -- a position you no longer own settles to zero pending for you,
     *  which is harmless, and removal would cost an O(n) array shuffle.
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
    event PositionTransferred(address indexed vault, uint256 indexed tokenId, address indexed from, address to, uint256 bankedToFrom, uint256 arthaMoved);
    event Settled(address indexed vault, uint256 indexed tokenId, address indexed owner, uint256 amount);
    event TransferRewardsOnExitSet(address indexed owner, address indexed vault, uint256 indexed tokenId, bool enabled);

    // ─────────────────────────── constructor ────────────────────────────────────

    constructor(address _rewardManager) UserRewardManager(_rewardManager) {}

    // ═══════════════════ the opt-in flag (owner sets it themselves) ═════════════

    /**
     * @notice Declare that when you transfer this position, the ARTHA it banked
     *         for you goes to the new owner as well.
     *
     *  CASE A (leave false, the default): you transfer the NFT, you keep your
     *    ARTHA. The buyer starts earning from their block 1.
     *
     *  CASE B (set true): you transfer the NFT, and the ARTHA this position
     *    banked for you moves into the buyer's `earned` -- immediately
     *    claimable by them, because it is already earned, not still accruing.
     *
     *  You call this yourself, ahead of the transfer. The vault never passes a
     *  bool; it just reports the transfer, and we read your standing instruction.
     *
     *  Consumed when it fires. Re-acquiring the position later means setting it
     *  again if you want the same behaviour.
     *
     *  READ CASE D at the top of this file before relying on this in a trade.
     */
    function setTransferRewardsOnExit(address _vault, uint256 _tokenId, bool _enabled) external {
        transferRewardsOnExit[msg.sender][_vault][_tokenId] = _enabled;
        emit TransferRewardsOnExitSet(msg.sender, _vault, _tokenId, _enabled);
    }

    // ═══════════════════════════ accrual core ═══════════════════════════════════

    /**
     * @dev Advance a vault's accumulator to `block.timestamp`.
     *
     *  ┌──────────────────────────────────────────────────────────────────────┐
     *  │  rewardRatio == 0  =>  NOTHING ACCRUES.                              │
     *  │                                                                      │
     *  │  The `if (ratio != 0)` guard is not strictly necessary -- multiplying │
     *  │  by zero adds zero anyway. We keep it because it saves the           │
     *  │  arithmetic and documents that ZERO IS THE OFF SWITCH.               │
     *  │                                                                      │
     *  │  lastUpdate still advances, so turning the ratio back on does NOT    │
     *  │  retroactively pay for the dark period. That is deliberate.          │
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
     *  THE BANK-BEFORE-CHANGE RULE. The single most important pattern here.
     *  Every caller must:
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
     *               owner. On transfer this is the OLD owner -- settle first.
     */
    function _settle(address _vault, uint256 _tokenId, address _owner)
        internal
        returns (uint256 banked)
    {
        _updateAccumulator(_vault);

        VaultMeta storage m = vaultMeta[_vault];
        PositionAccount storage a = positionAccount[_vault][_tokenId];

        uint256 accumulated = (a.balanceNorm * m.accArthaPerPrincipal) / ACC;
        // acc is monotonically non-decreasing and balanceNorm only changes right
        // after a settle, so accumulated >= rewardDebt always. No underflow.
        uint256 pending = accumulated - a.rewardDebt;

        if (pending != 0 && _owner != address(0)) {
            // _credit lives in the Vault layer and is CAPPED. It may return less
            // than `pending` (or zero) once the pool is exhausted.
            uint256 credited = _credit(_vault, _tokenId, _owner, pending);
            m.totalArthaEarned += credited;
            positionEarnedForOwner[_vault][_tokenId][_owner] += credited;
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

    /// @dev Link `_user` to this position, for claimAll bounding.
    function _linkUser(address _user, address _vault, uint256 _tokenId) internal {
        if (_user == address(0)) return;
        if (!userHasPosition[_user][_vault][_tokenId]) {
            userHasPosition[_user][_vault][_tokenId] = true;
            userPositions[_user].push(PositionRef({vault: _vault, tokenId: _tokenId}));
        }
    }

    /// @dev Settle every position `_user` is linked to. Used before reading their
    ///      banked balance, so `earned` is exact.
    function _settleUserPositions(address _user) internal {
        PositionRef[] storage list = userPositions[_user];
        for (uint256 i; i < list.length; i++) {
            _settle(list[i].vault, list[i].tokenId, _user);
        }
    }

    /// @dev Settle every position `_user` is linked to WITHIN one vault.
    function _settleUserPositionsInVault(address _user, address _vault) internal {
        PositionRef[] storage list = userPositions[_user];
        for (uint256 i; i < list.length; i++) {
            if (list[i].vault == _vault) _settle(_vault, list[i].tokenId, _user);
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
            totalDepositedRaw: 0,
            totalWithdrawnRaw: 0,
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
     *  BEFORE writing the new one. Everything up to this second is banked at the
     *  old rate; everything after accrues at the new one. Nobody is over- or
     *  under-paid, and no per-position loop is needed -- the accumulator IS the
     *  record of "old rate until here, new rate after".
     *
     *  `_newRatio = 0` is the clean OFF SWITCH (see _updateAccumulator).
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
     *  Called on EVERY deposit -- including when a third party deposits into
     *  someone else's position (CASE C). The vault passes:
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
        VaultMeta storage m = vaultMeta[_vault];
        uint256 addNorm = _rawPrincipal * m.scale;
        PositionAccount storage a = positionAccount[_vault][_tokenId];
        a.balanceNorm += addNorm;
        a.depositedRaw += _rawPrincipal; // lifetime counter
        m.totalPrincipalNorm += addNorm;
        m.totalDepositedRaw += _rawPrincipal;

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
     *  │  profitable position. It clamps below, but the clamp is a symptom:   │
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
        VaultMeta storage m = vaultMeta[_vault];
        uint256 decNorm = _rawPrincipal * m.scale;
        if (decNorm > a.balanceNorm) decNorm = a.balanceNorm; // defensive clamp
        uint256 decRaw = decNorm / m.scale;

        a.balanceNorm -= decNorm;
        a.withdrawnRaw += decRaw; // lifetime counter, post-clamp
        m.totalPrincipalNorm -= decNorm;
        m.totalWithdrawnRaw += decRaw;

        // 3. RE-CHECKPOINT
        _recheckpoint(_vault, _tokenId);

        emit PrincipalDecreased(_vault, _tokenId, _owner, decRaw, a.balanceNorm);
    }

    /**
     * @notice The NFT changed hands. Settle to the OLD owner, then honour their
     *         standing instruction about the ARTHA.
     *
     *  ── WHAT ALWAYS HAPPENS ──────────────────────────────────────────────
     *    _settle(from) runs unconditionally. It converts the seller's PENDING
     *    into their banked `earned`, at the rate their capital actually earned
     *    over the time they actually held it. Not optional: without it the buyer
     *    would inherit un-banked pending that the SELLER earned.
     *
     *  ── WHAT THE FLAG DECIDES ────────────────────────────────────────────
     *    CASE A  flag false (default): the banked ARTHA STAYS with the seller.
     *    CASE B  flag true:            it MOVES into the buyer's `earned`,
     *                                  immediately claimable.
     *
     *    We move `positionEarnedForOwner[vault][tokenId][from]` -- what THIS
     *    position banked for THIS seller -- never their global `earned`, which
     *    would leak ARTHA from positions they are keeping.
     *
     *  ── WHAT NEVER HAPPENS ───────────────────────────────────────────────
     *    Principal does not move. It is keyed by (vault, tokenId) and the
     *    tokenId did not change -- only its owner did. The new owner earns on it
     *    from now, because the vault passes `to` as `_owner` on the next hook.
     *    See the note at the top on why per-address principal mirrors would
     *    re-introduce the phantom bug.
     *
     *  Mint (from == 0) and burn (to == 0) are accrual no-ops: a fresh position
     *  has zero principal, and a burned one was already emptied by
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
        uint256 movedAmt;

        if (_from != address(0)) {
            // ALWAYS bank the seller's pending: their rate, their time.
            banked = _settle(_vault, _tokenId, _from);

            // Then read their standing instruction (CASE A vs CASE B).
            if (transferRewardsOnExit[_from][_vault][_tokenId] && _to != address(0)) {
                movedAmt = _moveEarned(_vault, _tokenId, _from, _to);
                // consume the flag: fires once, never lingers
                transferRewardsOnExit[_from][_vault][_tokenId] = false;
                emit TransferRewardsOnExitSet(_from, _vault, _tokenId, false);
            }
        } else {
            // Mint: nothing to bank, but keep the accumulator current so the new
            // position's rewardDebt marks against an up-to-date acc.
            _updateAccumulator(_vault);
            _recheckpoint(_vault, _tokenId);
        }

        _linkUser(_to, _vault, _tokenId);
        emit PositionTransferred(_vault, _tokenId, _from, _to, banked, movedAmt);
    }

    // ═══════════════════════════ permissionless sync ════════════════════════════

    /**
     * @notice Bank one position's pending into claimable `earned`, without
     *         claiming. ANYONE may call.
     *
     *  This is the "sync before you transfer" path: an owner who wants their
     *  ARTHA crystallised before selling calls this, then transfers. (Belt-and-
     *  braces -- notifyTransfer settles anyway.)
     *
     *  Correctness never depends on this being called.
     *
     * @param _owner The position's current owner. Callers should pass
     *               `IERC721(vault).ownerOf(tokenId)`.
     */
    function sync(address _vault, uint256 _tokenId, address _owner) public {
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");
        _settle(_vault, _tokenId, _owner);
    }

    /// @notice Bank every position `_user` is linked to, across every vault.
    function syncUser(address _user) external {
        _settleUserPositions(_user);
    }

    /// @notice Bank every position `_user` is linked to within ONE vault.
    function syncUserInVault(address _user, address _vault) external {
        require(vaultMeta[_vault].registered, "NOT_REGISTERED");
        _settleUserPositionsInVault(_user, _vault);
    }

    /**
     * @notice Bank every position in a vault. Bounded by vaultPositions[vault].
     * @dev    O(n) over all positions ever created in the vault. For keeper /
     *         off-chain use, not a user tx. `_owners` must be supplied in the
     *         same order as `vaultPositions[_vault]`.
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
     * @dev    Mirrors _settle's math WITHOUT writing. Must stay in step with
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

    /// @notice Total pending across every position `_user` is linked to.
    function pendingRewardAll(address _user) public view returns (uint256 total) {
        PositionRef[] storage list = userPositions[_user];
        for (uint256 i; i < list.length; i++) {
            total += pendingReward(list[i].vault, list[i].tokenId);
        }
    }

    /// @notice Total pending for `_user` within ONE vault.
    function pendingRewardInVault(address _user, address _vault)
        public
        view
        returns (uint256 total)
    {
        PositionRef[] storage list = userPositions[_user];
        for (uint256 i; i < list.length; i++) {
            if (list[i].vault == _vault) total += pendingReward(_vault, list[i].tokenId);
        }
    }

    /**
     * @notice Everything about one vault's books.
     * @return rewardRatio_     per-year rate, 0..1e18
     * @return principalNorm    LIVE principal across all positions, 18dp
     * @return depositedRaw     LIFETIME principal ever deposited
     * @return withdrawnRaw     LIFETIME principal ever withdrawn
     * @return arthaEarned      cumulative ARTHA credited
     * @return arthaClaimed     cumulative ARTHA claimed
     * @return arthaOutstanding earned - claimed
     */
    function vaultBooks(address _vault)
        external
        view
        returns (
            uint256 rewardRatio_,
            uint256 principalNorm,
            uint256 depositedRaw,
            uint256 withdrawnRaw,
            uint256 arthaEarned,
            uint256 arthaClaimed,
            uint256 arthaOutstanding
        )
    {
        VaultMeta storage m = vaultMeta[_vault];
        return (
            m.rewardRatio,
            m.totalPrincipalNorm,
            m.totalDepositedRaw,
            m.totalWithdrawnRaw,
            m.totalArthaEarned,
            m.totalArthaClaimed,
            m.totalArthaEarned - m.totalArthaClaimed
        );
    }

    /// @notice LIVE principal on a position, in raw base-token units.
    function positionPrincipalRaw(address _vault, uint256 _tokenId) public view returns (uint256) {
        uint256 scale = vaultMeta[_vault].scale;
        return scale == 0 ? 0 : positionAccount[_vault][_tokenId].balanceNorm / scale;
    }

    /**
     * @notice Everything about one position's PRINCIPAL.
     * @return livePrincipalRaw  currently invested, raw base units
     * @return livePrincipalNorm currently invested, 18dp
     * @return depositedRaw      LIFETIME ever deposited into this position
     * @return withdrawnRaw      LIFETIME ever withdrawn from this position
     * @return pendingArtha      un-banked ARTHA accruing on it right now
     */
    function positionBooks(address _vault, uint256 _tokenId)
        external
        view
        returns (
            uint256 livePrincipalRaw,
            uint256 livePrincipalNorm,
            uint256 depositedRaw,
            uint256 withdrawnRaw,
            uint256 pendingArtha
        )
    {
        PositionAccount storage a = positionAccount[_vault][_tokenId];
        return (
            positionPrincipalRaw(_vault, _tokenId),
            a.balanceNorm,
            a.depositedRaw,
            a.withdrawnRaw,
            pendingReward(_vault, _tokenId)
        );
    }

    /**
     * @notice Total LIVE principal across every position `_user` is linked to, 18dp.
     * @dev    DERIVED, not stored. Sums the positions -- always exact, can never
     *         desync from the authoritative id-keyed balances. See the note at the
     *         top of this file on why this is a view and not state.
     */
    function userPrincipalNorm(address _user) public view returns (uint256 total) {
        PositionRef[] storage list = userPositions[_user];
        for (uint256 i; i < list.length; i++) {
            total += positionAccount[list[i].vault][list[i].tokenId].balanceNorm;
        }
    }

    /// @notice Total LIVE principal `_user` holds in ONE vault, 18dp. Derived.
    function userPrincipalNormInVault(address _user, address _vault)
        public
        view
        returns (uint256 total)
    {
        PositionRef[] storage list = userPositions[_user];
        for (uint256 i; i < list.length; i++) {
            if (list[i].vault == _vault) {
                total += positionAccount[_vault][list[i].tokenId].balanceNorm;
            }
        }
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

    // ═══════════════════════════ money hooks ════════════════════════════════════

    /**
     * @dev Implemented by the Vault layer. Credits `_amount` ARTHA to `_owner`,
     *      CAPPED by the remaining pool. Returns what was actually credited,
     *      which may be less than requested (or zero).
     *
     *      This is the ONLY seam between logic and money. The System never holds,
     *      transfers, or mints ARTHA -- it only decides who is owed what.
     */
    function _credit(address _vault, uint256 _tokenId, address _owner, uint256 _amount)
        internal
        virtual
        returns (uint256 credited);

    /**
     * @dev Implemented by the Vault layer. Moves the ARTHA this position banked
     *      for `_from` into `_to`'s `earned` (CASE B). Returns the amount moved.
     */
    function _moveEarned(address _vault, uint256 _tokenId, address _from, address _to)
        internal
        virtual
        returns (uint256 moved);
}
