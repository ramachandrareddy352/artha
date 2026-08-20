// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {ISwapper} from "../../src/strategies/interfaces/ISwapper.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockOracle {
    mapping(address => uint256) private _prices;
    mapping(address => bool) private _reverts;

    function setPrice(address token, uint256 price8dp) external {
        _prices[token] = price8dp;
    }

    function movePriceBps(address token, int256 bps) external {
        uint256 p = _prices[token];
        _prices[token] = bps >= 0 ? (p * (10_000 + uint256(bps))) / 10_000 : (p * (10_000 - uint256(-bps))) / 10_000;
    }

    function setReverting(address token, bool on) external {
        _reverts[token] = on;
    }

    function getPrice(address token) external view returns (uint256) {
        require(!_reverts[token], "ORACLE_DOWN");
        uint256 p = _prices[token];
        require(p != 0, "NOT_CONFIGURED");
        return p;
    }
}

contract MockSwapper is ISwapper {
    using SafeERC20 for IERC20;

    MockOracle public immutable oracle;
    uint256 public feeBps;
    bool public broken;

    constructor(address _oracle, uint256 _feeBps) {
        oracle = MockOracle(_oracle);
        feeBps = _feeBps;
    }

    function setFeeBps(uint256 _feeBps) external {
        feeBps = _feeBps;
    }

    function setBroken(bool _broken) external {
        broken = _broken;
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        uint256 pIn = oracle.getPrice(tokenIn);
        uint256 pOut = oracle.getPrice(tokenOut);
        uint256 out = Math.mulDiv(
            amountIn, pIn * (10 ** MockERC20(tokenOut).decimals()), pOut * (10 ** MockERC20(tokenIn).decimals())
        );
        return (out * (10_000 - feeBps)) / 10_000;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata)
        external
        override
        returns (uint256 amountOut)
    {
        require(!broken, "SWAPPER_BROKEN");
        amountOut = quote(tokenIn, tokenOut, amountIn);
        require(amountOut >= minOut, "MIN_OUT");
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(msg.sender, amountOut);
    }
}

contract MockERC4626 is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable assetToken;
    uint8 private immutable _decimals;
    uint256 public rate = 1e18;
    uint256 public liquidityCap = type(uint256).max;

    constructor(address _asset) ERC20("Mock 4626", "m4626") {
        assetToken = IERC20(_asset);
        _decimals = MockERC20(_asset).decimals();
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function accrueBps(uint256 bps) external {
        rate = (rate * (10_000 + bps)) / 10_000;
    }

    function setLiquidityCap(uint256 cap) external {
        liquidityCap = cap;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, rate, 1e18);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, 1e18, rate);
    }

    function maxWithdraw(address owner) public view returns (uint256) {
        uint256 mine = convertToAssets(balanceOf(owner));
        return mine < liquidityCap ? mine : liquidityCap;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        assetToken.safeTransferFrom(msg.sender, address(this), assets);
        shares = convertToShares(assets);
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(assets <= maxWithdraw(owner), "EXCEEDS_MAX");
        shares = convertToShares(assets);
        if (owner != msg.sender) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        _pay(receiver, assets);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        require(assets <= liquidityCap, "EXCEEDS_MAX");
        if (owner != msg.sender) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        _pay(receiver, assets);
    }

    function _pay(address receiver, uint256 assets) private {
        uint256 held = assetToken.balanceOf(address(this));
        if (held < assets) MockERC20(address(assetToken)).mint(address(this), assets - held);
        assetToken.safeTransfer(receiver, assets);
    }
}
