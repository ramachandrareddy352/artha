// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./sources/ChainlinkSource.sol";
import "./sources/PythSource.sol";

/**
 * @title  PriceFeed
 * @notice Multi-source price oracle. Every price returned is 8-decimal USD, matching
 *         Chainlink's own convention -- registered feeds are trusted to already
 *         report at that precision (see ChainlinkSource / PythSource).
 *
 *  Per token, per source, the admin registers a config (feed address / price id +
 *  a staleness bound). `getPrice(token)` with no source defaults to CHAINLINK;
 *  `getPrice(token, source)` reads a specific source explicitly. Sources never blend
 *  or cross-check each other automatically -- the caller picks one.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   ADDING A SOURCE LATER (DEX / LP / RWA / ...)
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  1. Append a value to PriceSource -- append ONLY, never reorder or remove existing
 *     entries. Their integer position is load-bearing the moment anything has been
 *     configured against them.
 *  2. Write a new sources/XSource.sol mixin (internal getXPrice(...) -> uint256,
 *     8dp), and inherit it here.
 *  3. Add its config mapping + admin setter/deleter, same shape as the Chainlink and
 *     Pyth ones below.
 *  4. Add its case to `_getPrice`.
 *
 *  A derived-price source (an LP token, for instance) needs the price of its own
 *  underlying tokens, not just one external call -- that's exactly what `_getPrice`
 *  is for: it's `internal`, so a future LP source mixin can call straight back into
 *  it for each underlying token, in the same contract, with no external call and no
 *  reentrancy surface. This is why the dispatch core is kept separate from the
 *  external `getPrice()` overloads instead of being inlined into them.
 */
contract PriceFeed is ChainlinkSource, PythSource {
    enum PriceSource {
        CHAINLINK,
        PYTH
    }

    struct ChainlinkConfig {
        address feed;
        uint256 maxStaleTime;
    }

    struct PythConfig {
        bytes32 priceId;
        uint256 maxStaleTime;
    }

    /// @notice The Pyth network contract for this chain. Immutable: this is
    ///         infrastructure wiring, not per-token config.
    address public immutable pyth;

    address public oracleAdmin;

    mapping(address token => ChainlinkConfig) public chainlinkConfigs;
    mapping(address token => PythConfig) public pythConfigs;

    event AdminUpdated(address oldAdmin, address newAdmin);
    event ChainlinkConfigUpdated(address indexed token, address indexed feed, uint256 maxStaleTime);
    event PythConfigUpdated(address indexed token, bytes32 priceId, uint256 maxStaleTime);

    modifier onlyAdmin() {
        require(oracleAdmin == msg.sender, "NOT_ORACLE_ADMIN");
        _;
    }

    constructor(address _oracleAdmin, address _pyth) {
        require(_oracleAdmin != address(0), "ZERO_ADDRESS");
        require(_pyth != address(0), "ZERO_ADDRESS");
        oracleAdmin = _oracleAdmin;
        pyth = _pyth;
    }

    // ------------------- ADMIN -------------------//

    function setAdmin(address _newOracleAdmin) external onlyAdmin {
        require(_newOracleAdmin != address(0), "ZERO_ADDRESS");

        emit AdminUpdated(oracleAdmin, _newOracleAdmin);
        oracleAdmin = _newOracleAdmin;
    }

    function setChainlinkConfig(address _token, address _feed, uint256 _maxStaleTime) external onlyAdmin {
        require(_token != address(0) && _feed != address(0), "ZERO_ADDRESS");
        require(_maxStaleTime >= 600, "INVALID_MAX_AGE"); // atleast 10 minutues

        chainlinkConfigs[_token] = ChainlinkConfig({feed: _feed, maxStaleTime: _maxStaleTime});

        emit ChainlinkConfigUpdated(_token, _feed, _maxStaleTime);
    }

    function deleteChainlinkConfig(address _token) external onlyAdmin {
        delete chainlinkConfigs[_token];
        emit ChainlinkConfigUpdated(_token, address(0), 0);
    }

    function setPythConfig(address _token, bytes32 _priceId, uint256 _maxStaleTime) external onlyAdmin {
        require(_token != address(0), "ZERO_ADDRESS");
        require(_priceId != bytes32(0), "INVALID_PRICE_ID");
        require(_maxStaleTime >= 600, "INVALID_MAX_AGE"); // atleast 10 minutues

        pythConfigs[_token] = PythConfig({priceId: _priceId, maxStaleTime: _maxStaleTime});

        emit PythConfigUpdated(_token, _priceId, _maxStaleTime);
    }

    function deletePythConfig(address _token) external onlyAdmin {
        delete pythConfigs[_token];
        emit PythConfigUpdated(_token, bytes32(0), 0);
    }

    // ------------------- READ PRICE ------------------- //

    /// @notice Price of `_token`, 8 decimals, using its default source (Chainlink).
    function getPrice(address _token) external view returns (uint256) {
        return _getPrice(_token, PriceSource.CHAINLINK);
    }

    /// @notice Price of `_token`, 8 decimals, from an explicitly chosen source.
    function getPrice(address _token, PriceSource _source) external view returns (uint256) {
        return _getPrice(_token, _source);
    }

    /// @dev The one dispatch point every source, present and future, resolves
    ///      through. See the contract header for why this is internal and separate
    ///      from the external getPrice() overloads.
    function _getPrice(address _token, PriceSource _source) internal view returns (uint256) {
        if (_source == PriceSource.CHAINLINK) {
            ChainlinkConfig memory config = chainlinkConfigs[_token];
            require(config.feed != address(0), "NOT_CONFIGURED");
            return getChainlinkPrice(config.feed, config.maxStaleTime);
        } else if (_source == PriceSource.PYTH) {
            PythConfig memory config = pythConfigs[_token];
            require(config.priceId != bytes32(0), "NOT_CONFIGURED");
            return getPythPrice(pyth, config.priceId, config.maxStaleTime);
        }
        revert("UNKNOWN_SOURCE");
    }
}
