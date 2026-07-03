// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {ArthaToken} from "../src/governance/ArthaToken.sol";
import {ArthaTimelock} from "../src/governance/ArthaTimelock.sol";
import {ArthaGovernor} from "../src/governance/ArthaGovernor.sol";

/*//////////////////////////////////////////////////////////////////////////
             ReferralMock — stands in for the ReferralVault proxy
//////////////////////////////////////////////////////////////////////////*/
/// @dev Same admin shape as the UUPS referral stack: single `admin` address
///      gates every privileged setter (and, on the real proxy,
///      _authorizeUpgrade). Governance takes over by becoming `admin`.
contract ReferralMock {
    address public admin;
    uint16 public referralBps;

    error NotAdmin();

    constructor(address _admin) {
        admin = _admin;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        admin = newAdmin;
    }

    function setReferralBps(uint16 bps) external onlyAdmin {
        referralBps = bps;
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        GovernanceLifecycleTest
//////////////////////////////////////////////////////////////////////////*/
contract GovernanceLifecycleTest is Test {
    /*----------------------------- config ----------------------------*/
    uint256 constant MIN_DELAY = 2 days;
    uint48 constant VOTING_DELAY = 1 days;
    uint32 constant VOTING_PERIOD = 5 days;
    uint256 constant THRESHOLD = 100_000e18;
    uint256 constant QUORUM_PCT = 4;
    uint256 constant CAP = 1_000_000_000e18;

    /*----------------------------- actors ----------------------------*/
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice"); //   60M ARTHA — whale, proposer
    address bob = makeAddr("bob"); //       37M ARTHA
    address carol = makeAddr("carol"); //    3M ARTHA — small holder
    address dave = makeAddr("dave"); //   1000  ARTHA — below threshold
    address guardian = makeAddr("guardian"); // veto multisig

    /*---------------------------- contracts --------------------------*/
    ArthaToken token;
    ArthaTimelock timelock;
    ArthaGovernor governor;
    ReferralMock referral;

    /*------------------------- shared proposal -----------------------*/
    // "Set referral fee share to 500 bps on the ReferralVault"
    address[] targets;
    uint256[] values;
    bytes[] calldatas;
    string constant DESCRIPTION = "ARP-1: set referral fee share to 500 bps";
    bytes32 descHash;

    function setUp() public {
        vm.startPrank(deployer);

        /*------------------------------------------------------------
          Token: mint & delegate.
          totalSupply = 60M + 37M + 3M + 1000 = 100_000_001_000e15...
          exactly: 100_000_000e18 + 1_000e18 = 100_001_000e18
          quorum   = 100_001_000e18 * 4 / 100 = 4_000_040e18
        ------------------------------------------------------------*/
        token = new ArthaToken(CAP, deployer);
        token.grantRole(token.MINTER_ROLE(), deployer);
        token.mint(alice, 60_000_000e18);
        token.mint(bob, 37_000_000e18);
        token.mint(carol, 3_000_000e18);
        token.mint(dave, 1_000e18);

        /*------------------------------------------------------------
          Timelock + Governor + role wiring (mirrors deploy script)
        ------------------------------------------------------------*/
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new ArthaTimelock(MIN_DELAY, proposers, executors, deployer);

        governor = new ArthaGovernor(
            token, timelock, VOTING_DELAY, VOTING_PERIOD, THRESHOLD, QUORUM_PCT
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), guardian);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        /*------------------------------------------------------------
          Referral target: admin handed to the TIMELOCK
        ------------------------------------------------------------*/
        referral = new ReferralMock(deployer);
        referral.transferAdmin(address(timelock));
        vm.stopPrank();

        // Voting power = 0 until delegated (ERC20Votes rule).
        vm.prank(alice);
        token.delegate(alice);
        vm.prank(bob);
        token.delegate(bob);
        vm.prank(carol);
        token.delegate(carol);
        vm.prank(dave);
        token.delegate(dave);

        // propose() reads votes at clock()-1; move 1s so the delegation
        // checkpoints written above are strictly in the past.
        vm.warp(block.timestamp + 1);

        // The proposal payload reused across tests.
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(referral);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(ReferralMock.setReferralBps, (500));
        descHash = keccak256(bytes(DESCRIPTION));
    }

    /*------------------------------ helpers --------------------------*/

    function _propose() internal returns (uint256 id) {
        vm.prank(alice); // 60M votes >= 100k threshold
        id = governor.propose(targets, values, calldatas, DESCRIPTION);
    }

    function _state(uint256 id) internal view returns (IGovernor.ProposalState) {
        return governor.state(id);
    }

    /*//////////////////////////////////////////////////////////////
        HAPPY PATH: propose -> vote -> queue -> execute
    //////////////////////////////////////////////////////////////*/
    function test_FullLifecycle_Execute() public {
        uint256 id = _propose();
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Pending));

        // ---- voting opens after votingDelay -------------------------
        vm.warp(governor.proposalSnapshot(id) + 1);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Active));

        vm.prank(alice);
        governor.castVote(id, 1); // For   (60M)
        vm.prank(bob);
        governor.castVote(id, 1); // For   (37M)
        vm.prank(carol);
        governor.castVote(id, 0); // Against (3M)

        (uint256 against, uint256 forV, uint256 abst) = governor.proposalVotes(id);
        assertEq(forV, 97_000_000e18);
        assertEq(against, 3_000_000e18);
        assertEq(abst, 0);

        // ---- voting closes: For > Against and quorum (4,000,040) met
        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Succeeded));

        // ---- queue into the timelock --------------------------------
        governor.queue(targets, values, calldatas, descHash);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Queued));

        // too early to execute: still inside minDelay
        vm.expectRevert();
        governor.execute(targets, values, calldatas, descHash);

        // ---- execute after minDelay (anyone can call) ---------------
        vm.warp(block.timestamp + MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descHash);

        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Executed));
        assertEq(referral.referralBps(), 500); // the timelock made the call
    }

    /*//////////////////////////////////////////////////////////////
        REJECTION 1: Against >= For  ->  Defeated, queue impossible
    //////////////////////////////////////////////////////////////*/
    function test_Rejected_AgainstWins() public {
        uint256 id = _propose();
        vm.warp(governor.proposalSnapshot(id) + 1);

        vm.prank(alice);
        governor.castVote(id, 0); // Against (60M)
        vm.prank(bob);
        governor.castVote(id, 1); // For     (37M)

        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Defeated));

        vm.expectRevert(); // GovernorUnexpectedProposalState
        governor.queue(targets, values, calldatas, descHash);
        assertEq(referral.referralBps(), 0);
    }

    /*//////////////////////////////////////////////////////////////
        REJECTION 2: quorum not met  ->  Defeated
        carol alone: 3M For+Abstain < 4,000,040 quorum
    //////////////////////////////////////////////////////////////*/
    function test_Rejected_QuorumNotMet() public {
        uint256 id = _propose();
        vm.warp(governor.proposalSnapshot(id) + 1);

        vm.prank(carol);
        governor.castVote(id, 1); // For, but only 3M

        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    /*//////////////////////////////////////////////////////////////
        REJECTION 3: proposer below threshold can't even create
        dave: 1_000e18 < 100_000e18
    //////////////////////////////////////////////////////////////*/
    function test_Rejected_BelowProposalThreshold() public {
        vm.prank(dave);
        vm.expectRevert(); // GovernorInsufficientProposerVotes
        governor.propose(targets, values, calldatas, DESCRIPTION);
    }

    /*//////////////////////////////////////////////////////////////
        REJECTION 4: proposer cancels while still Pending
    //////////////////////////////////////////////////////////////*/
    function test_ProposerCancel_WhilePending() public {
        uint256 id = _propose();

        vm.prank(alice); // only the proposer, only while Pending
        governor.cancel(targets, values, calldatas, descHash);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Canceled));

        // dead: voting can never open
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(bob);
        vm.expectRevert();
        governor.castVote(id, 1);
    }

    /*//////////////////////////////////////////////////////////////
        REJECTION 5: guardian veto DURING the timelock delay
        (malicious proposal passed the vote; guardian deletes it)
    //////////////////////////////////////////////////////////////*/
    function test_GuardianVeto_AfterQueue() public {
        uint256 id = _propose();
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(alice);
        governor.castVote(id, 1);
        vm.warp(governor.proposalDeadline(id) + 1);
        governor.queue(targets, values, calldatas, descHash);

        // Recompute the timelock operation id exactly like
        // GovernorTimelockControl does:
        //   salt = bytes20(governor) ^ descriptionHash
        //   id   = hashOperationBatch(targets, values, calldatas, 0, salt)
        bytes32 salt = bytes20(address(governor)) ^ descHash;
        bytes32 opId =
            timelock.hashOperationBatch(targets, values, calldatas, bytes32(0), salt);

        vm.prank(guardian);
        timelock.cancel(opId); // CANCELLER_ROLE, op still pending

        // Governor now reports Canceled; execution is impossible.
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Canceled));
        vm.warp(block.timestamp + MIN_DELAY + 1);
        vm.expectRevert();
        governor.execute(targets, values, calldatas, descHash);
        assertEq(referral.referralBps(), 0);
    }

    /*//////////////////////////////////////////////////////////////
        SNAPSHOT INTEGRITY: tokens bought after snapshot don't count
    //////////////////////////////////////////////////////////////*/
    function test_VotesLockedAtSnapshot() public {
        uint256 id = _propose();
        vm.warp(governor.proposalSnapshot(id) + 1);

        // dave receives 50M AFTER the snapshot...
        vm.prank(alice);
        token.transfer(dave, 50_000_000e18);

        // ...but his weight is still his snapshot power: 1_000e18.
        assertEq(governor.getVotes(dave, governor.proposalSnapshot(id)), 1_000e18);
    }
}
