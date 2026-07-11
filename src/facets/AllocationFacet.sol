// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Modifiers, AppStorage, AllocationTarget} from "../libraries/LibAppStorage.sol";
import {LibStrategy} from "../libraries/LibStrategy.sol";
import {LibNav} from "../libraries/LibNav.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title  AllocationFacet
 * @notice Turns a pool's idle USDC into its 5-asset basket and keeps it balanced.
 *         Two kinds of caller, cleanly separated:
 *
 *    GOVERNANCE (bounds): whitelist tokens, set the per-asset strategy routing,
 *    approve swappers, and set target weights (validated against RiskGuard).
 *
 *    EXECUTOR (bounded ops): swap between assets, deploy idle tokens into their
 *    lending strategy, undeploy back, and harvest — each bounded by RiskGuard
 *    (whitelist, per-swap oracle value-floor). The executor composes these into a
 *    rebalance off-chain; every individual op is independently safe.
 *
 *  This is also where withdrawal liquidity comes from: undeploy pulls capital back
 *  to idle USDC, and swap converts basket tokens to USDC, so the buffer can be
 *  topped up before large USDC withdrawals (in-kind withdrawal needs neither).
 */
contract AllocationFacet is Modifiers {
    using SafeERC20 for IERC20;
    using LibStrategy for AppStorage;

    event WhitelistSet(address indexed token, bool ok, bool meme);
    event AssetStrategySet(uint8 indexed poolId, address indexed token, address strategy);
    event SwapperSet(address indexed swapper, bool ok);
    event TargetWeightsSet(uint8 indexed poolId, address[] tokens, uint16[] weights);
    event Deployed(uint8 indexed poolId, address indexed token, address strategy, uint256 amount);
    event Undeployed(uint8 indexed poolId, address indexed token, address strategy, uint256 amount);
    event Swapped(uint8 indexed poolId, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event Harvested(uint8 indexed poolId, address strategy, uint256 rewards);
    event AllocationsSet(uint8 indexed poolId, uint256 targetCount);
    event MaxStrategyUsdcSet(uint8 indexed poolId, address indexed strategy, uint256 capUsdc);

    /*//////////////////////////////////////////////////////////////
                       GOVERNANCE — BOUNDS / CONFIG
    //////////////////////////////////////////////////////////////*/

    function setWhitelist(address token, bool ok, bool meme) external onlyGovernance {
        s.whitelisted[token] = ok;
        s.isMemeClass[token] = meme;
        emit WhitelistSet(token, ok, meme);
    }

    /// @notice Route a pool's asset to a lending strategy (address(0) = hold idle).
    ///         The same token can route differently per pool (e.g. USDC->Aave in
    ///         one pool, USDC->Morpho in another).
    function setAssetStrategy(uint8 poolId, address token, address strategy)
        external
        onlyGovernance
        validPool(poolId)
    {
        require(s.whitelisted[token], "TOKEN_NOT_WHITELISTED");
        if (strategy != address(0)) {
            require(IStrategy(strategy).underlying() == token, "STRATEGY_UNDERLYING_MISMATCH");
        }
        s.assetStrategy[poolId][token] = strategy;
        emit AssetStrategySet(poolId, token, strategy);
    }

    function setApprovedSwapper(address swapper, bool ok) external onlyGovernance {
        s.approvedSwapper[swapper] = ok;
        emit SwapperSet(swapper, ok);
    }

    /**
     * @notice Set a pool's target basket weights. Validated against RiskGuard:
     *         <=5 tokens, all whitelisted, each <= maxWeight, meme sum <= cap, and
     *         the sum must leave room for the min idle buffer.
     */
    function setTargetWeights(uint8 poolId, address[] calldata tokens, uint16[] calldata weights)
        external
        onlyGovernance
        validPool(poolId)
    {
        require(tokens.length == weights.length && tokens.length <= 5, "BAD_LENGTHS");

        uint256 sum;
        uint256 memeSum;
        for (uint256 i; i < tokens.length; i++) {
            require(s.whitelisted[tokens[i]], "TOKEN_NOT_WHITELISTED");
            require(weights[i] <= s.maxWeightBps[poolId], "WEIGHT_OVER_CAP");
            if (s.isMemeClass[tokens[i]]) memeSum += weights[i];
            sum += weights[i];
            s.targetWeightBps[poolId][tokens[i]] = weights[i];
        }
        require(sum + s.minBufferBps[poolId] <= 10000, "BUFFER_NOT_RESERVED");
        require(memeSum <= s.maxMemeBps[poolId], "MEME_OVER_CAP");

        s.poolBasket[poolId] = tokens;
        emit TargetWeightsSet(poolId, tokens, weights);
    }

    /*//////////////////////////////////////////////////////////////
                   GOVERNANCE — WEIGHT-VECTOR ALLOCATOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set a pool's full target portfolio as a vector of {asset, strategy,
     *         weightBps}. This is the professional allocator model (Yearn/Enzyme):
     *         one list expresses every position — lend legs, hold legs, staking legs
     *         — and the executor rebalances toward it. Weights must leave the buffer.
     *
     *  Validation: each asset whitelisted (or USDC); each strategy (if set) matches
     *  its asset; per-asset weight <= maxWeight; meme sum <= cap; sum + minBuffer <= 100%.
     */
    function setAllocations(uint8 poolId, AllocationTarget[] calldata targets)
        external
        onlyGovernance
        validPool(poolId)
    {
        require(targets.length <= 12, "TOO_MANY_TARGETS");

        uint256 sum;
        uint256 memeSum;
        for (uint256 i; i < targets.length; i++) {
            AllocationTarget calldata t = targets[i];
            require(t.asset == s.usdc || s.whitelisted[t.asset], "ASSET_NOT_WHITELISTED");
            require(t.weightBps <= s.maxWeightBps[poolId], "WEIGHT_OVER_CAP");
            if (t.strategy != address(0)) {
                require(IStrategy(t.strategy).underlying() == t.asset, "STRATEGY_UNDERLYING_MISMATCH");
            }
            if (s.isMemeClass[t.asset]) memeSum += t.weightBps;
            sum += t.weightBps;
        }
        require(sum + s.minBufferBps[poolId] <= 10000, "BUFFER_NOT_RESERVED");
        require(memeSum <= s.maxMemeBps[poolId], "MEME_OVER_CAP");

        // replace the stored vector
        delete s.poolAllocations[poolId];
        for (uint256 i; i < targets.length; i++) {
            s.poolAllocations[poolId].push(targets[i]);
        }
        emit AllocationsSet(poolId, targets.length);
    }

    /// @notice Cap the absolute USDC a single strategy may hold for a pool (0 = uncapped).
    function setMaxStrategyUsdc(uint8 poolId, address strategy, uint256 capUsdc)
        external
        onlyGovernance
        validPool(poolId)
    {
        s.maxStrategyUsdc[poolId][strategy] = capUsdc;
        emit MaxStrategyUsdcSet(poolId, strategy, capUsdc);
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTOR — BOUNDED OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Move idle `token` into its lending strategy.
    function deploy(uint8 poolId, address token, uint256 amount)
        external
        onlyExecutor
        validPool(poolId)
        nonReentrant
    {
        require(amount != 0, "ZERO");
        address strat = s.assetStrategy[poolId][token];
        require(strat != address(0), "NO_STRATEGY");

        LibStrategy.debit(s, poolId, token, amount);
        IERC20(token).forceApprove(strat, amount);
        IStrategy(strat).deposit(poolId, amount);
        IERC20(token).forceApprove(strat, 0);
        LibStrategy.addStrategy(s, poolId, strat);

        // enforce the per-strategy absolute cap (0 = uncapped)
        uint256 cap = s.maxStrategyUsdc[poolId][strat];
        if (cap != 0) {
            require(IStrategy(strat).totalValue(poolId) <= cap, "STRATEGY_CAP_EXCEEDED");
        }

        emit Deployed(poolId, token, strat, amount);
    }

    /// @notice Pull `amount` of `token` back from its strategy to idle.
    function undeploy(uint8 poolId, address token, uint256 amount)
        external
        onlyExecutor
        validPool(poolId)
        nonReentrant
    {
        address strat = s.assetStrategy[poolId][token];
        require(strat != address(0), "NO_STRATEGY");

        uint256 got = IStrategy(strat).withdraw(poolId, amount);
        LibStrategy.credit(s, poolId, token, got);

        emit Undeployed(poolId, token, strat, got);
    }

    /**
     * @notice Swap `amountIn` of `tokenIn` for `tokenOut` within the pool via an
     *         approved swapper. Enforces `minOut` and an oracle value-floor:
     *         received value >= sent value * (1 - maxSlippageBps).
     */
    function swap(
        uint8 poolId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address swapper,
        bytes calldata data
    ) external onlyExecutor validPool(poolId) nonReentrant {
        require(amountIn != 0, "ZERO");
        require(s.approvedSwapper[swapper], "SWAPPER_NOT_APPROVED");
        require(tokenOut == s.usdc || s.whitelisted[tokenOut], "TOKENOUT_NOT_ALLOWED");

        uint256 inUsdc = IOracle(s.oracle).valueInUsdc(tokenIn, amountIn);

        LibStrategy.debit(s, poolId, tokenIn, amountIn);
        IERC20(tokenIn).forceApprove(swapper, amountIn);
        uint256 out = ISwapper(swapper).swap(tokenIn, tokenOut, amountIn, minOut, data);
        IERC20(tokenIn).forceApprove(swapper, 0);
        require(out >= minOut, "MIN_OUT");

        // oracle value-floor (independent of the swapper's own minOut)
        uint256 outUsdc = IOracle(s.oracle).valueInUsdc(tokenOut, out);
        require(outUsdc * 10000 >= inUsdc * (10000 - s.maxSlippageBps[poolId]), "SLIPPAGE");

        LibStrategy.credit(s, poolId, tokenOut, out);
        emit Swapped(poolId, tokenIn, tokenOut, amountIn, out);
    }

    /// @notice Claim & compound a strategy's reward emissions (raises its value).
    function harvest(uint8 poolId, address strategy)
        external
        onlyExecutor
        validPool(poolId)
        nonReentrant
        returns (uint256 rewards)
    {
        rewards = IStrategy(strategy).harvest(poolId);
        emit Harvested(poolId, strategy, rewards);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Current weight (bps of NAV) of a token in a pool.
    function currentWeightBps(uint8 poolId, address token) external view returns (uint256) {
        uint256 nav = LibNav.totalAssets(poolId);
        if (nav == 0) return 0;

        uint256 tokenValue;
        if (token == s.usdc) {
            tokenValue = s.idleUsdc[poolId];
        } else {
            uint256 idleTok = s.poolTokenBalance[poolId][token];
            if (idleTok != 0) tokenValue = IOracle(s.oracle).valueInUsdc(token, idleTok);
        }
        address strat = s.assetStrategy[poolId][token];
        if (strat != address(0)) tokenValue += IStrategy(strat).totalValue(poolId);

        return (tokenValue * 10000) / nav;
    }

    function targetWeightBps(uint8 poolId, address token) external view returns (uint16) {
        return s.targetWeightBps[poolId][token];
    }

    function poolBasket(uint8 poolId) external view returns (address[] memory) {
        return s.poolBasket[poolId];
    }

    function poolStrategies(uint8 poolId) external view returns (address[] memory) {
        return s.poolStrategies[poolId];
    }

    /// @notice The pool's stored target portfolio vector.
    function allocationTargets(uint8 poolId) external view returns (AllocationTarget[] memory) {
        return s.poolAllocations[poolId];
    }

    /**
     * @notice Rebalance helper: for each target, the current USDC value, target USDC
     *         value, and signed delta (target - current). Positive delta = buy/deploy
     *         more; negative = sell/undeploy. The executor reads this off-chain to
     *         build the exact swap/deploy/undeploy calls (each still RiskGuard-bounded).
     */
    function rebalanceDeltas(uint8 poolId)
        external
        view
        returns (uint256 nav, uint256[] memory currentUsdc, uint256[] memory targetUsdc, int256[] memory deltaUsdc)
    {
        nav = LibNav.totalAssets(poolId);
        AllocationTarget[] storage targets = s.poolAllocations[poolId];
        uint256 n = targets.length;
        currentUsdc = new uint256[](n);
        targetUsdc = new uint256[](n);
        deltaUsdc = new int256[](n);

        for (uint256 i; i < n; i++) {
            AllocationTarget storage t = targets[i];
            uint256 cur;
            if (t.strategy != address(0)) {
                cur = IStrategy(t.strategy).totalValue(poolId);
            } else if (t.asset == s.usdc) {
                cur = s.idleUsdc[poolId];
            } else {
                uint256 bal = s.poolTokenBalance[poolId][t.asset];
                if (bal != 0) cur = IOracle(s.oracle).valueInUsdc(t.asset, bal);
            }
            uint256 tgt = (nav * t.weightBps) / 10000;
            currentUsdc[i] = cur;
            targetUsdc[i] = tgt;
            deltaUsdc[i] = int256(tgt) - int256(cur);
        }
    }
}
