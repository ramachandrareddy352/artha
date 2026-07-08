// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AppStorage, LibAppStorage} from "./LibAppStorage.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/**
 * @title  LibNav
 * @notice Per-pool NAV = idle USDC + idle basket tokens (oracle-priced) + capital
 *         deployed to strategies (each strategy reports its own USDC value).
 *
 *  Custody is commingled in the one Diamond, so per-pool token holdings are tracked
 *  in `poolTokenBalance` (NOT balanceOf) to keep pools separate. Tokens deployed to
 *  a strategy are removed from poolTokenBalance and counted by the strategy — no
 *  double counting.
 */
library LibNav {
    function totalAssets(uint8 poolId) internal view returns (uint256 usdcValue) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // 1) idle USDC held for the pool
        usdcValue = s.idleUsdc[poolId];

        // 2) idle basket tokens, valued via the oracle
        address[] memory basket = s.poolBasket[poolId];
        for (uint256 i; i < basket.length; i++) {
            address token = basket[i];
            uint256 bal = s.poolTokenBalance[poolId][token];
            if (bal != 0) {
                usdcValue += IOracle(s.oracle).valueInUsdc(token, bal);
            }
        }

        // 3) capital deployed to strategies
        address[] memory strats = s.poolStrategies[poolId];
        for (uint256 j; j < strats.length; j++) {
            usdcValue += IStrategy(strats[j]).totalValue(poolId);
        }
    }
}
