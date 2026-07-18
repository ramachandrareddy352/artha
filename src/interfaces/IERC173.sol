// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IERC173 — standard ownership interface, used by OwnershipFacet.
interface IERC173 {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function owner() external view returns (address owner_);

    function transferOwnership(address _newOwner) external;
}
