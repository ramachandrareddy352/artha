// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";

/** 
 * @title  DiamondCutFacet
 * @notice The single entry point for upgrading protocol logic. Gated to the
 *         Diamond's `contractOwner` — the ArthaTimelock — so every facet change is a
 *         governance action that passed a public vote and sat through the timelock's
 *         delay window before it can execute (see ArthaTimelock.sol's header).
 */
contract DiamondCutFacet is IDiamondCut {
    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
    }
}
