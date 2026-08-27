// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {UniswapV3Swapper} from "../../src/strategies/swap/UniswapV3Swapper.sol";
import {UniswapV2Swapper} from "../../src/strategies/swap/UniswapV2Swapper.sol";
import {CurveSwapper} from "../../src/strategies/swap/CurveSwapper.sol";
import {BalancerV2Swapper} from "../../src/strategies/swap/BalancerV2Swapper.sol";
import {AggregatorSwapper} from "../../src/strategies/swap/AggregatorSwapper.sol";
import {RoutedSwapper} from "../../src/strategies/swap/RoutedSwapper.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {
    MockV3Router,
    MockV2Router,
    MockCurveExchange,
    MockBalancerVault,
    MockAggregatorRouter
} from "../mocks/MockSwapVenues.sol";

abstract contract SwapperBase is Test {
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    MockERC20 internal decoy;

    address internal caller = address(0xCA11E2);

    function _setUpTokens() internal {
        tokenIn = new MockERC20("In", "IN", 18);
        tokenOut = new MockERC20("Out", "OUT", 6);
        decoy = new MockERC20("Decoy", "DEC", 18);
        tokenIn.mint(caller, 1_000_000e18);
    }

    function _approve(address spender) internal {
        vm.prank(caller);
        tokenIn.approve(spender, type(uint256).max);
    }
}

contract UniswapV3SwapperTest is SwapperBase {
    MockV3Router internal router;
    UniswapV3Swapper internal swapper;

    function setUp() public {
        _setUpTokens();
        router = new MockV3Router();
        swapper = new UniswapV3Swapper(address(router));
        _approve(address(swapper));
    }

    function _path(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, uint24(500), b);
    }

    function test_O5_happyPathDeliversToTheCallerAndClearsApproval() public {
        vm.prank(caller);
        uint256 out = swapper.swap(
            address(tokenIn), address(tokenOut), 1_000e18, 900e18, _path(address(tokenIn), address(tokenOut))
        );

        assertEq(out, 1_000e18);
        assertEq(tokenOut.balanceOf(caller), 1_000e18);
        assertEq(tokenIn.allowance(address(swapper), address(router)), 0);
    }

    function test_O5_minOutIsEnforcedOnTheMeasuredDelta() public {
        router.setRateBps(8_000);

        vm.prank(caller);
        vm.expectRevert(bytes("MIN_OUT"));
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 900e18, _path(address(tokenIn), address(tokenOut)));
    }

    function test_O5_aRouterThatPaysNothingCannotSatisfyTheFloor() public {
        router.setPayNothing(true);

        vm.prank(caller);
        vm.expectRevert(bytes("MIN_OUT"));
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, _path(address(tokenIn), address(tokenOut)));
    }

    function test_O5_aPathEndingInTheWrongTokenIsRejected() public {
        vm.prank(caller);
        vm.expectRevert(bytes("PATH_OUT_MISMATCH"));
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 0, _path(address(tokenIn), address(decoy)));
    }

    function test_O5_aPathStartingInTheWrongTokenIsRejected() public {
        vm.prank(caller);
        vm.expectRevert(bytes("PATH_IN_MISMATCH"));
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 0, _path(address(decoy), address(tokenOut)));
    }

    function test_O5_malformedPathsAreRejected() public {
        vm.startPrank(caller);
        vm.expectRevert(bytes("PATH_TOO_SHORT"));
        swapper.swap(address(tokenIn), address(tokenOut), 1e18, 0, abi.encodePacked(address(tokenIn)));

        vm.expectRevert(bytes("BAD_PATH_SHAPE"));
        swapper.swap(
            address(tokenIn),
            address(tokenOut),
            1e18,
            0,
            abi.encodePacked(address(tokenIn), uint24(500), address(tokenOut), uint8(1))
        );
        vm.stopPrank();
    }

    function test_O5_aMultiHopPathIsAccepted() public {
        bytes memory path =
            abi.encodePacked(address(tokenIn), uint24(500), address(decoy), uint24(3000), address(tokenOut));

        vm.prank(caller);
        uint256 out = swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, path);
        assertEq(out, 1_000e18);
    }

    function test_A1_theRouterIsPinnedAtConstruction() public {
        vm.expectRevert(bytes("ZERO_ADDR"));
        new UniswapV3Swapper(address(0));
        assertEq(address(swapper.router()), address(router));
    }

    function testFuzz_O5_neverReturnsLessThanTheFloorItAccepts(uint256 rateBps, uint256 minOut) public {
        rateBps = bound(rateBps, 0, 20_000);
        minOut = bound(minOut, 0, 2_000e18);
        router.setRateBps(rateBps);

        vm.prank(caller);
        try swapper.swap(
            address(tokenIn), address(tokenOut), 1_000e18, minOut, _path(address(tokenIn), address(tokenOut))
        ) returns (uint256 out) {
            assertGe(out, minOut);
        } catch {}
    }
}

