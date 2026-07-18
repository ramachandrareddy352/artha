// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  IDiamondCut
 * @notice EIP-2535 standard interface for adding, replacing, and removing facet
 *         functions. This is the ONLY way the protocol's logic is ever changed —
 *         every facet in this repo is upgradeable by cutting a new one in, without
 *         moving user funds or changing the Diamond's own address.
 *
 *  Add     — selector currently unassigned, point it at `facetAddress`.
 *  Replace — selector currently assigned elsewhere, repoint it at `facetAddress`.
 *  Remove  — selector currently assigned, unassign it (`facetAddress` must be
 *            address(0) for Remove — see LibDiamond.removeFunctions).
 */
interface IDiamondCut {
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    /// @notice Apply a batch of facet changes, then optionally delegatecall `_init`
    ///         with `_calldata` (e.g. to seed new storage fields the new facets need).
    ///         Pass `_init = address(0)` to skip initialization.
    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external;

    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);
}
