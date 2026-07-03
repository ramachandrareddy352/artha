// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

import {ArthaToken} from "../../src/governance/ArthaToken.sol";
import {ArthaTimelock} from "../../src/governance/ArthaTimelock.sol";
import {ArthaGovernor} from "../../src/governance/ArthaGovernor.sol";
import {ReferralVault} from "../../src/referral/ReferralVault.sol";
import {MockDiamond} from "./MockDiamond.sol";

/*//////////////////////////////////////////////////////////////////////////
                 GovernanceTestBase  (shared test harness)
//////////////////////////////////////////////////////////////////////////*/
/**
 * @title  GovernanceTestBase
 * @notice One setUp for the WHOLE protocol under test, mirroring the real
 *         deploy script step by step:
 *
 *           1. ArthaToken   (cap 1B, deployer admin, deployer temp minter)
 *           2. ArthaTimelock(2d, [], [], deployer-as-temp-admin)
 *           3. ArthaGovernor(1d delay, 5d period, 100k threshold, 4% quorum)
 *           4. Wire roles   (governor -> PROPOSER + CANCELLER,
 *                            guardian -> CANCELLER, address(0) -> EXECUTOR,
 *                            deployer renounces timelock admin)
 *           5. ReferralVault implementation + ERC1967 proxy + initialize
 *           6. Seed         (codes, rates, vault funding, fake voters)
 *           7. HANDOFF      (referral admin -> timelock,
 *                            token DEFAULT_ADMIN_ROLE -> timelock)
 *
 *  FAKE-USER CAST (all made with makeAddr, funded by test-time minting):
 *
 *    proposer   200_000 ARTHA  — above the 100k proposal threshold
 *    whale   30_000_000 ARTHA  — single-handedly clears the 4M quorum
 *    voter2   5_000_000 ARTHA  — mid voter
 *    voter3   2_000_000 ARTHA  — small voter; ALONE it CANNOT reach quorum
 *    lateBuyer          0 now  — minted DURING a live proposal to prove the
 *                                snapshot rule (tokens after snapshot = 0 power)
 *    sleeper  3_000_000 ARTHA  — holds tokens from t0 but never delegates
 *                                until after a snapshot (delegation too late = 0)
 *
 *  SUPPLY / QUORUM MATH used everywhere in the tests:
 *    minted supply = 200k + 30M + 5M + 2M + 3M (sleeper) + 59.8M (treasury)
 *                  = 100_000_000 ARTHA
 *    quorum        = 4% * 100_000_000e18 = 4_000_000e18
 *    -> whale(30M) alone passes quorum; voter3(2M) alone fails it.
 *  (lateBuyer mints add to supply AFTER the snapshot, so they change neither
 *   the snapshot supply nor the quorum of an already-created proposal.)
 */