contract UniswapV2SwapperTest is SwapperBase {
    MockV2Router internal router;
    UniswapV2Swapper internal swapper;

    function setUp() public {
        _setUpTokens();
        router = new MockV2Router();
        swapper = new UniswapV2Swapper(address(router));
        _approve(address(swapper));
    }

    function _path(address a, address b) internal pure returns (bytes memory) {
        address[] memory p = new address[](2);
        p[0] = a;
        p[1] = b;
        return abi.encode(p);
    }

    function test_O5_happyPathDelivers() public {
        vm.prank(caller);
        uint256 out =
            swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, _path(address(tokenIn), address(tokenOut)));
        assertEq(out, 1_000e18);
        assertEq(tokenOut.balanceOf(caller), 1_000e18);
    }

    function test_O5_minOutIsEnforced() public {
        router.setRateBps(5_000);
        vm.prank(caller);
        vm.expectRevert(bytes("MIN_OUT"));
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 900e18, _path(address(tokenIn), address(tokenOut)));
    }

    function test_O5_pathEndpointsAreValidated() public {
        vm.startPrank(caller);
        vm.expectRevert(bytes("BAD_PATH"));
        swapper.swap(address(tokenIn), address(tokenOut), 1e18, 0, _path(address(decoy), address(tokenOut)));

        vm.expectRevert(bytes("BAD_PATH"));
        swapper.swap(address(tokenIn), address(tokenOut), 1e18, 0, _path(address(tokenIn), address(decoy)));

        address[] memory single = new address[](1);
        single[0] = address(tokenIn);
        vm.expectRevert(bytes("BAD_PATH"));
        swapper.swap(address(tokenIn), address(tokenOut), 1e18, 0, abi.encode(single));
        vm.stopPrank();
    }
}

contract CurveSwapperTest is SwapperBase {
    MockCurveExchange internal pool;
    CurveSwapper internal swapper;

    function setUp() public {
        _setUpTokens();
        pool = new MockCurveExchange();
        pool.setCoin(0, address(tokenIn));
        pool.setCoin(1, address(tokenOut));
        swapper = new CurveSwapper();
        _approve(address(swapper));
    }

    function _route() internal view returns (bytes memory) {
        return abi.encode(address(pool), int128(0), int128(1));
    }

    function test_O5_happyPathDelivers() public {
        vm.prank(caller);
        uint256 out = swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, _route());
        assertEq(out, 1_000e18);
        assertEq(tokenOut.balanceOf(caller), 1_000e18);
    }

    function test_O5_minOutIsEnforcedOnTheMeasuredDelta() public {
        pool.setRateBps(7_000);
        vm.prank(caller);
        vm.expectRevert(bytes("MIN_OUT"));
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 900e18, _route());
    }

    function test_O5_aPoolPayingTheWrongTokenCannotSatisfyTheFloor() public {
        pool.setPayWrongToken(true, address(decoy));

        vm.prank(caller);
        vm.expectRevert(bytes("MIN_OUT"));
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, _route());
    }

    function test_O5_approvalIsClearedAfterTheSwap() public {
        vm.prank(caller);
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, _route());
        assertEq(tokenIn.allowance(address(swapper), address(pool)), 0);
    }
}

