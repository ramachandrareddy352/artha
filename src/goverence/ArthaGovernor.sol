// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorVotesQuorumFraction} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/*//////////////////////////////////////////////////////////////////////////
                             ArthaGovernor
//////////////////////////////////////////////////////////////////////////*/
/**
 * @title  ArthaGovernor
 * @notice On-chain voting brain of Artha. Compound-Bravo-style governance
 *         built from the audited OZ v5 Governor modules. It holds NO
 *         protocol permissions itself — its only power is PROPOSER_ROLE /
 *         CANCELLER_ROLE on the ArthaTimelock.
 *
 *  MODULE STACK (what each parent contributes)
 *  -------------------------------------------
 *   Governor                    core: proposal storage, state machine,
 *                               propose / castVote / execute entrypoints
 *   GovernorSettings            votingDelay / votingPeriod /
 *                               proposalThreshold as storage, each
 *                               changeable ONLY via a passed proposal
 *                               (setVotingDelay etc. are onlyGovernance)
 *   GovernorCountingSimple      3-option ballots: 0=Against 1=For 2=Abstain
 *                               COUNTING_MODE = "support=bravo&quorum=for,abstain"
 *                               -> quorum counts For + Abstain votes
 *   GovernorVotes               reads voting power from ARTHA's
 *                               ERC20Votes checkpoints; inherits the
 *                               token's timestamp clock (ERC-6372)
 *   GovernorVotesQuorumFraction quorum = % of TOTAL SUPPLY at snapshot
 *   GovernorTimelockControl     routes execution through ArthaTimelock:
 *                               adds the Queued state + queue() step
 *
 *  FULL PROPOSAL STATE MACHINE
 *  ---------------------------
 *                    propose()
 *                       │
 *                       ▼
 *   ┌──────── 0 Pending ────────┐        cancel() by proposer
 *   │   (votingDelay running)   │──────────────────────────► 2 Canceled
 *   └──────────────┬────────────┘
 *                  ▼  t > voteStart
 *              1 Active
 *          (votingPeriod running, castVote here)
 *                  │  t > voteEnd
 *        ┌─────────┴──────────┐
 *        ▼                    ▼
 *   3 Defeated            4 Succeeded          ◄─ "rejection" happens here:
 *   (quorum missed OR         │                   quorum not met, or
 *    against >= for)          ▼  queue()          against >= for
 *        ✕ dead           5 Queued ─── guardian timelock.cancel ─► 2 Canceled
 *                             │  t >= eta, execute()
 *                             ▼
 *                         7 Executed
 *
 *  TIMELINE EXAMPLE (values from DeployGovernance.s.sol)
 *  -----------------------------------------------------
 *   votingDelay = 86_400 (1d), votingPeriod = 432_000 (5d),
 *   timelock minDelay = 172_800 (2d). Proposal created at t0:
 *
 *     snapshot  (voting power frozen) = t0 +  86_400
 *     voteEnd                         = t0 +  86_400 + 432_000 = t0 + 518_400
 *     queue at voteEnd  -> eta        = (t0 + 518_400) + 172_800
 *     earliest execution              = t0 + 691_200          (= t0 + 8 days)
 *
 *  QUORUM MATH (GovernorVotesQuorumFraction, numerator = 4)
 *  --------------------------------------------------------
 *     quorum(snapshot) = totalSupply(snapshot) * 4 / 100
 *     e.g. supply = 100_000_000e18
 *          quorum = 100_000_000e18 * 4 / 100 = 4_000_000e18
 *     reached when  forVotes + abstainVotes >= 4_000_000e18
 *     succeeded when ALSO  forVotes > againstVotes
 *
 *  CORE FUNCTIONS CHEAT-SHEET (all inherited, listed for reference)
 *  ----------------------------------------------------------------
 *  CREATE
 *    propose(address[] targets, uint256[] values, bytes[] calldatas,
 *            string description) returns (uint256 proposalId)
 *      - caller needs getVotes(caller, clock()-1) >= proposalThreshold()
 *      - proposalId = hashProposal(targets, values, calldatas,
 *                                  keccak256(bytes(description)))
 *        => the SAME 4 arrays + the description HASH must be replayed
 *           verbatim to queue/execute/cancel. One byte off = unknown id.
 *  VOTE (only while state == Active)
 *    castVote(id, support)                       support: 0/1/2
 *    castVoteWithReason(id, support, reason)
 *    castVoteWithReasonAndParams(...)
 *    castVoteBySig(id, support, voter, sig)      gasless via EIP-712
 *      - weight used = getPastVotes(voter, proposalSnapshot(id));
 *        buying ARTHA after the snapshot adds NOTHING.
 *      - one vote per address per proposal, no changing your vote.
 *  APPROVE INTO TIMELOCK (only when state == Succeeded)
 *    queue(targets, values, calldatas, descriptionHash)
 *      - forwards the batch to timelock.scheduleBatch with
 *        salt = bytes20(address(this)) ^ descriptionHash
 *      - state becomes Queued; eta = now + timelock.getMinDelay()
 *  EXECUTE (only when Queued and block.timestamp >= eta)
 *    execute(targets, values, calldatas, descriptionHash)  [payable]
 *      - timelock performs the calls; timelock — not the governor —
 *        must hold any funds/roles the payload spends.
 *  REJECT / KILL
 *    a) Defeated automatically at voteEnd (quorum or vote fail) — no tx.
 *    b) cancel(targets, values, calldatas, descriptionHash)
 *       — proposer only, and ONLY while state == Pending.
 *    c) Guardian veto while Queued:
 *       timelock.cancel(operationId) from the guardian multisig; the
 *       governor then reports the proposal as Canceled.
 *  READ
 *    state(id) proposalSnapshot(id) proposalDeadline(id) proposalEta(id)
 *    proposalVotes(id) -> (against, for, abstain)     hasVoted(id, voter)
 *    getVotes(account, timepoint)   quorum(timepoint)  proposalNeedsQueuing(id)
 */
