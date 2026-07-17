// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  IOracle
 * @notice Minimal price feed. Returns USD price in 8-decimal fixed point.
 */
interface IOracle {
    /// @param asset The base token.
    /// @return price USD price, 8 decimals (e.g. 1 USDC -> 1e8, 1 WETH -> 3000e8).
    function getPrice(address asset) external view returns (uint256 price);
}

/**
 * @title  IReferralVault
 * @notice Settlement surface (layer 3 of 3). Splits a vault's PERFORMANCE FEE
 *         between the protocol and the referrer, rebates part of the referrer's
 *         cut to the trader, and mints ARTHA on the referrer's gross commission.
 *
 *  ───────────────────────────── INTEGRATION ──────────────────────────────────
 *  Inside the vault's withdraw path, once the performance fee is known:
 *
 *      (uint256 ownerGross,
 *       uint256 ownerNet,
 *       uint256 discountAmount,
 *       uint256 protocolAmount,
 *       uint256 arthaAmount,
 *       uint64  code) = referralVault.getInfo(address(this), trader, perfFee);
 *
 *      if (ownerNet != 0 || discountAmount != 0) {
 *          base.approve(address(referralVault), ownerNet + discountAmount);
 *          referralVault.settlePerformanceFee(address(this), trader, perfFee);
 *          // referralVault pulls `ownerNet + discountAmount` via transferFrom and
 *          // forwards `discountAmount` straight to the trader.
 *      }
 *      // the vault keeps `protocolAmount` for the treasury.
 *
 *  getInfo is a pure VIEW and settlePerformanceFee recomputes the identical split
 *  internally, so the two can never disagree.
 */
interface IReferralVault {
    // ─────────────────────────────── types ──────────────────────────────────────

    /// @notice Config + lifetime books for one registered vault.
    struct VaultData {
        bool registered;
        uint8 decimals;             // base-token decimals (6..18)
        address baseAsset;          // the vault's single base token
        uint256 scale;              // 10^(18 - decimals); raw -> 18dp
        uint256 arthaRatio;         // ARTHA (18dp) per 1 USD of commission
        uint256 totalCommissionBase;// lifetime base paid out as referral commission (gross)
        uint256 totalDiscountBase;  // lifetime base rebated to traders
        uint256 totalProtocolBase;  // lifetime base retained by the protocol
        uint256 totalArthaEarned;   // lifetime ARTHA credited from this vault
    }

    /// @notice Per (code owner, vault) earnings ledger.
    struct Earning {
        uint256 totalEarnedBase;   // lifetime base commission, net of discount
        uint256 claimedBase;       // lifetime base claimed
        uint256 totalEarnedArtha;  // lifetime ARTHA credited
        uint256 claimedArtha;      // lifetime ARTHA claimed
    }

    /// @notice Per (code, vault) trader-side rebate ledger.
    struct UserData {
        uint256 totalDiscountBase; // lifetime base rebated to traders under this code
        uint256 totalVolumeBase;   // lifetime gross commission generated under this code
    }

    // ─────────────────────────────── events ─────────────────────────────────────

    event VaultRegistered(address indexed vault, address indexed baseAsset, uint8 decimals, uint256 arthaRatio);
    event ArthaRatioUpdated(address indexed vault, uint256 oldRatio, uint256 newRatio);
    event TierRewardRatioUpdated(address indexed vault, uint8 indexed tier, uint256 oldRatio, uint256 newRatio);
    event OracleUpdated(address oldOracle, address newOracle);

    event CommissionSettled(
        address indexed vault,
        uint64 indexed code,
        address indexed trader,
        uint256 performanceFee,
        uint256 ownerGross,
        uint256 ownerNet,
        uint256 discountAmount,
        uint256 protocolAmount,
        uint256 arthaAmount
    );
    event BaseClaimed(address indexed vault, uint64 indexed code, address indexed to, uint256 amount);
    event ArthaClaimed(address indexed vault, uint64 indexed code, address indexed to, uint256 amount);
    event ArthaCapReached(uint256 requested, uint256 granted, uint256 totalMinted);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ─────────────────────────────── constants ──────────────────────────────────

