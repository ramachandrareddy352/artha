// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReferralSystem
 * @notice Interface the ReferralVault and the Diamond facets use to talk to the
 *         standalone ReferralSystem registry (normal external CALL).
 */
interface IReferralSystem {
    // ---- views the deposit flow / vault rely on ----

    /// @return owner The current owner of the code (address(0) if none/deactivated).
    /// @return tierId The code's tier.
    /// @return discountShare PPM share of each reward returned to the investor.
    function getReferrerInfoByCode(bytes32 code)
        external
        view
        returns (address owner, uint16 tierId, uint32 discountShare);

    /// @return code The code an investor has chosen.
    /// @return owner Its owner.
    /// @return tierId Its tier.
    /// @return discountShare Its investor share (PPM).
    function getReferrerInfoByTrader(address trader)
        external
        view
        returns (bytes32 code, address owner, uint16 tierId, uint32 discountShare);

    /// @notice Compact config the vault reads on every settlement.
    /// @return owner The code's current owner.
    /// @return tierMultPPM The code's tier reward multiplier in PPM (1e6 = 1.0x).
    function getRewardConfig(bytes32 code)
        external
        view
        returns (address owner, uint256 tierMultPPM);

    // ---- handler action (the ReferralVault is a registered handler) ----

    /// @notice Deactivate a code. Only callable by a registered handler.
    function deactivateCode(bytes32 code) external;
}
