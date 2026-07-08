// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Modifiers} from "../libraries/LibAppStorage.sol";

/**
 * @title  AdminFacet
 * @notice Governance-only setters for every bound the executor operates within,
 *         plus the guardian pause. All bound changes are onlyGovernance (the
 *         Timelock), so they inherit the timelock delay. The guardian can pause
 *         (stop) but only governance can unpause (restart).
 */
contract AdminFacet is Modifiers {
    event RoleSet(bytes32 indexed role, address indexed account, bool enabled);
    event GovernanceSet(address oldGov, address newGov);
    event AddressSet(bytes32 indexed key, address value);
    event PoolActiveSet(uint8 indexed poolId, bool active);
    event MinDepositSet(uint256 amount);
    event MinPendingSet(uint8 indexed poolId, uint256 amount);
    event LockDurationSet(uint8 indexed poolId, uint256 secondsDur);
    event RiskLimitsSet(uint8 indexed poolId, uint16 maxWeight, uint16 minBuffer, uint16 maxSlippage, uint16 band, uint16 maxMeme);
    event FeesSet(uint8 indexed poolId, uint16 mgmt, uint16 perf);
    event FeeRoutingSet(uint16 toStaking, uint16 toEmergency);
    event PenaltySet(uint16 penalty, uint16 toProtocol, uint16 toEmergency, uint16 toUsers);
    event PausedSet(bool paused);

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    function setExecutor(address account, bool enabled) external onlyGovernance {
        s.isExecutor[account] = enabled;
        emit RoleSet("EXECUTOR", account, enabled);
    }

    function setGuardian(address account, bool enabled) external onlyGovernance {
        s.isGuardian[account] = enabled;
        emit RoleSet("GUARDIAN", account, enabled);
    }

    function setGovernance(address newGov) external onlyGovernance {
        require(newGov != address(0), "ZERO_GOV");
        emit GovernanceSet(s.governance, newGov);
        s.governance = newGov;
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL CONTRACT ADDRESSES
    //////////////////////////////////////////////////////////////*/

    function setOracle(address v) external onlyGovernance {
        require(v != address(0), "ZERO");
        s.oracle = v;
        emit AddressSet("ORACLE", v);
    }

    function setReferralVault(address v) external onlyGovernance {
        s.referralVault = v; // may be 0 to disable referral hooks
        emit AddressSet("REFERRAL_VAULT", v);
    }

    function setTreasury(address v) external onlyGovernance {
        require(v != address(0), "ZERO");
        s.treasury = v;
        emit AddressSet("TREASURY", v);
    }

    function setEmergencyFund(address v) external onlyGovernance {
        require(v != address(0), "ZERO");
        s.emergencyFund = v;
        emit AddressSet("EMERGENCY_FUND", v);
    }

    function setSwapAggregator(address v) external onlyGovernance {
        s.swapAggregator = v;
        emit AddressSet("SWAP_AGGREGATOR", v);
    }

    /*//////////////////////////////////////////////////////////////
                              POOL PARAMS
    //////////////////////////////////////////////////////////////*/

    function setPoolActive(uint8 poolId, bool active) external onlyGovernance validPool(poolId) {
        s.poolActive[poolId] = active;
        emit PoolActiveSet(poolId, active);
    }

    function setMinDeposit(uint256 amount) external onlyGovernance {
        s.minDepositUsdc = amount;
        emit MinDepositSet(amount);
    }

    function setMinPendingToSettle(uint8 poolId, uint256 amount) external onlyGovernance validPool(poolId) {
        s.minPendingToSettle[poolId] = amount;
        emit MinPendingSet(poolId, amount);
    }

    function setLockDuration(uint8 poolId, uint256 secondsDur) external onlyGovernance validPool(poolId) {
        s.lockDuration[poolId] = secondsDur;
        emit LockDurationSet(poolId, secondsDur);
    }

    function setRiskLimits(
        uint8 poolId,
        uint16 maxWeightBps,
        uint16 minBufferBps,
        uint16 maxSlippageBps,
        uint16 rebalanceBandBps,
        uint16 maxMemeBps
    ) external onlyGovernance validPool(poolId) {
        require(maxWeightBps <= 10000 && minBufferBps <= 10000 && maxSlippageBps <= 10000, "BPS_RANGE");
        s.maxWeightBps[poolId] = maxWeightBps;
        s.minBufferBps[poolId] = minBufferBps;
        s.maxSlippageBps[poolId] = maxSlippageBps;
        s.rebalanceBandBps[poolId] = rebalanceBandBps;
        s.maxMemeBps[poolId] = maxMemeBps;
        emit RiskLimitsSet(poolId, maxWeightBps, minBufferBps, maxSlippageBps, rebalanceBandBps, maxMemeBps);
    }

    /*//////////////////////////////////////////////////////////////
                              FEES / PENALTY
    //////////////////////////////////////////////////////////////*/

    function setFees(uint8 poolId, uint16 mgmtFeeBps, uint16 perfFeeBps) external onlyGovernance validPool(poolId) {
        require(mgmtFeeBps <= 10000 && perfFeeBps <= 10000, "BPS_RANGE");
        s.mgmtFeeBps[poolId] = mgmtFeeBps;
        s.perfFeeBps[poolId] = perfFeeBps;
        emit FeesSet(poolId, mgmtFeeBps, perfFeeBps);
    }

    function setFeeRouting(uint16 toStakingBps, uint16 toEmergencyBps) external onlyGovernance {
        require(uint256(toStakingBps) + toEmergencyBps <= 10000, "SUM_OVER_100");
        s.feeToStakingBps = toStakingBps;
        s.feeToEmergencyBps = toEmergencyBps;
        emit FeeRoutingSet(toStakingBps, toEmergencyBps);
    }

    function setPenalty(uint16 penaltyBps, uint16 toProtocolBps, uint16 toEmergencyBps, uint16 toUsersBps)
        external
        onlyGovernance
    {
        require(penaltyBps <= 10000, "BPS_RANGE");
        require(uint256(toProtocolBps) + toEmergencyBps + toUsersBps == 10000, "SPLIT_NOT_100");
        s.earlyExitPenaltyBps = penaltyBps;
        s.penToProtocolBps = toProtocolBps;
        s.penToEmergencyBps = toEmergencyBps;
        s.penToUsersBps = toUsersBps;
        emit PenaltySet(penaltyBps, toProtocolBps, toEmergencyBps, toUsersBps);
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Guardian can stop the protocol; governance restarts it.
    function pause() external onlyGuardian {
        s.paused = true;
        emit PausedSet(true);
    }

    function unpause() external onlyGovernance {
        s.paused = false;
        emit PausedSet(false);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function paused() external view returns (bool) {
        return s.paused;
    }

    function governance() external view returns (address) {
        return s.governance;
    }

    function isExecutor(address a) external view returns (bool) {
        return s.isExecutor[a];
    }

    function isGuardian(address a) external view returns (bool) {
        return s.isGuardian[a];
    }
}
