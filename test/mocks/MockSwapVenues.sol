// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockERC20} from "./Mocks.sol";

/// Uniswap-V3-shaped router. Pays `rateBps` of the input, in the token the PATH names
/// last — which is deliberately not always the token the caller asked for.
contract MockV3Router {
    using SafeERC20 for IERC20;

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    uint256 public rateBps = 10_000;
    bool public payNothing;

    function setRateBps(uint256 r) external {
        rateBps = r;
    }

    function setPayNothing(bool on) external {
        payNothing = on;
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 amountOut) {
        address tokenIn = _tokenAt(p.path, 0);
        address tokenOut = _tokenAt(p.path, p.path.length - 20);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        if (payNothing) return 0;

        amountOut = (p.amountIn * rateBps) / 10_000;
        MockERC20(tokenOut).mint(p.recipient, amountOut);
    }

    function _tokenAt(bytes calldata path, uint256 offset) private pure returns (address token) {
        assembly {
            token := shr(96, calldataload(add(path.offset, offset)))
        }
    }
}

/// Uniswap-V2-shaped router.
contract MockV2Router {
    using SafeERC20 for IERC20;

    uint256 public rateBps = 10_000;

    function setRateBps(uint256 r) external {
        rateBps = r;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 out = (amountIn * rateBps) / 10_000;
        MockERC20(path[path.length - 1]).mint(to, out);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}

/// Curve-shaped pool.
contract MockCurveExchange {
    using SafeERC20 for IERC20;

    mapping(int128 => address) public coins;
    uint256 public rateBps = 10_000;
    bool public payWrongToken;
    address public wrongToken;

    function setCoin(int128 i, address token) external {
        coins[i] = token;
    }

    function setRateBps(uint256 r) external {
        rateBps = r;
    }

    function setPayWrongToken(bool on, address token) external {
        payWrongToken = on;
        wrongToken = token;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256) external returns (uint256) {
        IERC20(coins[i]).safeTransferFrom(msg.sender, address(this), dx);

        uint256 out = (dx * rateBps) / 10_000;
        address paid = payWrongToken ? wrongToken : coins[j];
        MockERC20(paid).mint(msg.sender, out);
        return out;
    }
}

/// Balancer-vault-shaped venue.
contract MockBalancerVault {
    using SafeERC20 for IERC20;

    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    uint256 public rateBps = 10_000;

    function setRateBps(uint256 r) external {
        rateBps = r;
    }

    function swap(SingleSwap calldata s, FundManagement calldata f, uint256, uint256)
        external
        payable
        returns (uint256)
    {
        IERC20(s.assetIn).safeTransferFrom(f.sender, address(this), s.amount);

        uint256 out = (s.amount * rateBps) / 10_000;
        MockERC20(s.assetOut).mint(f.recipient, out);
        return out;
    }
}

/// An aggregator router driven entirely by the caller's payload.
contract MockAggregatorRouter {
    using SafeERC20 for IERC20;

    /// Honest fill: pull `amountIn`, pay `amountOut` of `tokenOut`.
    function fill(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address to) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(to, amountOut);
    }

    /// Takes the input and pays nothing.
    function steal(address tokenIn, uint256 amountIn) external {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
    }

    /// Pays a token nobody asked for.
    function fillWrongToken(address tokenIn, address wrongToken, uint256 amountIn, uint256 amountOut, address to)
        external
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        MockERC20(wrongToken).mint(to, amountOut);
    }

    function boom() external pure {
        revert("ROUTER_REVERTED");
    }
}

/// Pyth-shaped oracle with a settable price, exponent and publish time.
contract MockPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    mapping(bytes32 => Price) private _prices;

    function setPrice(bytes32 id, int64 price, int32 expo, uint256 publishTime) external {
        _prices[id] = Price({price: price, conf: 0, expo: expo, publishTime: publishTime});
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory) {
        return _prices[id];
    }
}
