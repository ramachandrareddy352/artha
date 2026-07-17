// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ReferralVaultManager.sol";

/**
 * @title  ReferralSystem
 * @notice The referral REGISTRY layer. It knows "who owns each code", "which TIER
 *         each code sits in", "which code each TRADER bound", and "how much of his
 *         commission each code owner rebates". It holds no money.
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault
 *
 *   CODES ARE CREATED AND TRANSFERRED BY THE ADMIN ONLY
 *
 *  The protocol hands codes to active participants. Users cannot self-generate
 *  codes, so nobody can mint a code and refer their own second wallet. (The vault
 *  layer also blocks owner == trader as defense-in-depth.)
 *
 *  Transfer is TWO steps. The current owner nominates a successor with
 *  approveTransfer(); the admin then executes it with executeTransfer(). Neither
 *  side can move a code alone: the admin cannot seize one from an owner who never
 *  nominated, and a stolen owner key cannot pull the code out without the admin
 *  also signing off. Codes carry unclaimed base and ARTHA, so the book moves with
 *  them as a going concern -- the code is sold or handed over whole.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   TRADER => CODE, BOUND ONCE
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  A trader binds ONE code, once, with setTraderCode(). It cannot be changed while
 *  that code is alive -- otherwise a trader could shop for whichever code currently
 *  offers the fattest discount right before a big withdrawal, or park under code A
 *  and re-point to code B they also control the moment B gets promoted.
 *
 *  The ONE exception: if the bound code is later DEACTIVATED, the trader is freed
 *  and may bind a new one. `activeTraderCode()` returns 0 for a trader whose code
 *  is dead, so the vault treats them as unreferred until they rebind -- 100% of the
 *  performance fee goes to the protocol in the meantime.
 *
 *  TIERS.
 *  Every code carries a tier (1..MAX_TIERS). The tier does NOT change the math
 *  here; it only records the code's rank. The TOP layer (ReferralVault) maps each
 *  (vault, tier) to a reward ratio and uses it in the split. New codes start at
 *  tier 1. The admin promotes a code with ReferralVault.setCodeTier() as its
 *  referral performance grows -- a higher tier takes a larger share of the
 *  performance fee. Because nothing accrues over time, promotion needs no
 *  settlement dance: it simply applies from the next fee onward.
 *
 *  DISCOUNTS.
 *  Each code owner may rebate part of HIS OWN commission back to the traders using
 *  his code, via setCodeDiscount(). 1_000 = 1%, 100_000 = 100%. This is the owner's
 *  own competitive lever and costs the protocol nothing -- the protocol's share is
 *  computed BEFORE the discount is applied, and ARTHA is priced on the owner's
 *  GROSS commission, so rebating does not shrink his ARTHA.
 */
