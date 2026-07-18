// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  IDiamondLoupe
 * @notice EIP-2535 standard read-only inspection interface. Lets anyone — a block
 *         explorer, a monitoring bot, a user — enumerate exactly which facet
 *         implements which function, with no special access. Never called from
 *         inside another on-chain transaction; it exists for external inspection,
 *         so the O(n) / O(n^2) loops in its implementation are intentional and safe.
 */
interface IDiamondLoupe {
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    /// @notice Every facet and the selectors it implements.
    function facets() external view returns (Facet[] memory facets_);

    /// @notice All selectors implemented by one facet.
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory facetFunctionSelectors_);

    /// @notice Every facet address currently installed.
    function facetAddresses() external view returns (address[] memory facetAddresses_);

    /// @notice Which facet implements one selector (address(0) = unassigned).
    function facetAddress(bytes4 _functionSelector) external view returns (address facetAddress_);
}
