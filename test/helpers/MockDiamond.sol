// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IReferralVault} from "../../src/referral/interfaces/IReferralVault.sol";

/*//////////////////////////////////////////////////////////////////////////
                          MockDiamond  (test helper)
//////////////////////////////////////////////////////////////////////////*/
/**
 * @title  MockDiamond
 * @notice Stands in for the Artha Diamond in tests and demo seeding.
 *
 *  In production, deposit/withdraw facets run INSIDE the Diamond via
 *  delegatecall, so when a facet calls the ReferralVault the msg.sender is
 *  the Diamond's own address — which is why the vault approves exactly one
 *  address with setPool(diamond, true).
 *
 *  This mock reproduces that calling pattern: tests call
 *  mockDiamond.deposit(...) and the vault sees msg.sender == address(this),
 *  i.e. the approved pool. It performs NO USDC accounting — the real vault
 *  never holds USDC either; it only receives principal *numbers* from the
 *  Diamond's already-settled deposit flow.
 */
contract MockDiamond {
    IReferralVault public immutable vault;

    constructor(address _vault) {
        vault = IReferralVault(_vault);
    }

    /// @notice Simulate a user's referred deposit landing in a risk pool.
    function deposit(uint8 poolId, address investor, uint256 principal) external {
        vault.notifyDeposit(poolId, investor, principal);
    }

    /// @notice Simulate a user's referred position shrinking / exiting.
    function withdraw(uint8 poolId, address investor, uint256 principal) external {
        vault.notifyWithdraw(poolId, investor, principal);
    }
}
