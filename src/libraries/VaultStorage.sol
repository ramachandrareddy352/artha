// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
                                CONSTANTS
//////////////////////////////////////////////////////////////////////////*/

// Basis-point denominator used everywhere in the vault (10_000 = 100%).
uint256 constant BPS_DENOMINATOR = 10_000;

// Admin-settable idle buffer is capped at 10% — a ceiling, never a hard target.
uint16 constant MAX_IDLE_BPS = 1_000;

// A vault may hold at most 5 active strategies. Keeps NAV computation,
// reallocation, and withdrawal draining bounded and reviewable.
uint256 constant MAX_STRATEGIES_PER_VAULT = 5;

// Fixed decimals for every vault's share token, independent of the base
// asset's own decimals. Required so the virtual-offset inflation defense
// behaves identically across every vault regardless of what it holds.
uint8 constant SHARE_DECIMALS = 18;

// Virtual-share exponent for the ERC-4626 inflation-attack defense.
// 10**DECIMALS_OFFSET virtual shares and 1 virtual asset are added on both
// sides of every conversion.
uint8 constant DECIMALS_OFFSET = 6;

// Price-per-share fixed-point scale (matches SHARE_DECIMALS).
uint256 constant PPS_SCALE = 1e18;

// Hard ceiling on performance fee, enforced in code (not just governance
// discretion). 3_000 = 30%.
uint16 constant MAX_PERFORMANCE_FEE_BPS = 3_000;

/*//////////////////////////////////////////////////////////////////////////
                               VAULT STORAGE
//////////////////////////////////////////////////////////////////////////*/
/**
 * @notice Per-vault storage, at a namespaced ERC-7201-style slot.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ONE DEPLOYED VAULT = ONE STORAGE. NO SHARED, VAULT-KEYED MAPPINGS.
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  Unlike the previous single-Diamond-many-vaults design (one AppStorage at
 *  slot 0 keyed by `address vault`), EVERY vault is now its OWN deployed
 *  `Vault` contract with its OWN copy of this struct. There is no `vault` key
 *  anywhere — a field like `idleBalance` is simply THIS vault's idle balance.
 *  Two vaults never share a slot, so one vault's accounting can never touch
 *  another's, and the base-asset custody is not commingled across vaults.
 *
 *  The struct lives at a fixed keccak slot (NOT slot 0), completely separate
 *  from anything the compiler might assign, so the router (`Vault`) and every
 *  delegatecalled facet read/write exactly the same layout.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE VAULT IS BOTH ROUTER AND CUSTODIAN
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  The `Vault` holds the base asset (idle) AND every DeFi receipt (aTokens,
 *  ERC-4626 shares, LP/gauge positions, venue-internal ledger balances credited
 *  to the vault). Strategies custody nothing — they are stateless executors the
 *  vault calls to invest/divest/harvest, with receipts always credited to, and
 *  redemptions always returned to, this vault.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   UPGRADE RULE
 *  ═══════════════════════════════════════════════════════════════════════════
 *  Append new fields ONLY at the end (before `__gap`, shrinking it). Never
 *  reorder or retype existing fields — the layout IS the vault's persistent
 *  state; a facet upgrade that changes it corrupts the vault.
 */
library VaultStorage {
    /// @dev ERC-7201-style namespaced slot: keccak of a domain string, minus 1,
    ///      masked to a 256-aligned slot.
    bytes32 internal constant STORAGE_SLOT =
        keccak256(abi.encode(uint256(keccak256("artha.vault.storage")) - 1)) & ~bytes32(uint256(0xff));

    struct Layout {
        // ============================ identity / roles ==========================
        /// @notice The base token (USDC, WETH, ...). Immutable in spirit, set at init.
        address baseAsset;
        uint8 baseDecimals;
        /// @notice This vault's own share ERC-20 (mint/burn only by this vault).
        address shareToken;
        /// @notice Governance (the ArthaTimelock). Sole config/upgrade authority.
        address governance;
        /// @notice Destination for the protocol's share of performance fees.
        address treasury;
        /// @notice Bounded automation identity: harvest / deployIdle / rebalance.
        mapping(address => bool) isKeeper;
        /// @notice May PAUSE this vault instantly; may NEVER unpause.
        mapping(address => bool) isGuardian;

        // ============================ flags / lock ==============================
        bool paused;
        /// @notice Reentrancy lock (false = not entered, true = entered).
        bool reentrancyLocked;
        /// @notice Set once by `initialize`, prevents re-initialization.
        bool initialized;

        // ============================ balances / NAV ============================
        /// @notice Base-token units held by this vault, un-deployed to any strategy.
        uint256 idleBalance;
        /// @notice Last computed totalAssets (idle + Σ strategy positionValue).
        uint256 navCheckpoint;

        // ============================ config ====================================
        uint16 idleTargetBps;
        uint256 minDeposit; // base-token units; 0 = no floor
        uint256 tvlCap; // base-token units; 0 = uncapped

        // ---- per-block flow caps ----
        uint256 depositCapPerBlock; // 0 = uncapped
        uint256 withdrawCapPerBlock; // 0 = uncapped
        mapping(address => bool) isCapExempt;
        uint256 depositFlowBlock;
        uint256 depositFlowAmount;
        uint256 withdrawFlowBlock;
        uint256 withdrawFlowAmount;

        // ---- fees ----
        uint16 performanceFeeBps;
        uint256 highWaterMarkPps; // PPS_SCALE fixed point
        uint16 harvestMaxImpactBps;

        // ============================ strategies ================================
        address[] strategies; // priority order; withdrawal drains index 0 first
        mapping(address => uint16) strategyWeightBps;
        mapping(address => bool) strategyDisabled; // blocks new deploys only
        mapping(address => bool) strategyBroken; // circuit-broken
        mapping(address => uint256) strategyLastValue;
        uint16 strategyMaxDeltaBps;

        // ============================ router ====================================
        mapping(bytes4 => address) selectorToFacet;

        // ------- APPEND NEW STORAGE BELOW THIS LINE ONLY -------
        uint256[50] __gap;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }
}

/*//////////////////////////////////////////////////////////////////////////
                     MODIFIERS  (inherited by every facet)
//////////////////////////////////////////////////////////////////////////*/
/**
 * @notice Shared access-control + reentrancy modifiers for every facet.
 *
 *  Facets are stateless logic delegatecalled by the `Vault`, so `address(this)`
 *  inside a facet is the vault instance and `VaultStorage.layout()` resolves to
 *  THAT vault's storage. These modifiers read roles straight out of it.
 *
 *  The reentrancy lock is a single shared storage flag (not per-facet), because
 *  every facet delegatecalls into the SAME storage — the lock must live at one
 *  fixed slot the whole vault agrees on.
 */
abstract contract VaultModifiers {
    modifier onlyGovernance() {
        require(msg.sender == VaultStorage.layout().governance, "NOT_GOVERNANCE");
        _;
    }

    modifier onlyKeeper() {
        require(VaultStorage.layout().isKeeper[msg.sender], "NOT_KEEPER");
        _;
    }

    modifier onlyGuardian() {
        require(VaultStorage.layout().isGuardian[msg.sender], "NOT_GUARDIAN");
        _;
    }

    modifier whenNotPaused() {
        require(!VaultStorage.layout().paused, "PAUSED");
        _;
    }

    modifier nonReentrant() {
        VaultStorage.Layout storage s = VaultStorage.layout();
        require(!s.reentrancyLocked, "REENTRANCY");
        s.reentrancyLocked = true;
        _;
        s.reentrancyLocked = false;
    }
}