contract ArthaGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /**
     * @param _token             ArthaToken (must implement IVotes/ERC20Votes).
     * @param _timelock          ArthaTimelock the governor queues into.
     * @param _votingDelay       Seconds between propose() and voting start
     *                           (token clock is timestamp mode). Rec: 86_400.
     * @param _votingPeriod      Seconds voting stays open. Rec: 432_000 (5d).
     * @param _proposalThreshold Min voting power to create a proposal,
     *                           in token wei. Rec: 100_000e18.
     * @param _quorumNumerator   Percent of total supply that must vote
     *                           (For+Abstain). Rec: 4  (=> 4%).
     */
    constructor(
        IVotes _token,
        TimelockController _timelock,
        uint48 _votingDelay,
        uint32 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumNumerator
    )
        Governor("Artha Governor")
        GovernorSettings(_votingDelay, _votingPeriod, _proposalThreshold)
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(_quorumNumerator)
        GovernorTimelockControl(_timelock)
    {}

    /*//////////////////////////////////////////////////////////////
        OVERRIDES REQUIRED BY SOLIDITY — every function below exists in
        two parents, so we must pin the resolution order explicitly.
        All of them just defer to super (C3-linearized) — no new logic.
    //////////////////////////////////////////////////////////////*/

    /// @dev GovernorSettings stores the value; Governor declares the API.
    function votingDelay()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    /// @dev quorum(timepoint) = pastTotalSupply(timepoint) * numerator / 100.
    function quorum(uint256 timepoint)
        public
        view
        override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(timepoint);
    }

    /// @dev TimelockControl folds the timelock's status into the state:
    ///      Queued while pending, Canceled if vetoed, Executed when done.
    function state(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    /// @dev Always true with a timelock: Succeeded proposals must be
    ///      queue()d before execute() (adds the public delay window).
    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function proposalThreshold()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    /// @dev Called by queue(): schedules the batch in the ArthaTimelock
    ///      with salt = bytes20(address(this)) ^ descriptionHash and
    ///      delay = timelock.getMinDelay(). Returns eta (uint48).
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @dev Called by execute(): tells the timelock to run the batch.
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /// @dev Also unschedules from the timelock if already queued.
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /// @dev The address that ultimately performs calls = the TIMELOCK.
    ///      This is exactly why protocol contracts must set the timelock
    ///      (never the governor) as their admin/owner.
    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }
}
