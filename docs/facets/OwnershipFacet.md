# OwnershipFacet

**Source:** `contracts/src/facets/OwnershipFacet.sol`
**Access:** `owner()` is public view; `transferOwnership` is `onlyGovernance`

## Purpose

Standard ERC-173 ownership surface over `LibDiamond`'s stored `contractOwner`. The owner is the ArthaTimelock (see `ArthaTimelock.sol`'s header for why the timelock, not the governor, holds every protocol permission).

## Functions

- `owner() returns (address)` — reads `LibDiamond.contractOwner()`.
- `transferOwnership(address newOwner)` — `onlyGovernance`; rejects `address(0)`.

## Security notes

Transferring ownership is itself a full governance proposal (since only the current owner — the Timelock — may call this), never a single admin key action. There is no separate "admin" shortcut around this.
