// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface IVaultView {
    function strategyList() external view returns (address[] memory);
    function vaultConfig() external view returns (VaultConfigView memory);
}

struct VaultConfigView {
    address baseAsset;
    uint8 baseDecimals;
    address shareToken;
    uint256 idleBalance;
    uint16 idleTargetBps;
    uint256 minDeposit;
    uint256 tvlCap;
    uint256 depositCapPerBlock;
    uint256 withdrawCapPerBlock;
    uint16 performanceFeeBps;
    uint256 highWaterMarkPps;
    uint256 totalAssets;
    uint256 totalShares;
    uint256 pricePerShare;
    bool paused;
}

interface IStrategyView {
    function receiptToken() external view returns (address);
    function positionValue() external view returns (uint256);
}

/**
 * @title  VerifyReceiptCollisions — READ-ONLY production check
 * @notice Answers one question about a LIVE vault, without sending a transaction:
 *
 *     "Does any registered strategy declare a `receiptToken()` that collides with the
 *      base asset, the share token, or another strategy's receipt?"
 *
 *  A collision means that strategy is granted an allowance over a token it does not
 *  exclusively own every time the vault divests from it — which lets it move another
 *  strategy's position, and (even with no malice) makes both strategies report the same
 *  balance into NAV.
 *
 *  This performs only `view` calls. It sends nothing, signs nothing, and changes nothing.
 *
 *  Usage:
 *      ETH_RPC_URL=<rpc> VAULT=<address> forge script script/VerifyReceiptCollisions.s.sol
 *
 *  Exit reading:
 *      "CLEAN"     — no collision; the missing on-chain guard is not currently exploited.
 *      "COLLISION" — act immediately: the named strategies share a receipt.
 */
contract VerifyReceiptCollisions is Script {
    function run() external view {
        address vault = vm.envAddress("VAULT");
        console.log("vault:", vault);

        VaultConfigView memory cfg = IVaultView(vault).vaultConfig();
        console.log("baseAsset: ", cfg.baseAsset);
        console.log("shareToken:", cfg.shareToken);
        console.log("paused:    ", cfg.paused);

        address[] memory strategies = IVaultView(vault).strategyList();
        console.log("strategies:", strategies.length);

        address[] memory receipts = new address[](strategies.length);
        bool bad = false;

        for (uint256 i; i < strategies.length; ++i) {
            address s = strategies[i];
            address r;
            bool readable = true;

            try IStrategyView(s).receiptToken() returns (address got) {
                r = got;
            } catch {
                readable = false;
            }

            receipts[i] = r;

            console.log("--------------------------------");
            console.log("strategy:", s);
            if (!readable) {
                console.log("  receiptToken(): UNREADABLE - investigate");
                bad = true;
                continue;
            }
            console.log("  receipt:", r);

            try IStrategyView(s).positionValue() returns (uint256 v) {
                console.log("  position:", v);
            } catch {
                console.log("  positionValue(): UNREADABLE - strategy is degraded");
                bad = true;
            }

            if (r == address(0)) {
                console.log("  -> internal-ledger venue, no allowance is ever granted: OK");
                continue;
            }

            if (r == cfg.baseAsset) {
                console.log("  !! COLLISION: receipt IS THE BASE ASSET");
                bad = true;
            }
            if (r == cfg.shareToken) {
                console.log("  !! COLLISION: receipt IS THE SHARE TOKEN");
                bad = true;
            }

            for (uint256 j; j < i; ++j) {
                if (receipts[j] != address(0) && receipts[j] == r) {
                    console.log("  !! COLLISION with earlier strategy:", strategies[j]);
                    bad = true;
                }
            }
        }

        console.log("================================");
        if (bad) {
            console.log("RESULT: COLLISION - remediate before any further divest/withdraw");
        } else {
            console.log("RESULT: CLEAN - no strategy currently shares a receipt");
        }
    }
}