abstract contract GovernanceTestBase is Test {
    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant CAP = 1_000_000_000e18; // 1B ARTHA hard cap
    uint256 internal constant MIN_DELAY = 2 days;     // timelock delay
    uint48 internal constant VOTING_DELAY = 1 days;   // propose -> snapshot
    uint32 internal constant VOTING_PERIOD = 5 days;  // snapshot -> voteEnd
    uint256 internal constant PROPOSAL_THRESHOLD = 100_000e18;
    uint256 internal constant QUORUM_PERCENT = 4;     // 4% of supply

    // Pool rates seeded at deploy (ARTHA-wei / whole USDC / year)
    uint256 internal constant RATE_LOW = 0.5e18;
    uint256 internal constant RATE_MEDIUM = 0.75e18;
    uint256 internal constant RATE_HIGH = 1e18;

    uint256 internal constant VAULT_FUNDING = 5_000_000e18; // ARTHA pre-minted into the vault

    /*//////////////////////////////////////////////////////////////
                               CONTRACTS
    //////////////////////////////////////////////////////////////*/

    ArthaToken internal artha;
    ArthaTimelock internal timelock;
    ArthaGovernor internal governor;
    ReferralVault internal vault; // the PROXY, typed as the implementation
    MockDiamond internal diamond;

    /*//////////////////////////////////////////////////////////////
                                 CAST
    //////////////////////////////////////////////////////////////*/

    address internal guardian = makeAddr("guardian"); // veto-only multisig

    // governance actors
    address internal proposer = makeAddr("proposer");
    address internal whale = makeAddr("whale");
    address internal voter2 = makeAddr("voter2");
    address internal voter3 = makeAddr("voter3");
    address internal lateBuyer = makeAddr("lateBuyer");
    address internal sleeper = makeAddr("sleeper");
    address internal treasury = makeAddr("treasury");

    // referral actors
    address internal referrerA = makeAddr("referrerA");
    address internal referrerB = makeAddr("referrerB");
    address internal referrerC = makeAddr("referrerC");
    address internal investor1 = makeAddr("investor1");
    address internal investor2 = makeAddr("investor2");
    address internal investor3 = makeAddr("investor3");

    uint64 internal constant CODE_A = 1001;
    uint64 internal constant CODE_B = 1002;
    uint64 internal constant CODE_C = 1003;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        // Anchor away from t=0 so `clock()-1` style lookups never underflow.
        vm.warp(1_000_000);

        /*--------------------- 1. token ---------------------------*/
        artha = new ArthaToken(CAP, address(this));
        artha.grantRole(artha.MINTER_ROLE(), address(this)); // temp minter for seeding

        /*-------------------- 2. timelock -------------------------*/
        address[] memory noAddresses = new address[](0);
        timelock = new ArthaTimelock(MIN_DELAY, noAddresses, noAddresses, address(this));

        /*-------------------- 3. governor -------------------------*/
        governor = new ArthaGovernor(
            artha, timelock, VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD, QUORUM_PERCENT
        );

        /*------------------- 4. wire roles ------------------------*/
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), guardian); // emergency veto
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0)); // open execution
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        /*---------------- 5. referral vault (UUPS) ----------------*/
        ReferralVault impl = new ReferralVault();
        bytes memory initData =
            abi.encodeCall(ReferralVault.initialize, (address(this), address(artha)));
        vault = ReferralVault(address(new ERC1967Proxy(address(impl), initData)));

        diamond = new MockDiamond(address(vault));
        vault.setPool(address(diamond), true);

        /*----------------------- 6. seed --------------------------*/
        // fund the vault so claims can pay out (vault never mints)
        artha.mint(address(vault), VAULT_FUNDING);

        // referral codes for three fake referrers
        vault.createCode(CODE_A, referrerA);
        vault.createCode(CODE_B, referrerB);
        vault.createCode(CODE_C, referrerC);

        // initial pool rates: LOW 0.5 / MEDIUM 0.75 / HIGH 1.0 ARTHA/USDC/yr
        vault.setRate(0, RATE_LOW);
        vault.setRate(1, RATE_MEDIUM);
        vault.setRate(2, RATE_HIGH);

        // investors link their codes once (they never resend them)
        vm.prank(investor1);
        vault.setTraderCode(CODE_A);
        vm.prank(investor2);
        vault.setTraderCode(CODE_B);
        vm.prank(investor3);
        vault.setTraderCode(CODE_C);

        // fake ARTHA holders for governance (100M total supply)
        artha.mint(proposer, 200_000e18);
        artha.mint(whale, 30_000_000e18);
        artha.mint(voter2, 5_000_000e18);
        artha.mint(voter3, 2_000_000e18);
        artha.mint(sleeper, 3_000_000e18); // holds early, delegates late
        // treasury takes the remainder so totalSupply is exactly 100M
        // 100M - 200k - 30M - 5M - 2M - 3M - 5M(vault funding) = 54.8M
        artha.mint(treasury, 54_800_000e18);
        assertEq(artha.totalSupply(), 100_000_000e18, "supply must be exactly 100M");

        // voting power requires DELEGATION — sleeper deliberately skips this
        vm.prank(proposer);
        artha.delegate(proposer);
        vm.prank(whale);
        artha.delegate(whale);
        vm.prank(voter2);
        artha.delegate(voter2);
        vm.prank(voter3);
        artha.delegate(voter3);

        // Checkpoints are timepoint-keyed; move past the delegation second so
        // `getPastVotes(voter, clock()-1)` already reflects them.
        vm.warp(block.timestamp + 1);

        /*---------------------- 7. HANDOFF ------------------------*/
        // Referral vault admin -> TIMELOCK (the whole point of this setup:
        // every future createCode / setRate / rescue / upgrade is a proposal).
        vault.setReferralVaultManager(address(timelock));

        // Token role admin -> timelock; deployer steps down. Keep MINTER on
        // the test contract so tests can mint to actors mid-scenario (in
        // production the minter is the emissions controller).
        artha.grantRole(artha.DEFAULT_ADMIN_ROLE(), address(timelock));
        artha.renounceRole(artha.DEFAULT_ADMIN_ROLE(), address(this));
    }

    /*//////////////////////////////////////////////////////////////
                          PROPOSAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Build the 3-call "update reward rate for pools 0,1,2" payload.
    function _buildSetRatesProposal(uint256 rLow, uint256 rMed, uint256 rHigh)
        internal
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            string memory description
        )
    {
        targets = new address[](3);
        values = new uint256[](3);
        calldatas = new bytes[](3);

        targets[0] = address(vault);
        targets[1] = address(vault);
        targets[2] = address(vault);
        // values stay 0 — no ETH rides along

        calldatas[0] = abi.encodeCall(ReferralVault.setRate, (0, rLow));
        calldatas[1] = abi.encodeCall(ReferralVault.setRate, (1, rMed));
        calldatas[2] = abi.encodeCall(ReferralVault.setRate, (2, rHigh));

        description = "ARP-1: Update referral reward rates for pools 0, 1, 2";
    }

    /// @dev propose() as `proposer` and return the id.
    function _propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId) {
        vm.prank(proposer);
        proposalId = governor.propose(targets, values, calldatas, description);
    }

    /// @dev Warp to just AFTER the snapshot so the proposal is Active.
    function _rollToActive(uint256 proposalId) internal {
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
    }

    /// @dev Warp to just AFTER voteEnd so the outcome is final.
    function _rollToVoteEnd(uint256 proposalId) internal {
        vm.warp(governor.proposalDeadline(proposalId) + 1);
    }

    /// @dev Full happy tail: queue -> wait minDelay -> execute.
    function _queueAndExecute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal {
        bytes32 descHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descHash);
        vm.warp(block.timestamp + MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descHash);
    }

    /// @dev Read a pool's current rate from the struct getter tuple.
    function _rate(uint8 poolId) internal view returns (uint256 r) {
        (r,,,) = vault.poolState(poolId);
    }

    /// @dev IGovernor.ProposalState pretty assert.
    function _assertState(uint256 id, IGovernor.ProposalState expected) internal view {
        assertEq(uint8(governor.state(id)), uint8(expected), "unexpected proposal state");
    }
}
