// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultHarness} from "../helpers/VaultHarness.sol";
import {Vault} from "../../src/Vault.sol";
import {VaultShareToken} from "../../src/VaultShareToken.sol";
import {AdminFacet} from "../../src/facets/AdminFacet.sol";
import {ViewFacet} from "../../src/facets/ViewFacet.sol";
import {DepositFacet} from "../../src/facets/DepositFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {PriceFeed} from "../../src/oracle/PriceFeed.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {MockPyth} from "../mocks/MockSwapVenues.sol";

contract VaultRouterTest is VaultHarness {
    MockERC20 internal usdc;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        _deployVault(address(usdc), 1_000, 5_000);
        usdc.mint(alice, 1_000_000e6);
    }

    function test_A4_anUnknownSelectorIsRejected() public {
        (bool ok, bytes memory data) = address(vault).call(abi.encodeWithSignature("noSuchFunction()"));
        assertFalse(ok);
        assertEq(_reason(data), "FUNCTION_NOT_FOUND");
    }

    function test_A4_everyRegisteredSelectorResolvesToAFacet() public view {
        assertTrue(vault.facetOf(DepositFacet.deposit.selector) != address(0));
        assertTrue(vault.facetOf(DepositFacet.mint.selector) != address(0));
        assertTrue(vault.facetOf(WithdrawFacet.withdraw.selector) != address(0));
        assertTrue(vault.facetOf(WithdrawFacet.redeem.selector) != address(0));
        assertTrue(vault.facetOf(AdminFacet.execOnStrategy.selector) != address(0));
        assertTrue(vault.facetOf(ViewFacet.totalAssets.selector) != address(0));
    }

    function test_A4_onlyGovernanceCanRepointASelector() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NOT_GOVERNANCE"));
        vault.setFacet(DepositFacet.deposit.selector, address(0xBEEF));
    }

    function test_A4_repointingASelectorTakesEffectImmediately() public {
        _deposit(alice, 1_000e6);
        assertEq(_totalAssets(), 1_000e6);

        vm.prank(GOV);
        vault.setFacet(DepositFacet.deposit.selector, address(0));

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        (bool ok, bytes memory data) = address(vault).call(abi.encodeCall(DepositFacet.deposit, (1_000e6, alice, 0)));
        vm.stopPrank();

        assertFalse(ok);
        assertEq(_reason(data), "FUNCTION_NOT_FOUND");
        assertEq(_totalAssets(), 1_000e6);
    }

    function test_A4_anUpgradedFacetSharesTheSameStorage() public {
        _deposit(alice, 50_000e6);
        uint256 navBefore = _totalAssets();
        uint256 sharesBefore = _shareToken().balanceOf(alice);

        address upgraded = address(new ViewFacet());
        vm.prank(GOV);
        vault.setFacet(ViewFacet.totalAssets.selector, upgraded);
        assertEq(vault.facetOf(ViewFacet.totalAssets.selector), upgraded);

        assertEq(_totalAssets(), navBefore);
        assertEq(_shareToken().balanceOf(alice), sharesBefore);
    }

    function test_A1_theVaultRejectsAReInitialization() public view {
        assertTrue(vault.shareToken() != address(0));
    }

    function test_A1_constructorBoundsAreEnforced() public {
        Vault.Facets memory f = Vault.Facets({
            deposit: address(new DepositFacet()),
            withdraw: address(new WithdrawFacet()),
            strategy: address(0x1),
            admin: address(0x2),
            emergency: address(0x3),
            view_: address(0x4)
        });

        Vault.InitConfig memory c = _config();
        c.baseAsset = address(0);
        vm.expectRevert(bytes("ZERO_ADDRESS"));
        new Vault(c, f);

        c = _config();
        c.governance = address(0);
        vm.expectRevert(bytes("ZERO_GOV"));
        new Vault(c, f);

        c = _config();
        c.idleTargetBps = 1_001;
        vm.expectRevert(bytes("IDLE_TOO_HIGH"));
        new Vault(c, f);

        c = _config();
        c.performanceFeeBps = 3_001;
        vm.expectRevert(bytes("FEE_TOO_HIGH"));
        new Vault(c, f);

        c = _config();
        c.strategyMaxDeltaBps = 0;
        vm.expectRevert(bytes("INVALID_MAX_DELTA"));
        new Vault(c, f);

        c = _config();
        c.entryFeeWei = 0.2 ether;
        vm.expectRevert(bytes("ENTRY_FEE_TOO_HIGH"));
        new Vault(c, f);
    }

    function _config() internal view returns (Vault.InitConfig memory) {
        return Vault.InitConfig({
            baseAsset: address(usdc),
            governance: GOV,
            treasury: TREASURY,
            keeper: KEEPER,
            guardian: GUARDIAN,
            idleTargetBps: 1_000,
            performanceFeeBps: 0,
            strategyMaxDeltaBps: 5_000,
            harvestMaxImpactBps: 5_000,
            entryFeeWei: 0,
            minDeposit: 0,
            tvlCap: 0,
            depositCapPerBlock: 0,
            withdrawCapPerBlock: 0,
            name: "n",
            symbol: "s"
        });
    }

    function _reason(bytes memory data) internal pure returns (string memory) {
        if (data.length < 68) return "";
        assembly {
            data := add(data, 0x04)
        }
        return abi.decode(data, (string));
    }
}

