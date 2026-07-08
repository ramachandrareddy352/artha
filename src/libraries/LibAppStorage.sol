// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
                                 ENUMS
//////////////////////////////////////////////////////////////////////////*/

/// @notice Risk tier of a pool.
enum RiskTier {
    LOW,
    MEDIUM,
    HIGH
}

/// @notice VARIABLE = withdraw anytime (floating NAV). FIXED = locked term
///         (still floating NAV / pass-through returns — NOT a promised fixed rate;
///         just a lockup with an early-exit penalty).
enum PoolKind {
    VARIABLE,
    FIXED
}

/*//////////////////////////////////////////////////////////////////////////
                               APP STORAGE
//////////////////////////////////////////////////////////////////////////*/
/**
 * @notice The single shared storage struct for the whole protocol Diamond.
 *         Six pools, keyed by poolId 0..5:
 *           0 = LOW/VARIABLE   1 = LOW/FIXED
 *           2 = MED/VARIABLE   3 = MED/FIXED
 *           4 = HIGH/VARIABLE  5 = HIGH/FIXED
 *
 *  UPGRADE RULE: append new fields ONLY at the end. Adding mapping keys is always
 *  safe. Never reorder / retype existing fields.
 */
struct AppStorage {
    // ============ external contracts (separate deployments) ============
    address usdc;
    address artha;
    address oracle;          // OracleAggregator (batch 4)
    address referralVault;   // ReferralVault (separate)
    address swapAggregator;
    address treasury;
    address emergencyFund;

    // ============ roles ============
    address governance;                     // == Timelock; the ONLY setter of bounds
    mapping(address => bool) isExecutor;    // bounded multisig: triggers daily batch / rebalance
    mapping(address => bool) isGuardian;    // pause / emergency

    // ============ pools (poolId 0..5) ============
    uint8 poolCount;
    mapping(uint8 => bool)      poolActive;
    mapping(uint8 => RiskTier)  poolTier;
    mapping(uint8 => PoolKind)  poolKind;
    mapping(uint8 => address[]) poolBasket;      // <= 5 tokens
    mapping(uint8 => uint256)   idleUsdc;        // un-deployed USDC held for the pool
    mapping(uint8 => address[]) poolStrategies;  // active strategy adapters for the pool

    // ============ shares (ERC-4626 internal accounting) ============
    mapping(uint8 => uint256) totalShares;
    mapping(uint8 => mapping(address => uint256)) shares;
    uint8 decimalsOffset;                   // inflation-attack defense (>= 3)

    // ============ end-of-day deposit batching ============
    uint256 currentDay;
    mapping(uint8 => uint256) minPendingToSettle;                       // gate
    mapping(uint8 => mapping(uint256 => uint256)) pendingDeposit;        // [pool][day] => USDC
    mapping(uint8 => mapping(uint256 => mapping(address => uint256))) userPendingDeposit;
    mapping(uint8 => mapping(uint256 => uint256)) sharesPerAsset;        // [pool][day] settled (1e18)
    mapping(uint8 => mapping(uint256 => bool))    daySettled;

    // ============ RiskGuard limits (per pool) ============
    mapping(uint8 => uint16) maxWeightBps;
    mapping(uint8 => uint16) minBufferBps;
    mapping(uint8 => uint16) maxSlippageBps;
    mapping(uint8 => uint16) rebalanceBandBps;
    mapping(uint8 => uint16) maxMemeBps;
    mapping(uint8 => mapping(address => uint16)) targetWeightBps;       // [pool][token]
    mapping(address => bool) whitelisted;
    mapping(address => bool) isMemeClass;
    mapping(uint8 => mapping(address => address)) assetStrategy;        // [pool][token] => strategy

    // ============ fixed-term / early-exit ============
    mapping(uint8 => uint256) lockDuration;                            // penalty window (secs); 0 = none
    mapping(uint8 => mapping(address => uint256)) lockedUntil;         // [pool][user]
    uint16 earlyExitPenaltyBps;                                       // e.g. 100 = 1% of principal
    uint16 penToProtocolBps;
    uint16 penToEmergencyBps;
    uint16 penToUsersBps;

    // ============ fees + high-water mark (per pool) ============
    mapping(uint8 => uint16)  mgmtFeeBps;
    mapping(uint8 => uint16)  perfFeeBps;
    mapping(uint8 => uint256) highWaterMark;
    mapping(uint8 => uint256) lastMgmtAccrual;
    uint16 feeToStakingBps;
    uint16 feeToEmergencyBps;

    // ============ reentrancy guard (shared) ============
    uint256 _reentrancyStatus;                 // 1 = not entered, 2 = entered

    // ------- APPEND NEW STORAGE BELOW THIS LINE ONLY -------

    // ---- batch 2 additions ----
    bool paused;                                                     // global pause (guardian)
    uint256 minDepositUsdc;                                          // min per requestDeposit
    mapping(uint8 => mapping(address => uint256)) poolTokenBalance;  // [pool][token] idle basket holdings

    // ---- batch 3 additions ----
    mapping(address => bool) approvedSwapper;                        // DEX adapters allowed for swaps
}

/*//////////////////////////////////////////////////////////////////////////
                          STORAGE ACCESSOR (slot 0)
//////////////////////////////////////////////////////////////////////////*/

library LibAppStorage {
    function diamondStorage() internal pure returns (AppStorage storage s) {
        assembly {
            s.slot := 0
        }
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        MODIFIERS  (inherited by every app facet)
//////////////////////////////////////////////////////////////////////////*/

contract Modifiers {
    AppStorage internal s;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier onlyGovernance() {
        require(msg.sender == s.governance, "NOT_GOVERNANCE");
        _;
    }

    modifier onlyExecutor() {
        require(s.isExecutor[msg.sender], "NOT_EXECUTOR");
        _;
    }

    modifier onlyGuardian() {
        require(s.isGuardian[msg.sender], "NOT_GUARDIAN");
        _;
    }

    modifier validPool(uint8 poolId) {
        require(poolId < s.poolCount, "INVALID_POOL");
        _;
    }

    modifier whenNotPaused() {
        require(!s.paused, "PAUSED");
        _;
    }

    modifier nonReentrant() {
        require(s._reentrancyStatus != _ENTERED, "REENTRANCY");
        s._reentrancyStatus = _ENTERED;
        _;
        s._reentrancyStatus = _NOT_ENTERED;
    }
}
