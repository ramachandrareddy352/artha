# DiamondLoupeFacet

**Source:** `contracts/src/facets/DiamondLoupeFacet.sol`
**Access:** anyone (all functions are `view`)

## Purpose

Standard EIP-2535 read-only inspection: lets a block explorer, monitoring bot, or curious user enumerate exactly which facet implements which function, with no special access.

## Functions

- `facets() returns (Facet[])` — every facet address and the selectors it implements.
- `facetFunctionSelectors(address facet) returns (bytes4[])` — all selectors implemented by one facet.
- `facetAddresses() returns (address[])` — every installed facet address.
- `facetAddress(bytes4 selector) returns (address)` — which facet implements one selector (`address(0)` = unassigned).
- `supportsInterface(bytes4) returns (bool)` — ERC-165, reads `LibDiamond`'s `supportedInterfaces` map.

## Security notes

These functions are never called from another on-chain transaction — only by off-chain tooling — so their O(n)/O(n²) loops (bounded by the total number of installed selectors, a small, governance-controlled number, never user-controlled input) are intentional and cannot be griefed.
