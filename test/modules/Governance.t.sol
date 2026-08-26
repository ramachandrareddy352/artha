// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "openzeppelin-contracts/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "openzeppelin-contracts/contracts/governance/IGovernor.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {ArthaToken} from "../../src/governance/ArthaToken.sol";
import {ArthaTimelock} from "../../src/governance/ArthaTimelock.sol";
import {ArthaGovernor} from "../../src/governance/ArthaGovernor.sol";
import {Vault} from "../../src/Vault.sol";
import {DepositFacet} from "../../src/facets/DepositFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {StrategyFacet} from "../../src/facets/StrategyFacet.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {EmergencyFacet} from "../../src/facets/EmergencyFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {MockERC20} from "../mocks/Mocks.sol";

contract GovernanceTest is Test {
    uint256 internal constant CAP = 100_000_000e18;
    uint48 internal constant VOTING_DELAY = 1 days;
    uint32 internal constant VOTING_PERIOD = 5 days;
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000e18;
    uint256 internal constant QUORUM_NUMERATOR = 4;
    uint256 internal constant TIMELOCK_DELAY = 2 days;

    ArthaToken internal token;
    ArthaTimelock internal timelock;
    ArthaGovernor internal governor;
    Vault internal vault;
    MockERC20 internal usdc;

    address internal deployer = address(this);
    address internal whale = address(0x511A1E);
    address internal minnow = address(0x111);
    address internal guardian = address(0x6A11);

    function setUp() public {
        vm.warp(365 days);

        token = new ArthaToken(CAP, deployer);
        token.grantRole(token.MINTER_ROLE(), deployer);

        address[] memory empty = new address[](0);
        timelock = new ArthaTimelock(TIMELOCK_DELAY, empty, empty, deployer);

        governor = new ArthaGovernor(
            IVotes(address(token)),
            TimelockController(payable(address(timelock))),
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_NUMERATOR
        );

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));

        token.mint(whale, 20_000_000e18);
        token.mint(minnow, 1_000e18);

        vm.prank(whale);
        token.delegate(whale);
        vm.prank(minnow);
        token.delegate(minnow);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        _deployVaultGovernedByTimelock();

        vm.warp(block.timestamp + 1);
    }

    function _deployVaultGovernedByTimelock() internal {
        Vault.Facets memory f = Vault.Facets({
            deposit: address(new DepositFacet()),
            withdraw: address(new WithdrawFacet()),
            strategy: address(new StrategyFacet()),
            admin: address(new AdminFacet()),
            emergency: address(new EmergencyFacet()),
            view_: address(new ViewFacet())
        });

        Vault.InitConfig memory c = Vault.InitConfig({
            baseAsset: address(usdc),
            governance: address(timelock),
            treasury: address(0x77EA),
            keeper: address(0x6EE9E4),
            guardian: guardian,
            idleTargetBps: 1_000,
            performanceFeeBps: 0,
            strategyMaxDeltaBps: 5_000,
            harvestMaxImpactBps: 5_000,
            entryFeeWei: 0,
            minDeposit: 0,
            tvlCap: 0,
            depositCapPerBlock: 0,
            withdrawCapPerBlock: 0,
            name: "Artha Vault Share",
            symbol: "avSHARE"
        });

        vault = new Vault(c, f);
    }

    function _setFeeProposal(uint16 bps)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory desc)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(vault);
        values[0] = 0;
        calldatas[0] = abi.encodeCall(AdminFacet.setPerformanceFee, (bps));
        desc = "set performance fee";
    }

    function _propose(address proposer, uint16 bps) internal returns (uint256 id) {
        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _setFeeProposal(bps);
        vm.prank(proposer);
        id = governor.propose(t, v, c, d);
    }

    function _feeBps() internal view returns (uint16) {
        return ViewFacet(payable(address(vault))).vaultConfig().performanceFeeBps;
    }

    // ───────────────────────── G4: the full path works ──────────────────────────

    function test_G4_fullProposeVoteQueueExecuteReconfiguresTheVault() public {
        assertEq(_feeBps(), 0);

        uint256 id = _propose(whale, 1_500);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Pending));

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Active));

        vm.prank(whale);
        governor.castVote(id, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Succeeded));

        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _setFeeProposal(1_500);
        governor.queue(t, v, c, keccak256(bytes(d)));
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Queued));

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        governor.execute(t, v, c, keccak256(bytes(d)));

        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Executed));
        assertEq(_feeBps(), 1_500);
    }

    // ───────────────────────── G1: the delay is real ────────────────────────────

    function test_G1_executionBeforeTheTimelockDelayIsRefused() public {
        uint256 id = _propose(whale, 1_500);
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(whale);
        governor.castVote(id, 1);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _setFeeProposal(1_500);
        governor.queue(t, v, c, keccak256(bytes(d)));

        vm.expectRevert();
        governor.execute(t, v, c, keccak256(bytes(d)));

        assertEq(_feeBps(), 0);
    }

    function test_G1_executionAtExactlyTheDelayBoundarySucceeds() public {
        uint256 id = _propose(whale, 1_500);
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(whale);
        governor.castVote(id, 1);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _setFeeProposal(1_500);
        governor.queue(t, v, c, keccak256(bytes(d)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        governor.execute(t, v, c, keccak256(bytes(d)));
        assertEq(_feeBps(), 1_500);
    }

    // ─────────────────────── G2: threshold and quorum bind ──────────────────────

    function test_G2_aProposerBelowThresholdCannotPropose() public {
        vm.prank(minnow);
        vm.expectRevert();
        governor.propose(new address[](1), new uint256[](1), new bytes[](1), "nope");
    }

    function test_G2_aProposalThatMissesQuorumIsDefeated() public {
        uint256 id = _propose(whale, 1_500);
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(minnow);
        governor.castVote(id, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Defeated));

        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _setFeeProposal(1_500);
        vm.expectRevert();
        governor.queue(t, v, c, keccak256(bytes(d)));
    }

    function test_G2_aProposalVotedDownIsDefeated() public {
        uint256 id = _propose(whale, 1_500);
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(whale);
        governor.castVote(id, 0);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_G2_quorumIsAPercentageOfSupplyAtTheSnapshot() public {
        uint256 id = _propose(whale, 1_500);
        uint256 snapshot = governor.proposalSnapshot(id);
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        uint256 expected = (token.totalSupply() * QUORUM_NUMERATOR) / 100;
        assertEq(governor.quorum(snapshot), expected);
    }

    // ─────────────────── G3: voting power is snapshotted ────────────────────────

    function test_G3_tokensAcquiredAfterTheSnapshotCannotVote() public {
        uint256 id = _propose(whale, 1_500);
        uint256 snapshot = governor.proposalSnapshot(id);

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        address latecomer = address(0x1A7E);
        token.mint(latecomer, 30_000_000e18);
        vm.prank(latecomer);
        token.delegate(latecomer);
        vm.warp(block.timestamp + 1);

        assertEq(governor.getVotes(latecomer, snapshot), 0);

        vm.prank(latecomer);
        governor.castVote(id, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_G3_delegationMovesVotingPowerForFutureProposals() public {
        address delegatee = address(0xDE1E);

        vm.prank(whale);
        token.delegate(delegatee);
        vm.warp(block.timestamp + 1);

        uint256 id = _propose(delegatee, 1_500);
        uint256 snapshot = governor.proposalSnapshot(id);
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        assertEq(governor.getVotes(whale, snapshot), 0);
        assertGt(governor.getVotes(delegatee, snapshot), 0);

        vm.prank(delegatee);
        governor.castVote(id, 1);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Succeeded));
    }

    // ─────────────────────────── G5: cancellation ───────────────────────────────

    function test_G5_aQueuedProposalCanBeCancelledBeforeExecution() public {
        uint256 id = _propose(whale, 1_500);
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(whale);
        governor.castVote(id, 1);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _setFeeProposal(1_500);
        governor.queue(t, v, c, keccak256(bytes(d)));

        bytes32 salt = bytes20(address(governor)) ^ keccak256(bytes(d));
        bytes32 opId = timelock.hashOperationBatch(t, v, c, 0, salt);
        assertTrue(timelock.isOperationPending(opId));

        vm.prank(address(governor));
        timelock.cancel(opId);

        assertFalse(timelock.isOperation(opId));

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        vm.expectRevert();
        governor.execute(t, v, c, keccak256(bytes(d)));

        assertEq(_feeBps(), 0);
    }

    // ─────────────────── A1/A3: only the timelock governs the vault ─────────────

    function test_A1_theVaultRefusesAdminCallsFromAnyoneButTheTimelock() public {
        vm.prank(whale);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        AdminFacet(payable(address(vault))).setPerformanceFee(1_000);

        vm.prank(address(governor));
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        AdminFacet(payable(address(vault))).setPerformanceFee(1_000);

        vm.prank(address(timelock));
        AdminFacet(payable(address(vault))).setPerformanceFee(1_000);
        assertEq(_feeBps(), 1_000);
    }

    function test_A1_onlyTheGovernorMayProposeToTheTimelock() public {
        address[] memory t = new address[](1);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](1);
        t[0] = address(vault);
        c[0] = abi.encodeCall(AdminFacet.setPerformanceFee, (3_000));

        vm.prank(whale);
        vm.expectRevert();
        timelock.scheduleBatch(t, v, c, 0, bytes32(0), TIMELOCK_DELAY);
    }

    function test_A1_theGuardianCanPauseWithoutGovernanceButNotUnpause() public {
        vm.prank(guardian);
        EmergencyFacet(payable(address(vault))).pauseVault();
        assertTrue(ViewFacet(payable(address(vault))).vaultConfig().paused);

        vm.prank(guardian);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        EmergencyFacet(payable(address(vault))).unpauseVault();

        vm.prank(address(timelock));
        EmergencyFacet(payable(address(vault))).unpauseVault();
        assertFalse(ViewFacet(payable(address(vault))).vaultConfig().paused);
    }

    // ───────────────────────────── ARTHA token ──────────────────────────────────

    function test_G_tokenCapIsEnforced() public {
        uint256 remaining = CAP - token.totalSupply();
        token.mint(address(0xCAFE), remaining);

        vm.expectRevert();
        token.mint(address(0xCAFE), 1);
    }

    function test_G_onlyMinterRoleCanMint() public {
        vm.prank(whale);
        vm.expectRevert();
        token.mint(whale, 1e18);
    }

    function test_G_clockIsTimestampBased() public view {
        assertEq(token.clock(), uint48(block.timestamp));
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
    }
}
