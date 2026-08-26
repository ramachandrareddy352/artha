// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStrategy} from "../../src/strategies/interfaces/IStrategy.sol";
import {DepositFacet} from "../../src/facets/DepositFacet.sol";
import {WithdrawFacet} from "../../src/facets/WithdrawFacet.sol";
import {StrategyFacet} from "../../src/facets/StrategyFacet.sol";

/// A strategy that satisfies `addStrategy`'s checks and then behaves as badly as the
/// interface allows. Every hostile behaviour is a flag so one deployment can play many
/// different attackers.
contract EvilStrategy is IStrategy {
    using SafeERC20 for IERC20;

    enum ValueMode {
        Honest,
        Max,
        Double,
        Zero,
        Revert,
        GasBomb
    }

    enum Misbehaviour {
        None,
        RevertOnDivest,
        RevertOnEmergency,
        DivestWithoutPaying,
        DivestUnderpay,
        ReenterDepositOnInvest,
        ReenterWithdrawOnDivest,
        ReenterHarvestOnHarvest,
        StealReceiptOnDivest,
        StealReceiptAndPay
    }

    IERC20 public immutable baseToken;
    address public immutable theVault;

    ValueMode public valueMode;
    Misbehaviour public misbehaviour;
    address public fakeReceipt;
    address public victimReceipt;
    uint256 public bookedValue;

    constructor(address _vault, address _asset) {
        theVault = _vault;
        baseToken = IERC20(_asset);
    }

    function setValueMode(ValueMode m) external {
        valueMode = m;
    }

    function setMisbehaviour(Misbehaviour m) external {
        misbehaviour = m;
    }

    function setFakeReceipt(address token) external {
        fakeReceipt = token;
    }

    function setVictimReceipt(address token) external {
        victimReceipt = token;
    }

    /// Claim a position the vault never funded.
    function setBookedValue(uint256 v) external {
        bookedValue = v;
    }

    // ───────────────────────────── IStrategy surface ────────────────────────────

    function asset() external view returns (IERC20) {
        return baseToken;
    }

    function vault() external view returns (address) {
        return theVault;
    }

    function receiptToken() external view returns (address) {
        return fakeReceipt;
    }

    function positionValue() external view returns (uint256) {
        if (valueMode == ValueMode.Max) return type(uint256).max;
        if (valueMode == ValueMode.Double) return bookedValue * 2;
        if (valueMode == ValueMode.Zero) return 0;
        if (valueMode == ValueMode.Revert) revert("VENUE_DOWN");
        if (valueMode == ValueMode.GasBomb) {
            uint256 x;
            for (uint256 i; i < 100_000_000; ++i) {
                x += i;
            }
            return x;
        }
        return bookedValue;
    }

    function pendingRewardsValue() external pure returns (uint256) {
        return 0;
    }

    function maxWithdraw() external view returns (uint256) {
        return bookedValue;
    }

    function invest(uint256 assets) external {
        baseToken.safeTransferFrom(theVault, address(this), assets);
        bookedValue += assets;

        if (misbehaviour == Misbehaviour.ReenterDepositOnInvest) {
            DepositFacet(payable(theVault)).deposit(1e6, address(this), 0);
        }
    }

    function divest(uint256 assets) external returns (uint256) {
        if (misbehaviour == Misbehaviour.RevertOnDivest) revert("VENUE_FROZEN");

        if (misbehaviour == Misbehaviour.StealReceiptOnDivest) {
            uint256 stolen = IERC20(victimReceipt).balanceOf(theVault);
            if (stolen != 0) IERC20(victimReceipt).safeTransferFrom(theVault, address(this), stolen);
            return 0;
        }

        if (misbehaviour == Misbehaviour.StealReceiptAndPay) {
            uint256 stolen = IERC20(victimReceipt).balanceOf(theVault);
            if (stolen != 0) IERC20(victimReceipt).safeTransferFrom(theVault, address(this), stolen);

            uint256 due = assets > bookedValue ? bookedValue : assets;
            if (due != 0) {
                bookedValue -= due;
                baseToken.safeTransfer(theVault, due);
            }
            return due;
        }

        if (misbehaviour == Misbehaviour.ReenterWithdrawOnDivest) {
            WithdrawFacet(payable(theVault)).withdraw(1e6, address(this), address(this), type(uint256).max);
            return 0;
        }

        if (misbehaviour == Misbehaviour.DivestWithoutPaying) return assets;

        uint256 pay = assets;
        if (misbehaviour == Misbehaviour.DivestUnderpay) pay = assets / 2;
        if (pay > bookedValue) pay = bookedValue;
        if (pay == 0) return 0;

        bookedValue -= pay;
        baseToken.safeTransfer(theVault, pay);
        return pay;
    }

    function harvest() external returns (uint256) {
        if (misbehaviour == Misbehaviour.ReenterHarvestOnHarvest) {
            StrategyFacet(payable(theVault)).harvest(address(this));
        }
        return 0;
    }

    function tend() external {}

    function emergencyWithdraw() external returns (uint256) {
        if (misbehaviour == Misbehaviour.RevertOnEmergency) revert("CANNOT_UNWIND");

        uint256 all = bookedValue;
        if (all == 0) return 0;
        bookedValue = 0;
        baseToken.safeTransfer(theVault, all);
        return all;
    }

    /// Whatever the strategy managed to steal, for the tests to assert on.
    function loot(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
