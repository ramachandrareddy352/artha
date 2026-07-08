// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../interfaces/IOracle.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (Price memory);
}

/**
 * @title  OracleAggregator
 * @notice SEPARATE price oracle (deployed like the referral vault, not a facet).
 *         Implements the IOracle the Diamond calls for NAV and the swap value-floor.
 *
 *  Per token you configure a Chainlink TOKEN/USD feed and/or a Pyth price id:
 *    - Chainlink only  -> use Chainlink, revert if stale.
 *    - Pyth only       -> use Pyth, revert if stale.
 *    - both            -> average them, but revert if they diverge > maxDivergenceBps.
 *
 *  USDC is treated as $1 (price 1e18, value == amount), so stable-denominated NAV
 *  needs no feed. All prices are normalized to "USDC per whole token, scaled 1e18".
 *
 *  SAFETY: staleness (updatedAt within maxDelay) and divergence checks make a
 *  single manipulated/frozen feed unable to mis-price the vault. Owner = Timelock.
 */
contract OracleAggregator is IOracle, Ownable {
    struct Feed {
        address chainlink;       // TOKEN/USD Chainlink feed (address(0) if unused)
        bytes32 pythId;          // Pyth price id (bytes32(0) if unused)
        uint8 tokenDecimals;     // decimals of the priced token
        uint32 maxDelay;         // staleness threshold (seconds)
        uint16 maxDivergenceBps; // max Chainlink/Pyth divergence when both are set
        bool set;
    }

    uint256 private constant WAD = 1e18;

    address public immutable usdc;
    IPyth public pyth; // optional global Pyth contract

    mapping(address => Feed) public feeds;

    event PythSet(address pyth);
    event FeedSet(
        address indexed token,
        address chainlink,
        bytes32 pythId,
        uint8 tokenDecimals,
        uint32 maxDelay,
        uint16 maxDivergenceBps
    );

    constructor(address _usdc, address _admin) Ownable(_admin) {
        require(_usdc != address(0), "ZERO_USDC");
        usdc = _usdc;
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function setPyth(address _pyth) external onlyOwner {
        pyth = IPyth(_pyth);
        emit PythSet(_pyth);
    }

    function setFeed(
        address token,
        address chainlink,
        bytes32 pythId,
        uint8 tokenDecimals,
        uint32 maxDelay,
        uint16 maxDivergenceBps
    ) external onlyOwner {
        require(token != address(0), "ZERO_TOKEN");
        require(chainlink != address(0) || pythId != bytes32(0), "NO_SOURCE");
        feeds[token] = Feed(chainlink, pythId, tokenDecimals, maxDelay, maxDivergenceBps, true);
        emit FeedSet(token, chainlink, pythId, tokenDecimals, maxDelay, maxDivergenceBps);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice USDC per whole token, scaled 1e18.
    function price(address token) public view override returns (uint256) {
        if (token == usdc) return WAD;
        Feed memory f = feeds[token];
        require(f.set, "FEED_NOT_SET");

        bool hasCl = f.chainlink != address(0);
        bool hasPy = f.pythId != bytes32(0) && address(pyth) != address(0);

        uint256 clPrice = hasCl ? _chainlink1e18(f.chainlink, f.maxDelay) : 0;
        uint256 pyPrice = hasPy ? _pyth1e18(f.pythId, f.maxDelay) : 0;

        if (hasCl && hasPy) {
            uint256 hi = clPrice > pyPrice ? clPrice : pyPrice;
            uint256 lo = clPrice > pyPrice ? pyPrice : clPrice;
            require((hi - lo) * 10000 <= hi * f.maxDivergenceBps, "ORACLE_DIVERGENCE");
            return (clPrice + pyPrice) / 2;
        }
        return hasCl ? clPrice : pyPrice;
    }

    /// @notice USDC (6dp) value of `amount` raw units of `token`.
    function valueInUsdc(address token, uint256 amount) external view override returns (uint256) {
        if (token == usdc) return amount;
        Feed memory f = feeds[token];
        require(f.set, "FEED_NOT_SET");
        uint256 p = price(token); // 1e18 USDC per whole token
        // value(6dp) = amount * p / (10^tokenDecimals * 1e12)
        return (amount * p) / (10 ** f.tokenDecimals * 1e12);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _chainlink1e18(address feed, uint32 maxDelay) internal view returns (uint256) {
        IAggregatorV3 agg = IAggregatorV3(feed);
        (, int256 answer,, uint256 updatedAt,) = agg.latestRoundData();
        require(answer > 0, "BAD_PRICE");
        require(block.timestamp - updatedAt <= maxDelay, "STALE_PRICE");
        uint8 dec = agg.decimals();
        return (uint256(answer) * WAD) / (10 ** dec);
    }

    function _pyth1e18(bytes32 id, uint32 maxDelay) internal view returns (uint256) {
        IPyth.Price memory p = pyth.getPriceNoOlderThan(id, maxDelay);
        require(p.price > 0, "BAD_PRICE");
        uint256 raw = uint256(uint64(p.price));
        int32 expo = p.expo;
        if (expo <= 0) {
            return (raw * WAD) / (10 ** uint256(uint32(-expo)));
        }
        return raw * WAD * (10 ** uint256(uint32(expo)));
    }
}