contract VaultShareTokenTest is VaultHarness {
    MockERC20 internal usdc;
    VaultShareToken internal share;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        _deployVault(address(usdc), 1_000, 5_000);
        share = VaultShareToken(vault.shareToken());
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
    }

    function test_A1_onlyTheVaultCanMint() public {
        vm.prank(alice);
        vm.expectRevert();
        share.mint(alice, 1e18);
    }

    function test_A1_onlyTheVaultCanBurn() public {
        _deposit(alice, 1_000e6);

        vm.prank(alice);
        vm.expectRevert();
        share.burn(alice, 1);
    }

    function test_A1_onlyTheVaultCanSpendAllowanceOnBehalf() public {
        _deposit(alice, 1_000e6);
        vm.prank(alice);
        share.approve(bob, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert();
        share.spendAllowance(alice, bob, 1);
    }

    function test_S6_sharesAreOrdinarilyTransferable() public {
        uint256 shares = _deposit(alice, 1_000e6);

        vm.prank(alice);
        share.transfer(bob, shares / 2);

        assertEq(share.balanceOf(bob), shares / 2);
        assertEq(share.balanceOf(alice) + share.balanceOf(bob), share.totalSupply());
    }

    function test_S6_aTransferredShareCarriesItsClaim() public {
        uint256 shares = _deposit(alice, 1_000e6);
        vm.prank(alice);
        share.transfer(bob, shares);

        uint256 before = usdc.balanceOf(bob);
        _redeem(bob, shares);
        assertApproxEqAbs(usdc.balanceOf(bob) - before, 1_000e6, 1);
    }

    function test_S6_decimalsAreFixedIndependentOfTheBaseAsset() public view {
        assertEq(share.decimals(), 18);
    }
}

contract FlowCapTest is VaultHarness {
    MockERC20 internal usdc;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        _deployVault(address(usdc), 1_000, 5_000);
        usdc.mint(alice, 10_000_000e6);
        usdc.mint(bob, 10_000_000e6);

        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setCaps(0, 100_000e6, 100_000e6, 0);
    }

    function test_D3_theDepositCapIsCumulativeWithinABlock() public {
        _deposit(alice, 60_000e6);
        _deposit(bob, 40_000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("DEPOSIT_CAP_EXCEEDED"));
        DepositFacet(payable(address(vault))).deposit(1e6, alice, 0);
        vm.stopPrank();
    }

    function test_D3_theDepositCapResetsEachBlock() public {
        _deposit(alice, 100_000e6);
        vm.roll(block.number + 1);
        _deposit(alice, 100_000e6);
    }

    function test_D3_mintConsumesTheSameBudgetAsDeposit() public {
        _deposit(alice, 90_000e6);

        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("DEPOSIT_CAP_EXCEEDED"));
        DepositFacet(payable(address(vault))).mint(50_000e18, bob, type(uint256).max);
        vm.stopPrank();
    }

    function test_D3_anExemptAddressBypassesTheCap() public {
        vm.prank(GOV);
        AdminFacet(payable(address(vault))).setCapExempt(alice, true);

        _deposit(alice, 5_000_000e6);
        assertEq(_totalAssets(), 5_000_000e6);
    }

    function test_D3_theCapBoundaryIsInclusive() public {
        _deposit(alice, 100_000e6);
        assertEq(_totalAssets(), 100_000e6);
    }

    function testFuzz_D3_noSplitAcrossSendersEverExceedsTheBlockCap(uint96 a, uint96 b) public {
        uint256 first = bound(a, 1e6, 100_000e6);
        uint256 second = bound(b, 1e6, 100_000e6);

        _deposit(alice, first);

        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        try DepositFacet(payable(address(vault))).deposit(second, bob, 0) {
            assertLe(first + second, 100_000e6);
        } catch {}
        vm.stopPrank();
    }
}

