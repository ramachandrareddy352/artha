// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceFeed
/// @notice Integration surface for PriceFeed.sol. See PriceFeed's own header for the
///         multi-source design and how a future source (DEX / LP / RWA) slots in.
interface IPriceFeed {
    enum PriceSource {
        CHAINLINK,
        PYTH
    }

    event AdminUpdated(address oldAdmin, address newAdmin);
    event ChainlinkConfigUpdated(address indexed token, address indexed feed, uint256 maxStaleTime);
    event PythConfigUpdated(address indexed token, bytes32 priceId, uint256 maxStaleTime);

    // ── views ──

    function oracleAdmin() external view returns (address);
    function pyth() external view returns (address);

    function chainlinkConfigs(address token) external view returns (address feed, uint256 maxStaleTime);
    function pythConfigs(address token) external view returns (bytes32 priceId, uint256 maxStaleTime);

    /// @notice Price of `token`, 8 decimals, using its default source (Chainlink).
    function getPrice(address token) external view returns (uint256);

    /// @notice Price of `token`, 8 decimals, from an explicitly chosen source.
    function getPrice(address token, PriceSource source) external view returns (uint256);

    // ── admin ──

    function setAdmin(address newOracleAdmin) external;
    function setChainlinkConfig(address token, address feed, uint256 maxStaleTime) external;
    function deleteChainlinkConfig(address token) external;
    function setPythConfig(address token, bytes32 priceId, uint256 maxStaleTime) external;
    function deletePythConfig(address token) external;
}
