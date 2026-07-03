// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {ArthaTimelock} from "../src/governance/ArthaTimelock.sol";
import {ArthaGovernor} from "../src/governance/ArthaGovernor.sol";

/*//////////////////////////////////////////////////////////////////////////
                         DeployGovernance (Foundry)
//////////////////////////////////////////////////////////////////////////*/
/**
 *  DEPLOY ORDER (why this exact sequence)
 *  --------------------------------------
 *   0. ArthaToken must already exist (ERC20Votes). If yours is deployed
 *      WITHOUT ERC20Votes, see "wrapper" note in GOVERNANCE_RUNBOOK.md.
 *   1. ArthaTimelock   — deployed FIRST because the Governor's constructor
 *                        needs its address. Proposers = [] (governor does
 *                        not exist yet), executors = [address(0)] (open
 *                        execution), admin = deployer (TEMPORARY, for
 *                        step-3 wiring only).
 *   2. ArthaGovernor   — points at token + timelock.
 *   3. Wire roles      — governor gets PROPOSER + CANCELLER on timelock;
 *                        guardian multisig gets CANCELLER (veto-only).
 *   4. Renounce        — deployer drops DEFAULT_ADMIN_ROLE on the timelock.
 *                        From this tx on, the timelock administers itself:
 *                        role changes require a passed proposal.
 *   5. Handoff         — referral proxy admin -> timelock. Repeat the same
 *                        pattern for the Diamond owner and the token's
 *                        DEFAULT_ADMIN_ROLE (commented templates below).
 *
 *  RUN
 *  ---
 *   export PRIVATE_KEY=0x...
 *   export ARTHA_TOKEN=0x...        # ERC20Votes token
 *   export GUARDIAN=0x...           # team multisig (Safe) — veto only
 *   export REFERRAL_PROXY=0x...     # optional; omit to skip handoff
 *
 *   forge script script/DeployGovernance.s.sol:DeployGovernance \
 *     --rpc-url $L2_RPC --broadcast --verify -vvvv
 */

/// @dev Adjust to YOUR referral stack's admin setter:
///      - custom admin var (your ReferralVaultManager layer): transferAdmin
///      - OZ OwnableUpgradeable:                              transferOwnership
///      - OZ AccessControl: grantRole(DEFAULT_ADMIN_ROLE, timelock)
///                          + renounceRole(DEFAULT_ADMIN_ROLE, deployer)
interface IReferralAdmin {
    function transferAdmin(address newAdmin) external;
}

contract DeployGovernance is Script {
    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE CONFIG — EDIT HERE
        All timing values are SECONDS (token clock = timestamp mode).
    //////////////////////////////////////////////////////////////*/

    /// @dev Queue -> execute delay. 2 days = users' guaranteed exit window.
    uint256 constant MIN_DELAY = 2 days; // 172_800 s

    /// @dev propose() -> voting opens. Time to read/discuss + delegate.
    uint48 constant VOTING_DELAY = 1 days; // 86_400 s

    /// @dev How long voting stays open.
    uint32 constant VOTING_PERIOD = 5 days; // 432_000 s

    /// @dev Min ARTHA voting power to create a proposal (spam gate).
    ///      Sizing: ~0.1% of initial circulating supply.
    ///      100_000_000e18 * 0.001 = 100_000e18
    uint256 constant PROPOSAL_THRESHOLD = 100_000e18;

    /// @dev % of total supply that must vote For+Abstain. Industry std: 4.
    uint256 constant QUORUM_PERCENT = 4;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address token = vm.envAddress("ARTHA_TOKEN");
        address guardian = vm.envAddress("GUARDIAN");
        address referral = vm.envOr("REFERRAL_PROXY", address(0));

        vm.startBroadcast(pk);

        /*----------------------------------------------------------
          1. Timelock
        ----------------------------------------------------------*/
        address[] memory proposers = new address[](0); // filled in step 3
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution: anyone after delay

        ArthaTimelock timelock =
            new ArthaTimelock(MIN_DELAY, proposers, executors, deployer);

        /*----------------------------------------------------------
          2. Governor
        ----------------------------------------------------------*/
        ArthaGovernor governor = new ArthaGovernor(
            IVotes(token),
            timelock,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_PERCENT
        );

        /*----------------------------------------------------------
          3. Wire timelock roles
        ----------------------------------------------------------*/
        // Only vote-approved batches can be scheduled:
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        // Governor may unschedule its own ops (e.g. proposal canceled):
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        // Guardian = emergency veto ONLY (can delete queued ops, nothing else):
        timelock.grantRole(timelock.CANCELLER_ROLE(), guardian);
        // EXECUTOR_ROLE already open (address(0)) via constructor.

        /*----------------------------------------------------------
          4. Deployer drops the keys — MUST be after step 3
        ----------------------------------------------------------*/
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
        // From here, only the timelock itself (i.e. a passed proposal)
        // can grant/revoke PROPOSER / CANCELLER / EXECUTOR.

        /*----------------------------------------------------------
          5. Hand the referral system to governance
             ASSIGN THE TIMELOCK — NEVER THE GOVERNOR.
        ----------------------------------------------------------*/
        if (referral != address(0)) {
            IReferralAdmin(referral).transferAdmin(address(timelock));
        }

        // Same pattern for the rest of the protocol (uncomment + adapt):
        //
        // Diamond (OwnershipFacet):
        //   IERC173(DIAMOND).transferOwnership(address(timelock));
        //
        // ArthaToken role admin (so minter changes need a vote):
        //   ArthaToken(token).grantRole(bytes32(0), address(timelock));
        //   ArthaToken(token).renounceRole(bytes32(0), deployer);

        vm.stopBroadcast();

        console2.log("ArthaTimelock :", address(timelock));
        console2.log("ArthaGovernor :", address(governor));
        console2.log("Guardian      :", guardian);
        console2.log("ADMIN OF PROTOCOL CONTRACTS = TIMELOCK:", address(timelock));
    }
}
