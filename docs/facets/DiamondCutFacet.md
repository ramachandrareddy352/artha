# DiamondCutFacet

**Source:** `contracts/src/facets/DiamondCutFacet.sol`
**Access:** `onlyGovernance` (== `LibDiamond.contractOwner()` == the ArthaTimelock)

## Purpose

The only entry point for upgrading protocol logic. Every other facet's code can be added, replaced, or removed through this one function.

## Functions

### `diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata)`

Applies a batch of facet changes in one transaction:
- **Add** — a selector currently unassigned is pointed at a new facet address.
- **Replace** — a selector currently assigned elsewhere is repointed.
- **Remove** — a selector is unassigned (`facetAddress` must be `address(0)`).

After applying the cuts, if `_init != address(0)`, `_calldata` is `delegatecall`ed against `_init` — used to seed any new storage fields a freshly-added facet needs, in the same transaction as the cut itself.

## Security notes

- Gated to `LibDiamond.enforceIsContractOwner()` — since the owner is the ArthaTimelock, every logic upgrade already passed a public token vote (`ArthaGovernor`) and sat through the timelock's delay window before this can execute. There is no faster path to changing protocol logic.
- `LibDiamond.diamondCut`'s internal `addFunctions`/`replaceFunctions`/`removeFunctions` explicitly reject: adding a selector that already exists, replacing with the zero address, replacing a selector with the exact same facet it already points to, replacing/removing a selector that belongs to the Diamond's own immutable code (`address(this)`), and removing a selector that isn't currently assigned. See the reference EIP-2535 (diamond-3) implementation this follows.
