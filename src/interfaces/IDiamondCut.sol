// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDiamondCut — EIP-2535 upgrade interface (add / replace / remove selectors).
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

    /// @notice Add/replace/remove functions and optionally run an init delegatecall.
    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external;

    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);
}
