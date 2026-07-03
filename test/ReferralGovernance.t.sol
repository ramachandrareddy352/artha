// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GovernanceTestBase} from "./helpers/GovernanceTestBase.sol";
import {ReferralVault} from "../src/referral/ReferralVault.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/*//////////////////////////////////////////////////////////////////////////
        ReferralGovernance.t.sol — proposals drive the referral vault
//////////////////////////////////////////////////////////////////////////*/
/**
 *  The referral vault admin is the TIMELOCK (handoff done in setUp), so the
 *  ONLY way to change pool rates is a full governance proposal. This file
 *  proves every path the flow can take:
 *
 *   HAPPY PATH   propose -> (1d) -> vote -> (5d) -> queue -> (2d) -> execute
 *                and the rates for pools 0,1,2 actually change on-chain.
 *   REJECTIONS   a) quorum not met (votes below 4% of snapshot supply)
 *                b) Against >= For even though quorum was met
 *   TIME GATES   voting BEFORE the voting delay has passed is impossible —
 *                voters only get to use their power after the snapshot.
 *   SNAPSHOTS    tokens minted AFTER the snapshot give ZERO voting power on
 *                that proposal, even if the holder delegates and votes right
 *                away. Same for old tokens whose delegation came too late.
 *   GUARDS       proposal threshold, execute-before-eta, guardian veto,
 *                nobody but the timelock can touch setRate directly.
 */
