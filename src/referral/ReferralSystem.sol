// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract ReferralSystem {
    uint32 private constant BASIS_POINTS = 100_0000;

    address public referralAdmin;   // goverence, values are updated by dao outing process

    // tier id start from 1 only.
    // tierId → total rebate percentage (in basis points)
    mapping(uint16 => uint32) public tierRebates; // 20% = 20_0000
    // 20% sent to referral code owner and remaining to lp fees
    // in 20% the discount share is sent back to user and remaining to code referral owner

    struct Referral {
        address owner;
        uint16 tierId;
        uint32 discountShare; // custom share set by referrer (0..100_0000)
    }

    // referral code → referral data
    mapping(bytes32 => Referral) public codeToReferral;

    // referrer address → their referral code
    mapping(address => bytes32) public ownerToCode;

    // trader address → their referral code
    mapping(address => bytes32) public traderToCode;

    mapping(address => bool) public isHandler;

    /* EVENTS */
    // admin only
    event ReferralAdminTransferred(address oldAdmin, address newAdmin);
    event HandlerUpdated(address handler, bool isHandler);
    event TierRebateUpdated(uint16 tierId, uint32 totalRebate);
    event ReferrerTierUpdated(address indexed referrer, uint16 oldTierId, uint16 newTierId);

    // trader only
    event TraderCodeSet(address trader, bytes32 indexed code);

    // referral only
    event CodeCreated(address owner, bytes32 indexed code);
    event DiscountShareUpdated(address referrer, uint32 share);
    event CodeTransferred(bytes32 indexed code, address oldOwner, address newOwner);

    // handler
    event CodeDeactivated(address owner, bytes32 indexed code);

    /* MODIFIERS */
    modifier onlyReferralAdmin() {
        require(msg.sender == referralAdmin, "NOT_ADMIN");
        _;
    }

    modifier onlyHandler() {
        require(isHandler[msg.sender], "NOT_HANDLER");
        _;
    }

    constructor(address _referralAdmin) {
        require(_referralAdmin != address(0), "INVALID_ADMIN_ADDRESS");

        referralAdmin = _referralAdmin;
    }

    /* ADMIN FUNCTIONS */
    function transferAdmin(address _newAdmin) external onlyReferralAdmin {
        require(_newAdmin != address(0), "INVALID_ADMIN");

        referralAdmin = _newAdmin;

        emit ReferralAdminTransferred(msg.sender, _newAdmin);
    }

    // 1 handler is vault contract that deactivate the code and transfer all funds and set owner to zero address.
    function updateHandler(address _handler, bool _isHandler) external onlyReferralAdmin {
        require(_handler != address(0), "INVALID_HANDLER");

        isHandler[_handler] = _isHandler;

        emit HandlerUpdated(_handler, _isHandler);
    }

    function setTierRebate(uint16 _tierId, uint32 _totalRebate) external onlyReferralAdmin {
        require(_totalRebate != 0 && _totalRebate <= BASIS_POINTS, "INVALID_REBATE");

        tierRebates[_tierId] = _totalRebate;

        emit TierRebateUpdated(_tierId, _totalRebate);
    }

    // this is offline work, amdin can increase tier of referral to get more share in fees
    function adminSetReferrerTier(address _referrer, uint16 _newTierId) external onlyReferralAdmin {
        require(_referrer != address(0), "INVALID_REFERRER");

        bytes32 _code = ownerToCode[_referrer];
        require(_code != bytes32(0), "NOT_A_REFERRER");

        // the new tier must exist and have a positive rebate
        require(tierRebates[_newTierId] > 0, "TIER_NOT_CONFIGURED_OR_ZERO_REBATE");

        uint16 _oldTier = codeToReferral[_code].tierId;
        codeToReferral[_code].tierId = _newTierId;

        emit ReferrerTierUpdated(_referrer, _oldTier, _newTierId);
    }

    /* TRADER SET FUNCTIONS */
    function setReferralCode(bytes32 _code) external {
        require(_code != bytes32(0), "INVALID_CODE");
        require(codeToReferral[_code].owner != address(0), "CODE_DOES_NOT_EXIST");

        traderToCode[msg.sender] = _code;

        emit TraderCodeSet(msg.sender, _code);
    }

    /* USER FUNCTIONS */
    function registerCode(bytes32 _code, uint32 _discountShare) external {
        require(_code != bytes32(0), "INVALID_CODE");
        require(codeToReferral[_code].owner == address(0), "CODE_ALREADY_EXISTS");
        require(ownerToCode[msg.sender] == bytes32(0), "REFERRER_ALREADY_HAS_CODE");
        require(_discountShare <= BASIS_POINTS, "INVALID_SHARE");
        require(tierRebates[1] > 0, "DEFAULT_TIER_NOT_CONFIGURED");

        codeToReferral[_code] = Referral({
            owner: msg.sender,
            tierId: 1, // default tier
            discountShare: _discountShare
        });

        ownerToCode[msg.sender] = _code;

        emit CodeCreated(msg.sender, _code);
    }

    function setDiscountShare(uint32 _share) external {
        require(_share <= BASIS_POINTS, "INVALID_SHARE");

        bytes32 _code = ownerToCode[msg.sender];
        require(_code != bytes32(0), "NOT_A_REFERRER");

        codeToReferral[_code].discountShare = _share;

        emit DiscountShareUpdated(msg.sender, _share);
    }

    function transferCodeOwnership(bytes32 _code, address _newOwner) external {
        require(_newOwner != address(0), "INVALID_ADDRESS");

        Referral storage _referral = codeToReferral[_code];
        require(_referral.owner == msg.sender, "NOT_CODE_OWNER");

        address _oldOwner = msg.sender;

        _referral.owner = _newOwner;
        ownerToCode[_oldOwner] = bytes32(0);
        ownerToCode[_newOwner] = _code;

        emit CodeTransferred(_code, _oldOwner, _newOwner);
    }

    // currently only vault can call this function.
    function deactivateCode(bytes32 _code) external onlyHandler {
        require(_code != bytes32(0), "INVALID_CODE");

        Referral storage ref = codeToReferral[_code];
        address currentOwner = ref.owner;

        require(currentOwner != address(0), "ALREADY_DEACTIVATED");

        require(ownerToCode[currentOwner] == _code, "CODE_OWNER_MISMATCH");

        ref.owner = address(0);
        ownerToCode[currentOwner] = bytes32(0);

        emit CodeDeactivated(currentOwner, _code);
    }

    /* VIEW / CALCULATION FUNCTIONS */
    function getReferrerInfoByTrader(address _trader)
        external
        view
        returns (bytes32 code, address referrer, uint32 tierId, uint32 discountShare)
    {
        code = traderToCode[_trader];

        if (code == bytes32(0)) {
            return (bytes32(0), address(0), 0, 0);
        }

        Referral memory _referral = codeToReferral[code];

        return (code, _referral.owner, _referral.tierId, _referral.discountShare);
    }

    function getReferrerInfoByCode(bytes32 _code)
        external
        view
        returns (address referrer, uint16 tierId, uint32 discountShare)
    {
        Referral memory _ref = codeToReferral[_code];
        return (_ref.owner, _ref.tierId, _ref.discountShare);
    }

    function calculateReferralRewards(address _trader, uint256 _feeAmount)
        external
        view
        returns (uint256 traderDiscount, uint256 referrerReward)
    {
        bytes32 _code = traderToCode[_trader];
        if (_code == bytes32(0)) {
            return (0, 0);
        }

        Referral memory _referral = codeToReferral[_code];
        if (_referral.owner == address(0)) {
            return (0, 0);
        }

        if (_referral.owner == _trader) {
            return (0, 0); // Self-referral not allowed
        }

        uint32 _totalRebate = tierRebates[_referral.tierId];
        uint256 _rebate = (_feeAmount * _totalRebate) / BASIS_POINTS;
        uint32 _share = _referral.discountShare;

        traderDiscount = (_rebate * _share) / BASIS_POINTS;
        referrerReward = _rebate - traderDiscount;
    }
}
