// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "./libraries/LibDiamond.sol";
import {IDiamondCut} from "./interfaces/IDiamondCut.sol";

/**
 * @title  Diamond
 * @notice The one address users, the keeper, and every integration ever call. Its
 *         own bytecode is nearly empty — a constructor that wires in DiamondCutFacet,
 *         and a fallback that looks up `msg.sig` in LibDiamond's selector map and
 *         `delegatecall`s into whichever facet implements it.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   WHY DELEGATECALL IS THE WHOLE POINT
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  A `delegatecall` runs the facet's CODE against the DIAMOND's STORAGE and the
 *  DIAMOND's `msg.sender`/`address(this)`. Concretely:
 *    - `AppStorage` (LibAppStorage, slot 0) and `LibDiamond`'s own storage (a fixed
 *      keccak slot) are read/written as if the facet's code ran directly in the
 *      Diamond — there is exactly one copy of every vault's state, ever.
 *    - `msg.sender` inside a facet is the ORIGINAL caller (the user, the keeper),
 *      not the Diamond. `address(this)` inside a facet is the DIAMOND's address,
 *      not the facet's. This is why `onlyVault` on every strategy contract is
 *      correct: when a facet calls `IStrategy(strategy).deposit(...)`, that is a
 *      normal external call FROM the Diamond (address(this) inside the facet is the
 *      Diamond), so the strategy sees `msg.sender == diamond` regardless of which
 *      facet triggered it.
 *    - Upgrading logic is therefore just re-pointing a selector via `diamondCut` —
 *      no storage migration, no redeploy, no address change. Nothing that holds a
 *      reference to the Diamond (share tokens, the oracle mapping, other protocols
 *      that integrate against it) ever needs to update anything.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   DEPLOYMENT ORDER 
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *   1. Deploy DiamondCutFacet (no constructor args — it only calls LibDiamond).
 *   2. Deploy Diamond(owner, diamondCutFacetAddress) — this constructor performs
 *      ONE diamondCut that adds DiamondCutFacet's own `diamondCut` selector, so the
 *      Diamond can immediately accept further cuts from `owner`.
 *   3. `owner` (the ArthaTimelock — see ArthaTimelock.sol's header for why the
 *      timelock and not the governor holds this) calls `diamondCut` repeatedly to
 *      add every other facet (Loupe, Ownership, VaultAdmin, VaultDeposit,
 *      VaultWithdraw, VaultHarvest, VaultView, VaultEmergency).
 */
contract Diamond {
    constructor(address _contractOwner, address _diamondCutFacet) payable {
        require(_contractOwner != address(0) && _diamondCutFacet != address(0), "ZERO_ADDRESS");

        LibDiamond.setContractOwner(_contractOwner);

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: _diamondCutFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: selectors
        });
        LibDiamond.diamondCut(cut, address(0), "");
    }

    /// @dev Every call that doesn't match a selector known to THIS contract (i.e.
    ///      every call, since the Diamond itself defines no other functions) lands
    ///      here and is forwarded to whichever facet LibDiamond has on file.
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address facet = ds.facetAddressAndSelectorPosition[msg.sig].facetAddress;
        require(facet != address(0), "Diamond: function does not exist");

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @dev Lets the Diamond hold native gas token if a facet ever needs it (e.g. to
    ///      forward to a strategy that wraps native ETH). No facet currently requires
    ///      this, but rejecting plain transfers outright would break `.transfer()`-
    ///      style sends from a facet's own logic during delegatecall.
    receive() external payable {}
}
