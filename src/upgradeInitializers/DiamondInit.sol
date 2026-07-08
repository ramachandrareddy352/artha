// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {AppStorage, Modifiers, RiskTier, PoolKind} from "../libraries/LibAppStorage.sol";

/**
 * @title  DiamondInit
 * @notice One-time initializer, delegatecalled by the diamond during the first
 *         diamondCut. It configures global params and stands up all SIX pools
 *         (low/medium/high x variable/fixed) with sensible RiskGuard defaults.
 *         Governance can override any value afterwards through AdminFacet (batch 2+).
 *
 *  It inherits `Modifiers` only so `AppStorage s` resolves to slot 0 when run in
 *  the diamond's context via delegatecall.
 */
contract DiamondInit is Modifiers {
    struct Args {
        address usdc;
        address artha;
        address oracle;         // OracleAggregator (batch 4) — can be set later
        address referralVault;  // ReferralVault (separate) — can be set later
        address treasury;
        address emergencyFund;
        address governance;     // Timelock
        address executor;       // bounded keeper multisig
        address guardian;       // pause/emergency multisig
    }

    function init(Args memory a) external {
        // ----- external contracts -----
        s.usdc = a.usdc;
        s.artha = a.artha;
        s.oracle = a.oracle;
        s.referralVault = a.referralVault;
        s.treasury = a.treasury;
        s.emergencyFund = a.emergencyFund;

        // ----- roles -----
        s.governance = a.governance;
        s.isExecutor[a.executor] = true;
        s.isGuardian[a.guardian] = true;

        // ----- global params -----
        s.decimalsOffset = 6;      // ERC-4626 inflation-attack defense
        s.poolCount = 6;
        s._reentrancyStatus = 1;   // "not entered"
        s.minDepositUsdc = 100e6;  // $100 minimum per deposit

        // ----- penalty split (10% protocol / 20% emergency / 70% users) -----
        s.earlyExitPenaltyBps = 100; // 1% of principal
        s.penToProtocolBps = 1000;
        s.penToEmergencyBps = 2000;
        s.penToUsersBps = 7000;

        // ----- fee routing -----
        s.feeToStakingBps = 6000;   // 60% of collected fees -> ARTHA staking
        s.feeToEmergencyBps = 1500; // 15% -> emergency fund (rest -> treasury)

        // ----- stand up the six pools -----
        _configPool(0, RiskTier.LOW,    PoolKind.VARIABLE);
        _configPool(1, RiskTier.LOW,    PoolKind.FIXED);
        _configPool(2, RiskTier.MEDIUM, PoolKind.VARIABLE);
        _configPool(3, RiskTier.MEDIUM, PoolKind.FIXED);
        _configPool(4, RiskTier.HIGH,   PoolKind.VARIABLE);
        _configPool(5, RiskTier.HIGH,   PoolKind.FIXED);
    }

    function _configPool(uint8 id, RiskTier tier, PoolKind kind) internal {
        s.poolActive[id] = true;
        s.poolTier[id] = tier;
        s.poolKind[id] = kind;

        // shared RiskGuard defaults
        s.minBufferBps[id] = 1000;     // keep >= 10% idle USDC buffer
        s.maxSlippageBps[id] = 100;    // 1% per swap
        s.rebalanceBandBps[id] = 300;  // 3% drift before a rebalance is allowed
        s.minPendingToSettle[id] = 1000e6; // only run end-of-day batch if >= 1,000 USDC pending

        // per-tier weight + meme caps
        if (tier == RiskTier.LOW) {
            s.maxWeightBps[id] = 10000; // stables/lending only; single-asset allowed
            s.maxMemeBps[id] = 0;
        } else if (tier == RiskTier.MEDIUM) {
            s.maxWeightBps[id] = 5000;  // max 50% per token
            s.maxMemeBps[id] = 1000;    // <= 10% meme exposure
        } else {
            s.maxWeightBps[id] = 4000;  // max 40% per token
            s.maxMemeBps[id] = 3000;    // <= 30% meme exposure
        }

        // fixed pools get a default 90-day lock term (governance can change)
        if (kind == PoolKind.FIXED) {
            s.lockDuration[id] = 90 days;
        }

        // fees + high-water mark
        s.mgmtFeeBps[id] = 200;    // 2% / yr
        s.perfFeeBps[id] = 1500;   // 15%
        s.highWaterMark[id] = 1e18; // pps starts at 1.0
        s.lastMgmtAccrual[id] = block.timestamp;
    }
}