contract ReferralSystem is ReferralVaultManager {
    /// @notice 100_000 = 100%, 1_000 = 1%.
    uint32 public constant RATIO_ONE = 100_000;

    /// @notice Highest assignable tier id.
    uint8 public constant MAX_TIERS = 8;

    /// @notice code => current owner (address(0) means "no code / deactivated").
    mapping(uint64 => address) public codeOwner;

    /// @notice owner => the one code they hold (reverse lookup).
    mapping(address => uint64) public ownerToCode;

    /// @notice code => tier (1..MAX_TIERS). New codes default to tier 1.
    mapping(uint64 => uint8) public codeTier;

    /// @notice code => share of the OWNER's commission rebated to the trader.
    ///         1_000 = 1%. Set by the code owner, default 0.
    mapping(uint64 => uint32) public codeDiscount;

    /// @notice trader => bound code. Set once; re-settable only if the code dies.
    mapping(address => uint64) public traderCode;

    /// @notice code => the owner-approved incoming owner (pending transfer target).
    mapping(uint64 => address) public pendingCodeOwner;

    event CodeCreated(uint64 indexed code, address owner, uint8 tier);
    event CodeTransferred(uint64 indexed code, address oldOwner, address newOwner);
    event TransferApproved(uint64 indexed code, address currentOwner, address proposedOwner);
    event TransferApprovalRevoked(uint64 indexed code, address currentOwner);
    event CodeDeactivated(uint64 indexed code, address owner);
    event CodeTierSet(uint64 indexed code, uint8 oldTier, uint8 newTier);
    event CodeDiscountSet(uint64 indexed code, uint32 oldDiscountBps, uint32 newDiscountBps);
    event TraderCodeSet(uint64 indexed code, address trader);

    constructor(address _admin) ReferralVaultManager(_admin) {}

    // ─────────────────────────────── views ──────────────────────────────────────

    /// @notice True when the code exists and has not been deactivated.
    function isCodeActive(uint64 _code) public view returns (bool) {
        return _code != uint64(0) && codeOwner[_code] != address(0);
    }

    /**
     * @notice The code a trader will actually be credited under.
     * @dev    Returns 0 when the trader never bound one, OR when the code they
     *         bound has since been deactivated. The vault reads THIS, not the raw
     *         mapping, so a dead code silently degrades to "unreferred" (the whole
     *         performance fee goes to the protocol) instead of reverting a withdraw.
     */
    function activeTraderCode(address _trader) public view returns (uint64) {
        uint64 code = traderCode[_trader];
        return isCodeActive(code) ? code : uint64(0);
    }

    /// @notice The address the code's owner has approved to receive it (0 if none).
    function pendingTransferOf(uint64 _code) external view returns (address) {
        return pendingCodeOwner[_code];
    }

    // ────────────────────────── trader / owner actions ──────────────────────────

    /**
     * @notice Bind a referral code to msg.sender. ONCE ONLY.
     * @dev    Re-binding is allowed only if the previously bound code has been
     *         deactivated -- see the contract comment for why it is otherwise locked.
     */
    function setTraderCode(uint64 _code) external whenNotPaused {
        require(isCodeActive(_code), "CODE_NOT_ACTIVE");
        require(codeOwner[_code] != msg.sender, "SELF_REFERRAL");

        uint64 existing = traderCode[msg.sender];
        // The only way out of an existing binding is for that code to be dead.
        require(!isCodeActive(existing), "CODE_ALREADY_SET");

        traderCode[msg.sender] = _code;
        emit TraderCodeSet(_code, msg.sender);
    }

    /**
     * @notice The code owner sets what share of HIS commission is rebated to the
     *         traders using his code. 1_000 = 1%, 100_000 = 100% (gives it all away).
     */
    function setCodeDiscount(uint64 _code, uint32 _discount) external {
        require(codeOwner[_code] == msg.sender, "NOT_CODE_OWNER");
        require(_discount <= RATIO_ONE, "DISCOUNT_GT_ONE");

        uint32 old = codeDiscount[_code];
        codeDiscount[_code] = _discount;
        emit CodeDiscountSet(_code, old, _discount);
    }

    /**
     * @notice Step 1 — the CURRENT code owner nominates who may receive the code.
     * @dev    Nomination alone moves nothing. The admin must still execute step 2,
     *         so a phished or coerced owner signature is not sufficient on its own
     *         to move a code and its unclaimed book.
     */
    function approveTransfer(uint64 _code, address _proposedOwner) external {
        require(codeOwner[_code] == msg.sender, "NOT_CODE_OWNER");
        require(_proposedOwner != address(0), "INVALID_ADDRESS");
        require(_proposedOwner != msg.sender, "ALREADY_OWNER");
        require(ownerToCode[_proposedOwner] == uint64(0), "NEW_OWNER_HAS_CODE");

        pendingCodeOwner[_code] = _proposedOwner;
        emit TransferApproved(_code, msg.sender, _proposedOwner);
    }

    /// @notice The owner cancels a pending nomination before the admin executes it.
    function revokeTransferApproval(uint64 _code) external {
        require(codeOwner[_code] == msg.sender, "NOT_CODE_OWNER");
        require(pendingCodeOwner[_code] != address(0), "NO_PENDING_TRANSFER");

        delete pendingCodeOwner[_code];
        emit TransferApprovalRevoked(_code, msg.sender);
    }

    // ─────────────────────────────── admin ──────────────────────────────────────

    /// @notice Create a code and assign it to an owner at tier 1. ADMIN ONLY.
    function createCode(uint64 _code, address _owner) external onlyReferralVaultManager {
        require(_code != uint64(0), "INVALID_CODE");
        require(_owner != address(0), "INVALID_OWNER");
        require(codeOwner[_code] == address(0), "CODE_EXISTS");
        require(ownerToCode[_owner] == uint64(0), "OWNER_HAS_CODE");

        codeOwner[_code] = _owner;
        ownerToCode[_owner] = _code;
        codeTier[_code] = 1; // everyone starts at tier 1
        emit CodeCreated(_code, _owner, 1);
    }

    /**
     * @notice Step 2 — the ADMIN executes a transfer the owner already nominated.
     *         Both parties must act: the owner nominates, the admin confirms.
     *
     * @dev    Traders bound to this code stay bound -- they are keyed by the code
     *         NUMBER, not the owner address. The new owner inherits the entire
     *         referred book AND its unclaimed balances, which is the intent: the
     *         code changes hands as a going concern. The tier and discount travel
     *         with it, since both are properties of the code.
     *
     *  `ownerToCode[_newOwner]` is re-checked HERE, not just at nomination. Between
     *  the two steps the nominee may have been handed a code of their own, and one
     *  address holds at most one code -- executing blindly would overwrite that
     *  reverse lookup and strand their original code with no owner able to claim it.
     */
    function executeTransfer(uint64 _code) external onlyReferralVaultManager {
        address oldOwner = codeOwner[_code];
        require(oldOwner != address(0), "CODE_DOES_NOT_EXIST");

        address newOwner = pendingCodeOwner[_code];
        require(newOwner != address(0), "NO_PENDING_TRANSFER");
        require(newOwner != oldOwner, "ALREADY_OWNER");
        require(ownerToCode[newOwner] == uint64(0), "NEW_OWNER_HAS_CODE"); // re-check at execution

        delete pendingCodeOwner[_code];

        codeOwner[_code] = newOwner;
        ownerToCode[oldOwner] = uint64(0);
        ownerToCode[newOwner] = _code;
        emit CodeTransferred(_code, oldOwner, newOwner);
    }

    // ─────────────────────────────── internal ───────────────────────────────────

    /// @dev Internal tier writer. The public entry point lives in
    ///      ReferralVault.setCodeTier(). No settlement is needed before a tier
    ///      change: commission is priced per-fee at call time, never accrued.
    function _setCodeTier(uint64 _code, uint8 _newTier) internal {
        require(codeOwner[_code] != address(0), "CODE_DOES_NOT_EXIST");
        require(_newTier != 0 && _newTier <= MAX_TIERS, "INVALID_TIER");

        uint8 old = codeTier[_code];
        codeTier[_code] = _newTier;
        emit CodeTierSet(_code, old, _newTier);
    }

    /// @dev Clear a code's ownership. The vault layer calls this AFTER checking the
    ///      code has no unclaimed base and no unclaimed ARTHA in any vault; else
    ///      those rewards would be permanently stranded.
    function _deactivateCode(uint64 _code) internal {
        address owner = codeOwner[_code];
        require(owner != address(0), "ALREADY_DEACTIVATED");
        require(owner == msg.sender || msg.sender == referralVaultManager, "NOT_OWNER_OR_ADMIN");

        codeOwner[_code] = address(0);
        ownerToCode[owner] = uint64(0);
        codeTier[_code] = 0;
        codeDiscount[_code] = 0;

        delete pendingCodeOwner[_code];

        // Traders bound to this code are NOT touched here -- there may be many and
        // the loop is unbounded. `activeTraderCode()` resolves them to 0 the moment
        // codeOwner is cleared, which frees them to bind a new code.
        emit CodeDeactivated(_code, owner);
    }
}
