// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
                              ReferralSystem
//////////////////////////////////////////////////////////////////////////*/
/**
 * @title  ReferralSystem
 * @notice Standalone referral REGISTRY for Artha. It owns all of its storage
 *         (codes, owners, tiers, discount shares) inside this contract — it is
 *         NOT a Diamond facet and shares no storage with the Diamond.
 *
 *         The Diamond's logic facets talk to this contract through the
 *         IReferralSystem interface (a normal external CALL). To "upgrade" the
 *         referral logic, governance just points the protocol at a new registry
 *         address — but note: a *new* registry starts empty, so prefer putting
 *         this behind a proxy if you want to change code while keeping data.
 *
 *  WHAT LIVES HERE (registry only — no money):
 *    - who owns each referral code
 *    - what tier a code is on (tier = the referrer's earning power)
 *    - the "discount share": how much of a reward the owner gives back to the
 *      investor (in PPM, where 1,000,000 = 100%)
 *
 *  WHAT DOES NOT LIVE HERE:
 *    - ARTHA tokens and reward balances  -> those are in the ReferralVault
 *    - the time-based reward math         -> also in the ReferralVault
 *
 *  UNITS: "PPM" = parts per million. 1,000,000 == 100%. For the tier reward
 *  multiplier, 1,000,000 == 1.0x, 1,500,000 == 1.5x, and so on.
 *
 *  TIERS ARE ADMIN-ONLY: only the admin can configure tier multipliers and
 *  promote a referrer to a higher tier (e.g. as a reward for driving volume).
 */
