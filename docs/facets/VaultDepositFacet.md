# VaultDepositFacet

**Source:** `contracts/src/facets/VaultDepositFacet.sol`
**Access:** anyone, subject to `whenVaultNotPaused`

## Purpose

The only way base token enters a vault. Model A: shares mint immediately, priced against the vault's current checkpointed NAV; deposited base token sits as idle balance until the keeper's next `deployIdle`/`rebalance` call.

## Functions

### `deposit(vault, assets, receiver, minSharesOut, deadline) returns (uint256 shares)`

Deposit an exact amount of base token, receive at least `minSharesOut` shares, minted to `receiver` (may differ from `msg.sender` — the same stake-for-another pattern `UserRewardVault.stake()` already uses).

### `mint(vault, shares, receiver, maxAssetsIn, deadline) returns (uint256 assets)`

Mint an exact amount of shares, paying at most `maxAssetsIn` base token.

## Order of operations (both functions)

1. Deadline + zero-amount checks.
2. `LibVaultNav.refreshNav(vault)` — checkpoint refreshed FIRST, before any pricing (this also crystallizes the performance fee if price-per-share reached a new high — see `LibVaultFee`).
3. Convert (rounding DOWN for `deposit`'s shares, UP for `mint`'s assets — see `docs/formulas.md` §2).
4. `assets >= minDeposit[vault]` — the dust-position floor.
5. Slippage check against the caller's bound.
6. TVL cap check (`navCheckpoint + assets <= tvlCap`, if a cap is set).
7. Per-block deposit cap check/consume (`LibVaultCap`).
8. Pull base token via a BALANCE-DELTA check (`received == assets`, not just trusting the requested amount — defends against a non-standard/fee-on-transfer token silently under-crediting the vault).
9. Mint shares to `receiver`.

## Security notes

- Both entry points require a `deadline` and a slippage bound because Model A prices against a checkpoint that can move between signing and inclusion (another deposit, a harvest, a withdrawal landing first in the same block).
- `shares == 0` always reverts (`ZERO_SHARES`) — never silently accepts a deposit that rounds to nothing.
- `nonReentrant`, and the balance-delta pull happens before the mint but the state-changing accounting update (`idleBalance`/`navCheckpoint`) is written using the CONFIRMED received amount, not the requested one.