contract ReferralGovernanceTest is GovernanceTestBase {
    /*//////////////////////////////////////////////////////////////
        1. HAPPY PATH — full lifecycle updates rates on pools 0,1,2
    //////////////////////////////////////////////////////////////*/

    function test_HappyPath_ProposalUpdatesAllThreePoolRates() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _buildSetRatesProposal(0.40e18, 0.80e18, 1.20e18);

        /*----------------------- PROPOSE ---------------------------*/
        uint256 id = _propose(targets, values, calldatas, description);
        _assertState(id, IGovernor.ProposalState.Pending);

        // snapshot = propose time + votingDelay; deadline = snapshot + period
        assertEq(governor.proposalSnapshot(id), block.timestamp + VOTING_DELAY);
        assertEq(
            governor.proposalDeadline(id),
            block.timestamp + VOTING_DELAY + VOTING_PERIOD
        );

        /*------------------------ VOTE -----------------------------*/
        _rollToActive(id);
        _assertState(id, IGovernor.ProposalState.Active);

        vm.prank(whale);
        governor.castVote(id, 1); // For (30M — clears the 4M quorum alone)
        vm.prank(voter2);
        governor.castVote(id, 1); // For (5M)
        vm.prank(voter3);
        governor.castVote(id, 0); // Against (2M) — outvoted

        (uint256 against, uint256 forVotes, uint256 abstains) = governor.proposalVotes(id);
        assertEq(forVotes, 35_000_000e18);
        assertEq(against, 2_000_000e18);
        assertEq(abstains, 0);

        /*------------------- SUCCEED + QUEUE ------------------------*/
        _rollToVoteEnd(id);
        _assertState(id, IGovernor.ProposalState.Succeeded);

        bytes32 descHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descHash);
        _assertState(id, IGovernor.ProposalState.Queued);
        assertEq(governor.proposalEta(id), block.timestamp + MIN_DELAY);

        /*---------------- WAIT THE DELAY + EXECUTE ------------------*/
        vm.warp(block.timestamp + MIN_DELAY + 1);

        // the three RateUpdated events fire from inside the timelock call
        vm.expectEmit(true, false, false, true, address(vault));
        emit ReferralVault.RateUpdated(0, RATE_LOW, 0.40e18);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ReferralVault.RateUpdated(1, RATE_MEDIUM, 0.80e18);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ReferralVault.RateUpdated(2, RATE_HIGH, 1.20e18);

        governor.execute(targets, values, calldatas, descHash); // anyone may call
        _assertState(id, IGovernor.ProposalState.Executed);

        /*--------------------- ON-CHAIN EFFECT ----------------------*/
        assertEq(_rate(0), 0.40e18, "pool 0 updated by governance");
        assertEq(_rate(1), 0.80e18, "pool 1 updated by governance");
        assertEq(_rate(2), 1.20e18, "pool 2 updated by governance");
    }

    function test_HappyPath_NewRateActuallyChangesAccrual() public {
        // a live position accrues at 1.0 before the proposal and 2.0 after —
        // proving governance changes feed straight into the reward math and
        // are NOT retroactive (setRate settles the old rate first).
        diamond.deposit(2, investor1, 1_000e6);
        uint256 t0 = block.timestamp;

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _buildSetRatesProposal(RATE_LOW, RATE_MEDIUM, 2e18); // HIGH: 1.0 -> 2.0

        uint256 id = _propose(targets, values, calldatas, description);
        _rollToActive(id);
        vm.prank(whale);
        governor.castVote(id, 1);
        _rollToVoteEnd(id);
        _queueAndExecute(targets, values, calldatas, description);

        uint256 tExec = block.timestamp; // 8 days + 2s after t0
        vm.warp(tExec + 30 days);

        // phase 1 (t0 -> tExec)   @ 1.0 ARTHA/USDC/yr
        // phase 2 (tExec -> +30d) @ 2.0 ARTHA/USDC/yr
        uint256 p1 = (1_000e6 * ((1e18 * (tExec - t0) * 1e18) / (1e6 * 365 days))) / 1e18;
        uint256 p2 = (1_000e6 * ((2e18 * uint256(30 days) * 1e18) / (1e6 * 365 days))) / 1e18;
        assertEq(vault.pendingReward(2, CODE_A), p1 + p2);
    }

    /*//////////////////////////////////////////////////////////////
              2. REJECTION — quorum not met => Defeated
    //////////////////////////////////////////////////////////////*/

    function test_Reject_QuorumNotMet() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _buildSetRatesProposal(0.1e18, 0.2e18, 0.3e18);

        uint256 id = _propose(targets, values, calldatas, description);
        _rollToActive(id);

        // quorum = 4% of the 100M snapshot supply = 4,000,000 ARTHA.
        // voter3 alone brings 2,000,000 For — every vote is FOR, and it still dies.
        assertEq(governor.quorum(governor.proposalSnapshot(id)), 4_000_000e18);
        vm.prank(voter3);
        governor.castVote(id, 1);

        _rollToVoteEnd(id);
        _assertState(id, IGovernor.ProposalState.Defeated);

        // a defeated proposal cannot be queued...
        bytes32 descHash = keccak256(bytes(description));
        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.queue(targets, values, calldatas, descHash);

        // ...and nothing reached the vault
        assertEq(_rate(0), RATE_LOW);
        assertEq(_rate(1), RATE_MEDIUM);
        assertEq(_rate(2), RATE_HIGH);
    }

    /*//////////////////////////////////////////////////////////////
           3. REJECTION — quorum met but Against >= For
    //////////////////////////////////////////////////////////////*/

    function test_Reject_AgainstOutweighsFor() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _buildSetRatesProposal(0, 0, 0); // hostile: zero all rewards

        uint256 id = _propose(targets, values, calldatas, description);
        _rollToActive(id);

        vm.prank(voter2);
        governor.castVote(id, 1); // For: 5M — quorum IS met (>= 4M)
        vm.prank(whale);
        governor.castVote(id, 0); // Against: 30M — kills it anyway

        _rollToVoteEnd(id);
        _assertState(id, IGovernor.ProposalState.Defeated);

        assertEq(_rate(2), RATE_HIGH, "hostile rate change never landed");
    }

    /*//////////////////////////////////////////////////////////////
        4. TIME GATE — no voting while Pending; power arrives only
           after the voting delay has fully passed
    //////////////////////////////////////////////////////////////*/

    function test_CannotVoteWhilePending_PowerOnlyAfterDelay() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _buildSetRatesProposal(0.45e18, 0.85e18, 1.25e18);

        uint256 id = _propose(targets, values, calldatas, description);
        _assertState(id, IGovernor.ProposalState.Pending);

        // whale holds 30M delegated ARTHA and STILL cannot vote yet —
        // castVote demands the Active state (bitmap = 1 << Active).
        vm.prank(whale);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                id,
                IGovernor.ProposalState.Pending,
                bytes32(1 << uint8(IGovernor.ProposalState.Active))
            )
        );
        governor.castVote(id, 1);

        // one second BEFORE the snapshot: still Pending, still locked out
        vm.warp(governor.proposalSnapshot(id));
        _assertState(id, IGovernor.ProposalState.Pending);
        vm.prank(whale);
        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.castVote(id, 1);

        // one second AFTER the snapshot: NOW the vote counts
        vm.warp(governor.proposalSnapshot(id) + 1);
        _assertState(id, IGovernor.ProposalState.Active);
        vm.prank(whale);
        governor.castVote(id, 1);
        (, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, 30_000_000e18, "power usable only after the delay passed");
    }

    /*//////////////////////////////////////////////////////////////
        5. SNAPSHOT INTEGRITY — ARTHA received at proposal time,
           voted immediately => ZERO power
    //////////////////////////////////////////////////////////////*/

    function test_TokensMintedAfterSnapshot_HaveZeroPower() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _buildSetRatesProposal(0.42e18, 0.82e18, 1.22e18);

        uint256 id = _propose(targets, values, calldatas, description);
        uint256 snapshot = governor.proposalSnapshot(id);
        _rollToActive(id);

        // lateBuyer receives a HUGE stack (50M > the whole 4M quorum)
        // WHILE the vote is live, delegates instantly, and votes instantly.
        artha.mint(lateBuyer, 50_000_000e18);
        vm.prank(lateBuyer);
        artha.delegate(lateBuyer);
        vm.warp(block.timestamp + 1); // checkpoint lands — but AFTER snapshot

        assertEq(artha.balanceOf(lateBuyer), 50_000_000e18); // has the tokens...
        assertEq(artha.getPastVotes(lateBuyer, snapshot), 0); // ...has NO power

        vm.prank(lateBuyer);
        governor.castVote(id, 1); // accepted, but weighs 0

        assertTrue(governor.hasVoted(id, lateBuyer));
        (uint256 against, uint256 forVotes, uint256 abstains) = governor.proposalVotes(id);
        assertEq(forVotes, 0, "50M late tokens contribute ZERO weight");
        assertEq(against, 0);
        assertEq(abstains, 0);

        // the late mint also cannot bend the quorum bar: quorum reads the
        // SNAPSHOT supply (100M), not today's inflated 150M supply
        assertEq(governor.quorum(snapshot), 4_000_000e18);

        // nobody real voted, so the buy-in achieved nothing:
        _rollToVoteEnd(id);
        _assertState(id, IGovernor.ProposalState.Defeated);
        assertEq(_rate(2), RATE_HIGH);
    }

    function test_DelegationAfterSnapshot_AlsoZeroPower() public {
        // sleeper has held 3M ARTHA since BEFORE the proposal — but voting
        // power flows from delegation checkpoints, and sleeper never
        // delegated. Delegating after the snapshot is exactly as useless as
        // buying after it.
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _buildSetRatesProposal(0.41e18, 0.81e18, 1.21e18);

        uint256 id = _propose(targets, values, calldatas, description);
        uint256 snapshot = governor.proposalSnapshot(id);
        _rollToActive(id);

        vm.prank(sleeper);
        artha.delegate(sleeper); // too late for THIS proposal
        vm.warp(block.timestamp + 1);

        assertEq(artha.getPastVotes(sleeper, snapshot), 0);

        vm.prank(sleeper);
        governor.castVote(id, 1);
        (, uint256 forVotes,) = governor.proposalVotes(id);
        assertEq(forVotes, 0, "old tokens + late delegation = still zero");

        // control: for the NEXT proposal the same delegation counts in full
        (targets, values, calldatas, description) =
            _buildSetRatesProposal(0.43e18, 0.83e18, 1.23e18);
        uint256 id2 = _propose(targets, values, calldatas, description);
        _rollToActive(id2);
        vm.prank(sleeper);
        governor.castVote(id2, 1);
        (, uint256 forVotes2,) = governor.proposalVotes(id2);
        assertEq(forVotes2, 3_000_000e18, "counts once a snapshot postdates the delegation");
    }

    /*//////////////////////////////////////////////////////////////
                6. PROPOSAL THRESHOLD — spam gate
    //////////////////////////////////////////////////////////////*/

    function test_ProposeBelowThreshold_Reverts() public {
        address pauper = makeAddr("pauper");
        artha.mint(pauper, 1_000e18); // far under the 100k threshold
        vm.prank(pauper);
        artha.delegate(pauper);
        vm.warp(block.timestamp + 1);

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _buildSetRatesProposal(1e18, 1e18, 1e18);

        vm.prank(pauper);
        vm.expectPartialRevert(Governor.GovernorInsufficientProposerVotes.selector);
        governor.propose(targets, values, calldatas, description);
    }

    /*//////////////////////////////////////////////////////////////
               7. TIMELOCK DELAY — execute too early
    //////////////////////////////////////////////////////////////*/

    function test_ExecuteBeforeEta_Reverts() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _buildSetRatesProposal(0.5e18, 0.9e18, 1.3e18);

        uint256 id = _propose(targets, values, calldatas, description);
        _rollToActive(id);
        vm.prank(whale);
        governor.castVote(id, 1);
        _rollToVoteEnd(id);

        bytes32 descHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descHash);

        // immediately: op is not Ready inside the timelock
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        governor.execute(targets, values, calldatas, descHash);

        // one second before eta: still not Ready
        vm.warp(governor.proposalEta(id) - 1);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        governor.execute(targets, values, calldatas, descHash);

        // at eta: executes
        vm.warp(governor.proposalEta(id));
        governor.execute(targets, values, calldatas, descHash);
        assertEq(_rate(2), 1.3e18);
    }

    /*//////////////////////////////////////////////////////////////
             8. GUARDIAN VETO — cancel a queued operation
    //////////////////////////////////////////////////////////////*/

    function test_GuardianCanVetoQueuedProposal() public {
        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        ) = _buildSetRatesProposal(0, 0, 0); // pretend a malicious one passed

        uint256 id = _propose(targets, values, calldatas, description);
        _rollToActive(id);
        vm.prank(whale);
        governor.castVote(id, 1);
        _rollToVoteEnd(id);

        bytes32 descHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descHash);
        _assertState(id, IGovernor.ProposalState.Queued);

        // Timelock op id: GovernorTimelockControl salts the batch with
        // bytes20(governor) ^ descriptionHash and predecessor = 0.
        bytes32 salt = bytes32(bytes20(address(governor))) ^ descHash;
        bytes32 opId =
            timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);

        vm.prank(guardian);
        timelock.cancel(opId); // veto DURING the 2-day window

        _assertState(id, IGovernor.ProposalState.Canceled);

        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.expectPartialRevert(IGovernor.GovernorUnexpectedProposalState.selector);
        governor.execute(targets, values, calldatas, descHash);

        assertEq(_rate(2), RATE_HIGH, "vetoed payload never touched the vault");
    }

    /*//////////////////////////////////////////////////////////////
          9. NOBODY BYPASSES GOVERNANCE ON THE VAULT ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_DirectSetRate_AlwaysReverts_ForEveryoneButTimelock() public {
        vm.expectRevert(bytes("NOT_REFERRAL_VAULT_MANAGER")); // deployer
        vault.setRate(0, 1e18);

        vm.prank(address(governor)); // even the GOVERNOR is not the admin
        vm.expectRevert(bytes("NOT_REFERRAL_VAULT_MANAGER"));
        vault.setRate(0, 1e18);

        vm.prank(whale); // token power alone means nothing
        vm.expectRevert(bytes("NOT_REFERRAL_VAULT_MANAGER"));
        vault.setRate(0, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
         10. POST-HANDOFF ADMIN ACTION — create a code by proposal
    //////////////////////////////////////////////////////////////*/

    function test_Governance_CreatesNewReferralCode() public {
        address referrerD = makeAddr("referrerD");
        uint64 codeD = 1004;

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(vault);
        calldatas[0] = abi.encodeCall(ReferralVault.createCode, (codeD, referrerD));
        string memory description = "ARP-2: Onboard referrer D with code 1004";

        uint256 id = _propose(targets, values, calldatas, description);
        _rollToActive(id);
        vm.prank(whale);
        governor.castVote(id, 1);
        _rollToVoteEnd(id);
        _queueAndExecute(targets, values, calldatas, description);

        assertEq(vault.codeOwner(codeD), referrerD, "code created by governance");

        // and it is immediately usable end-to-end
        address freshInvestor = makeAddr("investorD");
        vm.prank(freshInvestor);
        vault.setTraderCode(codeD);
        diamond.deposit(2, freshInvestor, 1_000e6);
        vm.warp(block.timestamp + 365 days);
        assertEq(vault.pendingReward(2, codeD), 1_000e18);
    }
}