contract ReferralSystem {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev 1,000,000 == 100% (and == 1.0x for the tier multiplier).
    uint32 public constant PPM = 1_000_000;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The administrator. Controls tiers and handler permissions.
    address public admin;

    struct Referral {
        address owner;        // who owns this code (and earns from it)
        uint16 tierId;        // tier number; new codes start at tier 1
        uint32 discountShare; // PPM: fraction of each reward returned to the investor
    }

    /// @notice code => its registration data.
    mapping(bytes32 => Referral) public codeToReferral;

    /// @notice owner => the one code they own (one code per owner).
    mapping(address => bytes32) public ownerToCode;

    /// @notice investor => the code they have chosen to use (optional convenience).
    mapping(address => bytes32) public traderToCode;

    /// @notice tier => reward multiplier in PPM (1,000,000 = 1.0x). Admin-set.
    mapping(uint16 => uint32) public tierRewardMultPPM;

    /// @notice Addresses allowed to deactivate codes (e.g. the ReferralVault).
    mapping(address => bool) public isHandler;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AdminTransferred(address oldAdmin, address newAdmin);
    event HandlerUpdated(address handler, bool isHandler);
    event TierMultUpdated(uint16 tierId, uint32 multPPM);
    event ReferrerTierUpdated(address indexed referrer, uint16 oldTierId, uint16 newTierId);

    event CodeCreated(address indexed owner, bytes32 indexed code, uint32 discountShare);
    event DiscountShareUpdated(address indexed owner, uint32 share);
    event CodeTransferred(bytes32 indexed code, address indexed oldOwner, address indexed newOwner);
    event TraderCodeSet(address indexed trader, bytes32 indexed code);
    event CodeDeactivated(address indexed owner, bytes32 indexed code);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        require(msg.sender == admin, "NOT_ADMIN");
        _;
    }

    modifier onlyHandler() {
        require(isHandler[msg.sender], "NOT_HANDLER");
        _;
    }

    constructor(address _admin) {
        require(_admin != address(0), "INVALID_ADMIN");
        admin = _admin;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function transferAdmin(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "INVALID_ADMIN");
        admin = _newAdmin;
        emit AdminTransferred(msg.sender, _newAdmin);
    }

    /// @notice Allow/deny an address (typically the ReferralVault) to deactivate codes.
    function updateHandler(address _handler, bool _isHandler) external onlyAdmin {
        require(_handler != address(0), "INVALID_HANDLER");
        isHandler[_handler] = _isHandler;
        emit HandlerUpdated(_handler, _isHandler);
    }

    /**
     * @notice Configure a tier's reward multiplier. Tier 1 MUST be set before
     *         users can register codes (new codes start at tier 1).
     * @param  _tierId  Tier number (start at 1).
     * @param  _multPPM Multiplier in PPM (1,000,000 = 1.0x, 1,500,000 = 1.5x...).
     */
    function setTierMult(uint16 _tierId, uint32 _multPPM) external onlyAdmin {
        require(_multPPM != 0, "INVALID_MULT");
        tierRewardMultPPM[_tierId] = _multPPM;
        emit TierMultUpdated(_tierId, _multPPM);
    }

    /**
     * @notice Promote (or move) a referrer to a different tier. ADMIN ONLY.
     *         This is how a code that brings in lots of volume gets a higher
     *         multiplier. Admin decides off-chain based on referral volume.
     */
    function setReferrerTier(address _referrer, uint16 _newTierId) external onlyAdmin {
        require(_referrer != address(0), "INVALID_REFERRER");
        bytes32 code = ownerToCode[_referrer];
        require(code != bytes32(0), "NOT_A_REFERRER");
        require(tierRewardMultPPM[_newTierId] > 0, "TIER_NOT_CONFIGURED");

        uint16 oldTier = codeToReferral[code].tierId;
        codeToReferral[code].tierId = _newTierId;
        emit ReferrerTierUpdated(_referrer, oldTier, _newTierId);
    }

    /*//////////////////////////////////////////////////////////////
                       USER (REFERRER) FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create your referral code.
     * @param  _code          The code (bytes32) you want to own.
     * @param  _discountShare How much of each reward to hand back to investors,
     *                        in PPM (0 = keep all, 200_000 = give 20% back).
     */
    function registerCode(bytes32 _code, uint32 _discountShare) external {
        require(_code != bytes32(0), "INVALID_CODE");
        require(codeToReferral[_code].owner == address(0), "CODE_EXISTS");
        require(ownerToCode[msg.sender] == bytes32(0), "ALREADY_HAS_CODE");
        require(_discountShare <= PPM, "INVALID_SHARE");
        require(tierRewardMultPPM[1] > 0, "DEFAULT_TIER_NOT_SET");

        codeToReferral[_code] = Referral({owner: msg.sender, tierId: 1, discountShare: _discountShare});
        ownerToCode[msg.sender] = _code;
        emit CodeCreated(msg.sender, _code, _discountShare);
    }

    /// @notice Change how much of each reward you give back to investors.
    function setDiscountShare(uint32 _share) external {
        require(_share <= PPM, "INVALID_SHARE");
        bytes32 code = ownerToCode[msg.sender];
        require(code != bytes32(0), "NOT_A_REFERRER");
        codeToReferral[code].discountShare = _share;
        emit DiscountShareUpdated(msg.sender, _share);
    }

    /**
     * @notice Transfer your code to a new owner. The new owner must not already
     *         own a code (prevents orphaning their existing one).
     */
    function transferCodeOwnership(bytes32 _code, address _newOwner) external {
        require(_newOwner != address(0), "INVALID_ADDRESS");
        Referral storage ref = codeToReferral[_code];
        require(ref.owner == msg.sender, "NOT_CODE_OWNER");
        require(ownerToCode[_newOwner] == bytes32(0), "NEW_OWNER_HAS_CODE");

        ref.owner = _newOwner;
        ownerToCode[msg.sender] = bytes32(0);
        ownerToCode[_newOwner] = _code;
        emit CodeTransferred(_code, msg.sender, _newOwner);
    }

    /*//////////////////////////////////////////////////////////////
                          INVESTOR FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Optionally pre-set the code you (as an investor) want to use.
    ///         The deposit flow can also pass a code directly; this is convenience.
    function setTraderCode(bytes32 _code) external {
        require(_code != bytes32(0), "INVALID_CODE");
        require(codeToReferral[_code].owner != address(0), "CODE_DOES_NOT_EXIST");
        traderToCode[msg.sender] = _code;
        emit TraderCodeSet(msg.sender, _code);
    }

    /*//////////////////////////////////////////////////////////////
                          HANDLER FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deactivate a code. Only a registered handler (the ReferralVault)
     *         can call this — e.g. when an owner exits and withdraws everything.
     *         After deactivation the code earns nothing further.
     */
    function deactivateCode(bytes32 _code) external onlyHandler {
        require(_code != bytes32(0), "INVALID_CODE");
        Referral storage ref = codeToReferral[_code];
        address owner = ref.owner;
        require(owner != address(0), "ALREADY_DEACTIVATED");
        require(ownerToCode[owner] == _code, "OWNER_MISMATCH");

        ref.owner = address(0);
        ownerToCode[owner] = bytes32(0);
        emit CodeDeactivated(owner, _code);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Full info for a code. Used at deposit time to capture the discount.
    function getReferrerInfoByCode(bytes32 _code)
        external
        view
        returns (address owner, uint16 tierId, uint32 discountShare)
    {
        Referral memory r = codeToReferral[_code];
        return (r.owner, r.tierId, r.discountShare);
    }

    /// @notice Info for whatever code an investor currently has set.
    function getReferrerInfoByTrader(address _trader)
        external
        view
        returns (bytes32 code, address owner, uint16 tierId, uint32 discountShare)
    {
        code = traderToCode[_trader];
        if (code == bytes32(0)) return (bytes32(0), address(0), 0, 0);
        Referral memory r = codeToReferral[code];
        return (code, r.owner, r.tierId, r.discountShare);
    }

    /**
     * @notice Compact config the ReferralVault reads on every settlement:
     *         the current owner and the current tier's reward multiplier.
     * @dev    Tier multiplier is read LIVE (current tier). Because positions are
     *         settled on every user action, a tier promotion applies to accrual
     *         going forward; any un-settled gap gets the new multiplier. If you
     *         need strictly no retroactivity, settle a referrer's positions
     *         before promoting them.
     */
    function getRewardConfig(bytes32 _code)
        external
        view
        returns (address owner, uint256 tierMultPPM)
    {
        Referral memory r = codeToReferral[_code];
        return (r.owner, uint256(tierRewardMultPPM[r.tierId]));
    }
}
