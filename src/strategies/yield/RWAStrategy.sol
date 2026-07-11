// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626Strategy} from "./ERC4626Strategy.sol";

/**
 * @title  RWAStrategy  (tokenized real-world assets)
 * @notice Real-world-asset yield (tokenized T-bills / money-market funds) exposed
 *         as an ERC-4626 vault: e.g. Superstate USTB, Ondo (OUSG/USDY 4626 wrappers),
 *         BlackRock BUIDL feeder vaults. Same mechanics as ERC4626Strategy but with
 *         RWA-specific safety around redemption.
 *
 *  TWO THINGS THAT MAKE RWA DIFFERENT (and why this is its own adapter):
 *   1. KYC / permissioning — the RWA issuer must whitelist THIS adapter (and often
 *      the vault) as an allowed holder. Deploy the adapter, get it whitelisted with
 *      the issuer, THEN route funds. (Enforced off-chain by the issuer; the adapter
 *      simply reverts if a transfer is blocked.)
 *   2. Redemption can be delayed / capped — many RWA vaults only allow instant
 *      withdrawal up to a daily liquidity limit (the rest settles T+1). `_redeem`
 *      therefore checks `maxWithdraw` and reverts if the requested amount exceeds
 *      what can be pulled instantly, so callers fall back to in-kind withdrawal
 *      (the Diamond holds the RWA share and redeems later) instead of failing mid-tx.
 *
 *  Because of (2), size RWA with a conservative per-strategy cap and rely on the
 *  pool's idle buffer + in-kind withdrawal for user liquidity.
 */
contract RWAStrategy is ERC4626Strategy {
    constructor(address _vault, address _underlying, address _oracle, address _usdc, address _rwaVault4626)
        ERC4626Strategy(_vault, _underlying, _oracle, _usdc, _rwaVault4626)
    {}

    function _redeem(uint256 amount) internal override returns (uint256) {
        require(vault4626.maxWithdraw(address(this)) >= amount, "RWA_ILLIQUID_USE_INKIND");
        return super._redeem(amount);
    }
}
