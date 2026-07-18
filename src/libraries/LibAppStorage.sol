// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "./LibDiamond.sol";

/*//////////////////////////////////////////////////////////////////////////
                                CONSTANTS
//////////////////////////////////////////////////////////////////////////*/

// Basis-point denominator used everywhere in the vault (10_000 = 100%).
uint256 constant BPS_DENOMINATOR = 10_000;

// Admin-settable idle buffer is capped at 10% — the range this design
// discussion settled on. Never a hard-coded target, only a ceiling on it.
uint16 constant MAX_IDLE_BPS = 1_000;

// A vault may hold at most 5 active strategies. Keeps NAV computation,
// reallocation, and withdrawal draining bounded and reviewable — a vault
// with an unbounded strategy list is a vault whose gas cost and attack
// surface nobody can reason about.
uint256 constant MAX_STRATEGIES_PER_VAULT = 5;

// Fixed decimals for every vault's share token, independent of the base
// asset's own decimals (6 for USDC, 18 for WETH, 8 for WBTC, ...). Required
// so the virtual-offset inflation defense behaves identically across every
// vault regardless of what it holds.
uint8 constant SHARE_DECIMALS = 18;

// Virtual-share exponent for the ERC-4626 inflation-attack defense (OZ's
// decimals-offset approach). 10**DECIMALS_OFFSET virtual shares and 1
// virtual asset are added on both sides of every conversion, making it
// economically irrational to seed 1 wei and donate a large balance to
// round a second depositor's mint to zero — see LibVaultMath's header.
uint8 constant DECIMALS_OFFSET = 6;

// Price-per-share fixed-point scale (matches SHARE_DECIMALS).
uint256 constant PPS_SCALE = 1e18;

// Hard ceiling on performance fee, enforced in code (not just governance
// discretion) — a safety rail against a governance mistake or compromise setting
// an extractive fee. 3_000 = 30%.
uint16 constant MAX_PERFORMANCE_FEE_BPS = 3_000;

/*//////////////////////////////////////////////////////////////////////////
                               APP STORAGE
//////////////////////////////////////////////////////////////////////////*/
/**
 * @notice The single shared storage struct for the whole protocol Diamond, at slot 0.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ONE DIAMOND, MANY VAULTS, EACH VAULT KEYED BY ITS OWN SHARE-TOKEN ADDRESS
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Every vault (a USDC vault, a WETH vault, an LP vault, ...) is a row in this
 *  struct's mappings, keyed by `address vault`. That key IS the address of the
 *  vault's own `VaultShareToken` — a minimal ERC-20 deployed once per vault by
 *  `VaultAdminFacet.createVault`, minted/burned ONLY by this Diamond. Using the
 *  share token's own address as the key (rather than inventing a parallel uint256
 *  vault id) means every already-built external module that keys by "vault"
 *  (ReferralVault.registerVault, UserRewardVault.registerVault — both take a `vault`
 *  address distinct from `shareToken`/`baseAsset`) can be pointed at this same
 *  address with zero changes to that code.
 *
 *  Shares themselves are NOT tracked in this struct — `IERC20(vault).totalSupply()`
 *  and `balanceOf` on the VaultShareToken are the single source of truth. Keeping
 *  share accounting out of AppStorage and in a real transferable ERC-20 is what lets
 *  UserRewardVault's `stake()` pull a user's shares via a plain `transferFrom` with
 *  no Diamond involvement at all.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   UPGRADE RULE
 *  ═══════════════════════════════════════════════════════════════════════════
 *  Append new fields ONLY at the end. Adding mapping keys is always safe. Never
 *  reorder or retype existing fields — this struct's layout IS the protocol's
 *  persistent state; a facet upgrade that changes the layout corrupts every vault.
 */
struct AppStorage {
    // ============================ protocol-wide ==============================
    // NOTE: there is deliberately no separate `governance` address stored here.
    // `LibDiamond.contractOwner()` (== the ArthaTimelock — the same address that
    // may `diamondCut` new logic in) IS governance. Duplicating that address in a
    // second field risks the two drifting apart if one is ever updated without the
    // other; `Modifiers.onlyGovernance` reads `LibDiamond.contractOwner()` directly.

    /// @notice Bounded automation identity: harvest / deployIdle / rebalance calls.
    ///         Deliberately weak — a compromised keeper can waste gas or delay yield,
    ///         never move funds outside the vault's own strategies or bypass caps.
    mapping(address => bool) isKeeper;

    /// @notice May PAUSE a vault (or the whole protocol) instantly. May NEVER
    ///         unpause — see VaultEmergencyFacet for why that split is deliberate.
    mapping(address => bool) isGuardian;

    /// @notice Destination for the protocol's share of performance fees.
    address treasury;

    /// @notice Protocol-wide kill switch, independent of any single vault's pause.
    bool globalPaused;

    /// @notice Shared Diamond-storage reentrancy lock. Declared HERE — not inherited
    ///         separately by each facet via OZ's ReentrancyGuard — because a facet's
    ///         own contract only supplies CODE; every facet delegatecalls into the
    ///         SAME storage, so the lock must live at one fixed AppStorage slot that
    ///         every facet's `nonReentrant` modifier reads through `Modifiers.s`.
    ///         Relying on each facet inheriting OZ's ReentrancyGuard independently
    ///         would only coincidentally share a slot (whatever the compiler assigns
    ///         based on that facet's own inheritance order) — fragile, not designed.
    uint256 _reentrancyStatus; // 1 = not entered, 2 = entered

