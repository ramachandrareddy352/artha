# VaultWithdrawFacet

**Source:** `contracts/src/facets/VaultWithdrawFacet.sol`
**Access:** anyone, subject to `whenVaultNotPaused` (during a pause, use `VaultEmergencyFacet.emergencyWithdraw` instead)

## Purpose

The normal exit path: drains idle first, then strategies in priority-queue order for any shortfall, with an implicit harvest step so a withdrawing user's shares reflect true realized value rather than the conservative haircut estimate.

## Functions

### `withdraw(vault, assets, receiver, owner, maxSharesBurned, deadline) returns (uint256 shares)`

Withdraw an exact amount of base token, burning at most `maxSharesBurned` shares of `owner`'s.

### `redeem(vault, shares, receiver, owner, minAssetsOut, deadline) returns (uint256 assets)`

Redeem an exact amount of shares, receiving at least `minAssetsOut` base token.

If `msg.sender != owner`, the caller must hold sufficient ERC-20 allowance over `owner`'s shares — `VaultShareToken.spendAllowance` (Diamond-only) decrements it the same way `transferFrom` would, since `burn` itself bypasses the standard transfer path entirely.

## Order of operations

**`withdraw`** (assets known up front, so harvest can be decided before pricing):
1. If `assets > idleBalance`, harvest every active (non-broken) strategy, best-effort (a stuck strategy's failure is swallowed, not fatal — see Security notes).
2. `refreshNav` — now includes any freshly realized reward value.
3. Convert assets → shares (rounding UP), check against `maxSharesBurned`.
4. `_drain` — idle first, then the priority queue for the shortfall; reverts the WHOLE transaction (`INSUFFICIENT_LIQUIDITY`) if the full amount can't be produced after walking every strategy.
5. Burn shares, transfer `assets` to `receiver`.

**`redeem`** (assets unknown until priced, so it's a two-pass price → maybe-harvest → re-price):
1. `refreshNav`, price `shares` → `assets` (rounding DOWN).
2. If that `assets` figure exceeds `idleBalance`, harvest all active strategies, `refreshNav` again, and RE-price `shares` → `assets` against the fresh post-harvest state.
3. Slippage check, `_drain`, burn, transfer — same as `withdraw`.

## Security notes

- **Atomic revert, never partial-fill.** If the strategy queue can't fully cover a shortfall, the entire transaction reverts — no partial burn, no partial payout. The user keeps their shares and can retry once liquidity recovers.
- **`_drain` keeps the circuit breaker's cache honest.** Pulling `got` from a strategy decrements `strategyLastValue[strategy]` by exactly `got`. Without this, the next `refreshNav` would compare the strategy's now-genuinely-lower `totalAssets()` against a STALE pre-withdrawal cached value — indistinguishable from a suspicious value drop, falsely tripping the breaker on a perfectly healthy strategy.
- **Harvest failures during a withdrawal are swallowed, not fatal** — unlike `VaultHarvestFacet.rebalance()`, where a failed harvest hard-reverts the whole reallocation. Blocking a user's WITHDRAWAL because of an unrelated strategy's temporary swap-slippage issue would trap funds; here, the withdrawal simply proceeds using that strategy's last-known (haircut-estimated) value instead.
- Broken (circuit-tripped) strategies are skipped entirely in both the harvest step and the drain — their capital is unavailable to this path until governance clears the flag.
