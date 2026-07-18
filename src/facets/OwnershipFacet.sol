// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC173} from "../interfaces/IERC173.sol";

/// @title  OwnershipFacet
/// @notice Standard ERC-173 ownership surface over LibDiamond's `contractOwner`.
///         The owner is the ArthaTimelock — see ArthaTimelock.sol's header for why
///         ownership transfer itself is therefore a full governance proposal, never
///         a single admin call.
contract OwnershipFacet is IERC173 {
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        require(_newOwner != address(0), "ZERO_ADDRESS");
        LibDiamond.setContractOwner(_newOwner);
    }

    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }
}