contract BalancerV2SwapperTest is SwapperBase {
    MockBalancerVault internal balancer;
    BalancerV2Swapper internal swapper;

    function setUp() public {
        _setUpTokens();
        balancer = new MockBalancerVault();
        swapper = new BalancerV2Swapper(address(balancer));
        _approve(address(swapper));
    }

    function test_O5_happyPathDelivers() public {
        vm.prank(caller);
        uint256 out = swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, abi.encode(bytes32("pool")));
        assertEq(out, 1_000e18);
        assertEq(tokenOut.balanceOf(caller), 1_000e18);
    }

    function test_O5_minOutIsEnforced() public {
        balancer.setRateBps(6_000);
        vm.prank(caller);
        vm.expectRevert(bytes("MIN_OUT"));
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 900e18, abi.encode(bytes32("pool")));
    }

    function test_A1_theVaultIsPinnedAtConstruction() public {
        vm.expectRevert(bytes("ZERO_ADDR"));
        new BalancerV2Swapper(address(0));
    }
}

contract AggregatorSwapperTest is SwapperBase {
    MockAggregatorRouter internal router;
    AggregatorSwapper internal swapper;

    function setUp() public {
        _setUpTokens();
        router = new MockAggregatorRouter();
        swapper = new AggregatorSwapper(address(router));
        _approve(address(swapper));
    }

    function test_O5_anHonestPayloadDelivers() public {
        bytes memory data = abi.encodeCall(
            MockAggregatorRouter.fill, (address(tokenIn), address(tokenOut), 1_000e18, 950e6, address(swapper))
        );

        vm.prank(caller);
        uint256 out = swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 900e6, data);

        assertEq(out, 950e6);
        assertEq(tokenOut.balanceOf(caller), 950e6);
    }

    function test_O5_aPayloadThatPaysNothingIsCaughtByTheMeasuredFloor() public {
        bytes memory data = abi.encodeCall(MockAggregatorRouter.steal, (address(tokenIn), 1_000e18));

        vm.prank(caller);
        vm.expectRevert(bytes("MIN_OUT"));
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, data);
    }

    function test_O5_aPayloadPayingTheWrongTokenIsCaught() public {
        bytes memory data = abi.encodeCall(
            MockAggregatorRouter.fillWrongToken,
            (address(tokenIn), address(decoy), 1_000e18, 5_000e18, address(swapper))
        );

        vm.prank(caller);
        vm.expectRevert(bytes("MIN_OUT"));
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, data);
    }

    function test_O5_aRevertingRouterSurfacesAsSwapFailed() public {
        bytes memory data = abi.encodeCall(MockAggregatorRouter.boom, ());

        vm.prank(caller);
        vm.expectRevert(bytes("SWAP_FAILED"));
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, data);
    }

    function test_A1_onlyThePinnedRouterCanEverBeCalled() public {
        MockAggregatorRouter other = new MockAggregatorRouter();
        assertEq(swapper.router(), address(router));
        assertTrue(address(other) != swapper.router());

        vm.expectRevert(bytes("ZERO_ADDR"));
        new AggregatorSwapper(address(0));
    }

    function test_O5_approvalIsClearedAfterAFill() public {
        bytes memory data = abi.encodeCall(
            MockAggregatorRouter.fill, (address(tokenIn), address(tokenOut), 1_000e18, 950e6, address(swapper))
        );
        vm.prank(caller);
        swapper.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, data);

        assertEq(tokenIn.allowance(address(swapper), address(router)), 0);
    }
}