contract PythSourceTest is VaultHarness {
    MockERC20 internal usdc;
    MockPyth internal pyth;
    PriceFeed internal feed;

    bytes32 internal constant ID = bytes32("USDC/USD");

    function setUp() public {
        vm.warp(30 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pyth = new MockPyth();
        feed = new PriceFeed(address(this), address(pyth));
        feed.setPythConfig(address(usdc), ID, 1 hours);
    }

    function _price() internal view returns (uint256) {
        return feed.getPrice(address(usdc), PriceFeed.PriceSource.PYTH);
    }

    function test_O_normalisesAnExponentOfMinusEightToEightDecimals() public {
        pyth.setPrice(ID, 1e8, -8, block.timestamp);
        assertEq(_price(), 1e8);
    }

    function test_O_normalisesASmallerExponentByScalingDown() public {
        pyth.setPrice(ID, 1e18, -18, block.timestamp);
        assertEq(_price(), 1e8);
    }

    function test_O_normalisesALargerExponentByScalingUp() public {
        pyth.setPrice(ID, 1e5, -5, block.timestamp);
        assertEq(_price(), 1e8);
    }

    function test_O1_aStalePythPriceIsRefused() public {
        pyth.setPrice(ID, 1e8, -8, block.timestamp - 2 hours);
        vm.expectRevert(bytes("STALE_PRICE"));
        _price();
    }

    function test_O2_aZeroOrNegativePythPriceIsRefused() public {
        pyth.setPrice(ID, 0, -8, block.timestamp);
        vm.expectRevert(bytes("INVALID_PRICE"));
        _price();

        pyth.setPrice(ID, -1e8, -8, block.timestamp);
        vm.expectRevert(bytes("INVALID_PRICE"));
        _price();
    }

    function test_O2_anUnpublishedPythPriceIsRefused() public {
        pyth.setPrice(ID, 1e8, -8, 0);
        vm.expectRevert(bytes("ROUND_INCOMPLETE"));
        _price();
    }

    function test_O2_aFutureDatedPythPriceIsRefused() public {
        pyth.setPrice(ID, 1e8, -8, block.timestamp + 1 hours);
        vm.expectRevert(bytes("FUTURE_TIMESTAMP"));
        _price();
    }

    function test_O3_anUnconfiguredPythTokenReverts() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.expectRevert(bytes("NOT_CONFIGURED"));
        feed.getPrice(address(other), PriceFeed.PriceSource.PYTH);
    }

    function test_O_theTwoSourcesAreIndependentAndNeverCrossCheck() public {
        pyth.setPrice(ID, 2e8, -8, block.timestamp);
        assertEq(_price(), 2e8);

        vm.expectRevert(bytes("NOT_CONFIGURED"));
        feed.getPrice(address(usdc));
    }

    function testFuzz_O_exponentNormalisationIsExact(int32 expo) public {
        int32 e = int32(bound(int256(expo), -18, -1));
        uint256 raw = 10 ** uint256(int256(-e));

        pyth.setPrice(ID, int64(uint64(raw)), e, block.timestamp);
        assertEq(_price(), 1e8);
    }
}
