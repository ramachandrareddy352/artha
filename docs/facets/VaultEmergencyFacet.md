# VaultEmergencyFacet

**Source:** `contracts/src/facets/VaultEmergencyFacet.sol`
**Access:** pause is `onlyGuardian`; unpause is `onlyGovernance`; `emergencyWithdraw` is open to anyone

## Purpose

Pause/unpause and the guaranteed, always-available exit path — deliberately separate from `VaultAdminFacet` and `VaultWithdrawFacet` so an emergency response never needs a multi-day governance proposal and never depends on the normal withdrawal machinery.

## Functions

- **`pauseVault(vault)` / `pauseProtocol()`** — `onlyGuardian`. Instant, no delay, no vote — an incident in progress cannot wait for governance.
- **`unpauseVault(vault)` / `unpauseProtocol()`** — `onlyGovernance` (the ArthaTimelock). Requires a full public proposal and delay window.
- **`emergencyWithdraw(vault, shares, receiver, owner) returns (uint256 assetsReceived)`** — open to anyone, no pause gate. Burns `shares` from `owner` UNCONDITIONALLY and pays out whatever base token could actually be gathered: idle first, then every strategy's own `emergencyWithdraw()` (skip harvest, no swaps, no slippage bound), best-effort per strategy via `try/catch`.

## Security notes

- **Pause is deliberately asymmetric.** A guardian can pause instantly but can NEVER unpause. This defeats a compromised guardian key pausing-then-immediately-unpausing as a distraction, or a rogue guardian repeatedly toggling pause to grief the protocol — the worst a compromised guardian key can do is pause (safe by construction: it only blocks new deposits and routes withdrawals to this slower, simpler path) and it can never undo that alone.
- **`emergencyWithdraw` never reverts on shortfall — the opposite of `VaultWithdrawFacet`'s atomic-revert behavior, on purpose.** The normal path reverting on a shortfall is correct because it can be retried later; THIS path exists specifically for when things are going wrong, so it must never trap a user. Shares are burned in full regardless of how much is actually recovered; if a strategy is genuinely drained (e.g. mid-exploit) its contribution is honestly zero rather than blocking every other holder's ability to exit through the strategies that still work.
- Any surplus a strategy gives up beyond one caller's own entitlement is credited back to `idleBalance` for everyone else — never lost or double-counted.
- Priced against the last checkpoint AS-IS — deliberately no `refreshNav` call here, to keep this path's external-call surface as small as possible exactly when that matters most.
- Not subject to the per-block withdrawal cap (`LibVaultCap`) — applying a rate limit to the guaranteed exit would directly contradict its purpose.