contract RoutedSwapperTest is SwapperBase {
    MockV3Router internal v3Router;
    UniswapV3Swapper internal v3;
    RoutedSwapper internal routed;

    address internal governance = address(0x600);

    function setUp() public {
        _setUpTokens();
        v3Router = new MockV3Router();
        v3 = new UniswapV3Swapper(address(v3Router));
        routed = new RoutedSwapper(governance);
        _approve(address(routed));
    }

    function _register() internal {
        vm.prank(governance);
        routed.setRoute(
            address(tokenIn),
            address(tokenOut),
            address(v3),
            abi.encodePacked(address(tokenIn), uint24(500), address(tokenOut))
        );
    }

    function test_O5_aRegisteredRouteForwardsAndDelivers() public {
        _register();

        vm.prank(caller);
        uint256 out = routed.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, "");

        assertEq(out, 1_000e18);
        assertEq(tokenOut.balanceOf(caller), 1_000e18);
    }

    function test_O5_theCallersOwnDataIsIgnoredInFavourOfTheRoute() public {
        _register();

        vm.prank(caller);
        uint256 out = routed.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, hex"deadbeefdeadbeef");
        assertEq(out, 1_000e18);
    }

    function test_O5_anUnregisteredPairRevertsRatherThanGuessing() public {
        vm.prank(caller);
        vm.expectRevert(bytes("NO_ROUTE"));
        routed.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, "");
    }

    function test_O5_routesAreDirectional() public {
        _register();
        (address venue,) = routed.routeFor(address(tokenOut), address(tokenIn));
        assertEq(venue, address(0));
    }

    function test_O5_minOutIsEnforcedOnTheMeasuredDelta() public {
        _register();
        v3Router.setRateBps(5_000);

        vm.prank(caller);
        vm.expectRevert(bytes("MIN_OUT"));
        routed.swap(address(tokenIn), address(tokenOut), 1_000e18, 900e18, "");
    }

    function test_A1_onlyGovernanceMayChangeTheTable() public {
        vm.prank(caller);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        routed.setRoute(address(tokenIn), address(tokenOut), address(v3), "");

        vm.prank(caller);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        routed.removeRoute(address(tokenIn), address(tokenOut));

        vm.prank(caller);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        routed.transferGovernance(caller);
    }

    function test_A1_badRouteParametersAreRejected() public {
        vm.startPrank(governance);
        vm.expectRevert(bytes("BAD_PAIR"));
        routed.setRoute(address(0), address(tokenOut), address(v3), "");

        vm.expectRevert(bytes("BAD_PAIR"));
        routed.setRoute(address(tokenIn), address(tokenIn), address(v3), "");

        vm.expectRevert(bytes("ZERO_VENUE"));
        routed.setRoute(address(tokenIn), address(tokenOut), address(0), "");
        vm.stopPrank();
    }

    function test_O5_governanceCanRerouteWithoutTouchingTheCaller() public {
        _register();

        MockV3Router betterRouter = new MockV3Router();
        UniswapV3Swapper better = new UniswapV3Swapper(address(betterRouter));
        betterRouter.setRateBps(11_000);

        vm.prank(governance);
        routed.setRoute(
            address(tokenIn),
            address(tokenOut),
            address(better),
            abi.encodePacked(address(tokenIn), uint24(500), address(tokenOut))
        );

        vm.prank(caller);
        uint256 out = routed.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, "");
        assertEq(out, 1_100e18);
    }

    function test_O5_aRemovedRouteStopsWorkingImmediately() public {
        _register();
        vm.prank(governance);
        routed.removeRoute(address(tokenIn), address(tokenOut));

        vm.prank(caller);
        vm.expectRevert(bytes("NO_ROUTE"));
        routed.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, "");
    }

    function test_A3_governanceTransferIsTotal() public {
        address newGov = address(0x9E9);
        vm.prank(governance);
        routed.transferGovernance(newGov);

        vm.prank(governance);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        routed.setRoute(address(tokenIn), address(tokenOut), address(v3), "");

        vm.prank(newGov);
        routed.setRoute(address(tokenIn), address(tokenOut), address(v3), "");
    }

    function test_S2_theRoutedSwapperNeverRetainsTokens() public {
        _register();
        vm.prank(caller);
        routed.swap(address(tokenIn), address(tokenOut), 1_000e18, 1, "");

        assertEq(tokenIn.balanceOf(address(routed)), 0);
        assertEq(tokenOut.balanceOf(address(routed)), 0);
        assertEq(tokenIn.allowance(address(routed), address(v3)), 0);
    }
}