    // ============================ vault registry ==============================

    /// @notice Every vault's share-token address, in creation order. Bounds admin
    ///         iteration (e.g. a protocol-wide pause sweep); never iterated in a
    ///         user-facing call.
    address[] allVaults;
    mapping(address => bool) isVault;

    // ============================ vault config =================================
    // Flattened, vault-address-keyed — mirrors the proven poolId-keyed layout this
    // protocol already used for its (superseded) multi-pool design, generalized
    // from a fixed 6-pool set to an arbitrary number of single-asset vaults.

    mapping(address => address) baseAsset;
    mapping(address => uint8) baseDecimals;

    /// @notice Base-token units currently held by the Diamond for this vault,
    ///         un-deployed to any strategy. Tracked explicitly (not `balanceOf`)
    ///         because the Diamond commingles custody across every vault's base
    ///         asset in its own token balances — this is the per-vault ledger that
    ///         keeps them separate. Strategy withdrawals are also cases where
    ///         `withdraw` amounts settle first go through this bucket.
    mapping(address => uint256) idleBalance;

    /// @notice Admin-set idle-buffer TARGET, 0..MAX_IDLE_BPS (0-10%). Actual idle
    ///         can exceed this: strategy target weights are allowed to sum to less
    ///         than `BPS_DENOMINATOR - idleTargetBps`, intentionally widening the
    ///         buffer beyond the stated target during a cautious period.
    mapping(address => uint16) idleTargetBps;

    mapping(address => uint256) minDeposit; // base-token units; 0 = no floor
    mapping(address => uint256) tvlCap; // base-token units; 0 = uncapped

    // ---- per-block flow caps (fixed, governance-set, base-token units) ----
    mapping(address => uint256) depositCapPerBlock; // 0 = uncapped
    mapping(address => uint256) withdrawCapPerBlock; // 0 = uncapped
    mapping(address => mapping(address => bool)) isCapExempt; // vault => address => exempt
    mapping(address => uint256) depositFlowBlock; // vault => last block tracked
    mapping(address => uint256) depositFlowAmount; // vault => cumulative flow that block
    mapping(address => uint256) withdrawFlowBlock;
    mapping(address => uint256) withdrawFlowAmount;

    // ---- fees ----
    mapping(address => uint16) performanceFeeBps;
    /// @notice Aggregate high-water mark, price-per-share, PPS_SCALE (1e18) fixed
    ///         point. Fee is only ever charged on NEW profit above this mark.
    mapping(address => uint256) highWaterMarkPps;

    // ---- NAV checkpoint (see LibVaultNav) ----
    mapping(address => uint256) navCheckpoint; // base-token units, last computed totalAssets

    // ---- pause ----
    mapping(address => bool) vaultPaused;

    // ---- harvest outer sanity ceiling (separate from each strategy's own
    //      maxSlippageBps — see VaultHarvestFacet) ----
    mapping(address => uint16) harvestMaxImpactBps;

    // ============================ strategies (per vault) =======================

    /// @notice Priority-ordered strategy list (withdrawal drains index 0 first).
    ///         Length never exceeds MAX_STRATEGIES_PER_VAULT.
    mapping(address => address[]) strategies;
    mapping(address => mapping(address => uint16)) strategyWeightBps; // vault => strategy => target
    mapping(address => mapping(address => bool)) strategyDisabled; // blocks new deploys only
    mapping(address => mapping(address => bool)) strategyBroken; // circuit-broken: excluded from NAV/alloc

    /// @notice Last observed `totalAssets()` per strategy, for the NAV circuit
    ///         breaker (LibVaultNav) — a jump beyond `strategyMaxDeltaBps` between
    ///         two reads trips `strategyBroken` instead of trusting the new value.
    mapping(address => mapping(address => uint256)) strategyLastValue;
    mapping(address => uint16) strategyMaxDeltaBps;

    // ------- APPEND NEW STORAGE BELOW THIS LINE ONLY -------
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
                        MODIFIERS  (inherited by every vault facet)
//////////////////////////////////////////////////////////////////////////*/

contract Modifiers {
    AppStorage internal s;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier onlyGovernance() {
        require(msg.sender == LibDiamond.contractOwner(), "NOT_GOVERNANCE");
        _;
    }

    modifier onlyKeeper() {
        require(s.isKeeper[msg.sender], "NOT_KEEPER");
        _;
    }

    modifier onlyGuardian() {
        require(s.isGuardian[msg.sender], "NOT_GUARDIAN");
        _;
    }

    modifier onlyRegisteredVault(address vault) {
        require(s.isVault[vault], "NOT_A_VAULT");
        _;
    }

    modifier whenProtocolNotPaused() {
        require(!s.globalPaused, "PROTOCOL_PAUSED");
        _;
    }

    modifier whenVaultNotPaused(address vault) {
        require(!s.globalPaused, "PROTOCOL_PAUSED");
        require(!s.vaultPaused[vault], "VAULT_PAUSED");
        _;
    }

    /// @dev ONE lock shared by every facet, at a fixed AppStorage slot — see the
    ///      struct's `_reentrancyStatus` doc for why this must not be per-facet.
    modifier nonReentrant() {
        require(s._reentrancyStatus != _ENTERED, "REENTRANCY");
        s._reentrancyStatus = _ENTERED;
        _;
        s._reentrancyStatus = _NOT_ENTERED;
    }
}
