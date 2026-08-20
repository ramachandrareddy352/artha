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
uint8 constant MAX_STRATEGIES_PER_VAULT = 5;

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

// Hard ceiling on the flat native-ETH entry fee, so governance can never set an
// absurd toll. 0.1 ether.
uint96 constant MAX_ENTRY_FEE_WEI = 0.1 ether;

// How far a governance-confirmed circuit-breaker re-anchor may sit from the
// strategy's own live reading. Bounds `clearStrategyCircuitBreak` so a fat-finger
// can never mint NAV out of thin air. 500 = 5%.
uint16 constant CLEAR_ANCHOR_TOLERANCE_BPS = 500;

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
 *  The `Vault` contract is now its OWN deployed instance with its OWN copy of this struct. There is no `vault` key
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
        address shareToken; // 20B — this vault's own share ERC-20 (mint/burn by this vault)
        uint8 baseDecimals; //  1B
        uint16 idleTargetBps; //  2B
        uint16 performanceFeeBps; //  2B
        uint16 strategyMaxDeltaBps; //  2B — read in refreshNav's circuit breaker
        uint16 harvestMaxImpactBps; //  2B
        bool paused; //  1B — read first by whenNotPaused, warms the whole slot
        bool initialized; //  1B — set once at init, prevents re-initialization
        /// @notice 1 = not entered, 2 = entered.
        uint256 reentrancyStatus;
        address baseAsset; // the base token (USDC, WETH, ...)
        address governance; // the ArthaTimelock — sole config/upgrade authority
        address treasury; // destination for the protocol's fee shares
        // ═══════════════════════ roles / exemptions (mappings) ═══════════════════
        mapping(address => bool) isKeeper;
        mapping(address => bool) isGuardian;
        mapping(address => bool) isCapExempt; // used for other protocols want to invest in our protocol
        // ═══════════════════════ balances / NAV (hot writes, own slot) ═══════════
        uint256 idleBalance; // base held by this vault, un-deployed
        uint256 navCheckpoint; // last computed totalAssets
        uint256 highWaterMarkPps; // PPS_SCALE fixed point; ratchets up
        // ═══════════════════════ config limits (large, cold) ═════════════════════
        uint256 minDeposit; // base-token units; 0 = no floor
        uint256 tvlCap; // base-token units; 0 = uncapped
        uint256 depositCapPerBlock; // 0 = uncapped (bounded to uint192 in setters)
        uint256 withdrawCapPerBlock; // 0 = uncapped (bounded to uint192 in setters)
        // ═══════════════════════ per-block flow (packed pairs) ═══════════════════
        // block + cumulative amount are written together each capped op -> one slot.
        uint64 depositFlowBlock;
        uint192 depositFlowAmount;
        uint64 withdrawFlowBlock;
        uint192 withdrawFlowAmount;
        // ═══════════════════════ native-ETH entry fee (packed pair, 28B) ═════════
        // A flat ETH toll taken on every deposit/mint, pooled here as protocol-owned
        // ETH and withdrawable only by governance. Kept entirely separate from the
        // base-asset accounting above — user principal is never touched by it.
        uint96 entryFeeWei; // flat toll per invest; 0 = disabled (msg.value must be 0)
        uint128 collectedEthFees; // running total of tolls collected, admin-withdrawable
        // ═══════════════════════ strategies ══════════════════════════════════════
        address[] strategies; // priority order; withdrawal drains index 0 first
        mapping(address => uint16) strategyWeightBps;
        mapping(address => bool) strategyDisabled; // blocks new deploys only
        mapping(address => bool) strategyBroken; // circuit-broken
        mapping(address => uint256) strategyLastValue;
        // ═══════════════════════ router ══════════════════════════════════════════
        mapping(bytes4 => address) selectorToFacet;
        // ------- APPEND NEW STORAGE BELOW THIS LINE ONLY -------
        uint256[50] __gap;
    }

    function vaultLayout() internal pure returns (Layout storage s) {
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
 */
abstract contract VaultModifiers {
    modifier onlyGovernance() {
        require(msg.sender == VaultStorage.vaultLayout().governance, "NOT_GOVERNANCE");
        _;
    }

    modifier onlyKeeper() {
        require(VaultStorage.vaultLayout().isKeeper[msg.sender], "NOT_KEEPER");
        _;
    }

    modifier onlyGuardian() {
        require(VaultStorage.vaultLayout().isGuardian[msg.sender], "NOT_GUARDIAN");
        _;
    }

    modifier whenNotPaused() {
        require(!VaultStorage.vaultLayout().paused, "PAUSED");
        _;
    }

    modifier whenPaused() {
        require(VaultStorage.vaultLayout().paused, "NOT_PAUSED");
        _;
    }

    /// @dev OZ-style lock: a full word toggled 2<->1 (never 0), so each write is a
    ///      clean SSTORE with no bit-masking and never pays the zero->nonzero price.
    ///      `reentrancyStatus` is seeded to 1 in the Vault constructor.
    modifier nonReentrant() {
        VaultStorage.Layout storage s = VaultStorage.vaultLayout();
        require(s.reentrancyStatus != 2, "REENTRANCY");
        s.reentrancyStatus = 2;
        _;
        s.reentrancyStatus = 1;
    }
}
