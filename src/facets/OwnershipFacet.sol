// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC173} from "../interfaces/IERC173.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/**
 * @title  OwnershipFacet
 * @notice ERC-173 ownership. `owner` is the upgrade authority (holds diamondCut).
 *         Set it to the Timelock; transfer only through governance.
 */
contract OwnershipFacet is IERC173 {
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(_newOwner);
    }

    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }
}
