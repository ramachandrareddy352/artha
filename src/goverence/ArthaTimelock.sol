// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

/**
 * @title  ArthaTimelock
 * @notice THE single most important address in Artha governance.
 *
 *  ┌─────────────────────────────────────────────────────────────────────┐
 *  │  THE TIMELOCK — NOT THE GOVERNOR — IS THE ADMIN OF EVERYTHING.      │
 *  │                                                                     │
 *  │  ReferralVault proxy admin  ............ address(this timelock)    │
 *  │  _authorizeUpgrade gate  ............... address(this timelock)    │
 *  │  Diamond contractOwner  ................ address(this timelock)    │
 *  │  ArthaToken DEFAULT_ADMIN_ROLE  ........ address(this timelock)    │
 *  │  Vault fee / emission params owner  .... address(this timelock)    │
 *  │  Protocol treasury (fees, POL)  ........ held BY this timelock     │
 *  └─────────────────────────────────────────────────────────────────────┘
 *
 *  WHY THE TIMELOCK AND NOT THE GOVERNOR?
 *  --------------------------------------
 *  1. The delay is the security. Every admin action becomes publicly
 *     visible `minDelay` seconds before it can run. Users who disagree
 *     with a passed proposal have a guaranteed exit window to withdraw.
 *  2. The Governor is REPLACEABLE. If you ever ship GovernorV2 (new
 *     voting logic, different quorum), you pass ONE proposal that swaps
 *     PROPOSER_ROLE from old governor to new governor. Nothing that the
 *     timelock owns has to change — ownership never moves.
 *  3. If the Governor were the owner, a governor bug = protocol bug.
 *     Behind the timelock, a governor bug is contained: guardian cancels
 *     the malicious queued op and you rotate the governor.
 *
 *  ROLE MAP (TimelockController, OZ v5)
 *  ------------------------------------
 *  PROPOSER_ROLE   -> ArthaGovernor ONLY.
 *                     Only proposals that passed a token vote can be
 *                     scheduled into the timelock.
 *  CANCELLER_ROLE  -> ArthaGovernor + Guardian multisig.
 *                     Governor: cancels when a proposer drops below
 *                     threshold, etc. Guardian: emergency veto of a
 *                     malicious queued operation DURING the delay window.
 *                     The guardian can only DELETE queued ops — it can
 *                     never create or execute anything. Minimal trust.
 *  EXECUTOR_ROLE   -> address(0)  (open execution).
 *                     After the delay matures, ANYONE may call execute.
 *                     This is the Compound/Uniswap/ENS standard: it
 *                     removes "team refuses to press the button" as a
 *                     censorship vector. The payload is already fixed at
 *                     queue time, so open execution adds no attack surface.
 *  DEFAULT_ADMIN_ROLE (role admin of the three above)
 *                  -> address(this) — the timelock administers ITSELF.
 *                     The deployer holds it only during deployment wiring
 *                     and then renounces (see DeployGovernance.s.sol).
 *                     After that, granting/revoking any timelock role is
 *                     itself a governance proposal (target = timelock).
 *
 *  OPERATION LIFECYCLE INSIDE THE TIMELOCK
 *  ---------------------------------------
 *    scheduleBatch(targets, values, payloads, predecessor, salt, delay)
 *        └─ called by the Governor's queue(); stamps
 *           readyAt = block.timestamp + delay      (delay >= getMinDelay())
 *    ... minDelay seconds pass (public review window) ...
 *    executeBatch(...)   — anyone (EXECUTOR = address(0))
 *    cancel(id)          — CANCELLER only, while still pending
 *
 *  Example with minDelay = 172_800 (2 days):
 *    queued  at t = 1_760_000_000
 *    readyAt      = 1_760_000_000 + 172_800 = 1_760_172_800
 *    execute at any t >= 1_760_172_800 (ops never expire in OZ timelock)
 *
 *  CHANGING minDelay LATER
 *  -----------------------
 *  `updateDelay(uint256)` is gated to msg.sender == address(this), i.e. it
 *  can only run as an executed timelock operation -> requires a full
 *  governance proposal targeting this contract.
 */
contract ArthaTimelock is TimelockController {
    /**
     * @param minDelay   Seconds between queue and earliest execution.
     *                   Recommended: 172_800 (2 days).
     * @param proposers  Pass an EMPTY array at deployment — the Governor
     *                   does not exist yet; it is granted PROPOSER_ROLE +
     *                   CANCELLER_ROLE right after in the deploy script.
     * @param executors  Pass [address(0)] for open execution.
     * @param admin      TEMPORARY admin for wiring (the deployer). MUST
     *                   renounce after roles are granted. The timelock
     *                   always also self-holds DEFAULT_ADMIN_ROLE.
     */
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
}