    /// @notice 100_000 = 100%, 1_000 = 1%.
    function RATIO_ONE() external view returns (uint32);

    /// @notice Global lifetime ARTHA budget for the referral programme (10,000,000e18).
    function MAX_ARTHA() external view returns (uint256);

    /// @notice Highest assignable tier id.
    function MAX_TIERS() external view returns (uint8);

    // ─────────────────────────────── views ──────────────────────────────────────

    function artha() external view returns (address);

    function oracle() external view returns (IOracle);

    /// @notice Lifetime ARTHA credited across all vaults (capped by MAX_ARTHA).
    function totalArthaMinted() external view returns (uint256);

    /// @notice ARTHA still available under the global cap.
    function arthaRemaining() external view returns (uint256);

    /// @notice vault => tier => referrer's share of the performance fee.
    ///         1_000 = 1%, 100_000 = 100%.
    function tierRewardRatio(address vault, uint8 tier) external view returns (uint256);

    function vaultData(address vault) external view returns (VaultData memory);

    /// @notice Ledger for one code owner in one vault.
    function earningOf(address vault, uint64 code) external view returns (Earning memory);

    /// @notice Trader-side rebate ledger for one code in one vault.
    function userDataOf(address vault, uint64 code) external view returns (UserData memory);

    // ─────────────────────── the vault integration helper ───────────────────────

    /**
     * @notice Price a performance fee split WITHOUT mutating state.
     * @param  vault           The vault paying the fee (its own address).
     * @param  trader          The position owner the fee was charged to.
     * @param  performanceFee  The full performance fee, raw base-token units.
     * @return ownerGross      Referrer's commission BEFORE the trader discount.
     * @return ownerNet        What the referrer actually banks (gross - discount).
     * @return discountAmount  Base rebated to the trader.
     * @return protocolAmount  Base the vault retains (performanceFee - ownerGross).
     * @return arthaAmount     ARTHA credited to the referrer, priced on ownerGross.
     * @return code            The trader's active code (0 => no referral at all).
     */
    function getInfo(address vault, address trader, uint256 performanceFee)
        external
        view
        returns (
            uint256 ownerGross,
            uint256 ownerNet,
            uint256 discountAmount,
            uint256 protocolAmount,
            uint256 arthaAmount,
            uint64 code
        );

    /**
     * @notice Execute the split. Pulls `ownerNet + discountAmount` of base from the
     *         calling vault (which must have approved at least that much) and
     *         forwards `discountAmount` to the trader immediately.
     * @dev    onlyCaller(vault): msg.sender MUST equal `vault`.
     * @return ownerGross      Referrer's commission BEFORE the trader discount.
     * @return ownerNet         What the referrer banks (gross - discount).
     * @return discountAmount   Base forwarded to the trader.
     * @return protocolAmount   Base the vault retains.
     * @return arthaAmount      ARTHA actually credited (may be capped).
     */
    function settlePerformanceFee(address vault, address trader, uint256 performanceFee)
        external
        returns (
            uint256 ownerGross,
            uint256 ownerNet,
            uint256 discountAmount,
            uint256 protocolAmount,
            uint256 arthaAmount
        );

    // ─────────────────────────────── claiming ───────────────────────────────────

    function claimBase(address vault, uint64 code, address to, uint256 amount) external;

    function claimArtha(address vault, uint64 code, address to, uint256 amount) external;

    /// @notice Claim all base + ARTHA for a code across every vault it earned in.
    function claimAll(uint64 code, address to) external;

    /// @notice Deactivate a code. Requires every balance (base AND ARTHA) claimed.
    function deactivateCode(uint64 code) external;

    // ─────────────────────────────── admin ──────────────────────────────────────

    function registerVault(address vault, address baseAsset, uint8 decimals, uint256 arthaRatio) external;

    function setArthaRatio(address vault, uint256 arthaRatio) external;

    function setTierRewardRatio(address vault, uint8 tier, uint256 ratio) external;

    function setOracle(address newOracle) external;

    function rescue(address token, address to, uint256 amount) external;
}
