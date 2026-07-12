// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 ════════════════════════════════════════════════════════════════════════════════
  CurveConvexStrategy — LP-token vault that auto-compounds CRV/CVX back INTO the LP
 ════════════════════════════════════════════════════════════════════════════════
  STRATEGY  (this is the "asset is an LP token" showcase)
    The vault's `asset` is a Curve LP token. Users deposit LP, the strategy stakes it
    in Convex, and the earned CRV/CVX rewards are sold for one of the pool's coins and
    ADDED BACK as liquidity — minting more of the same LP. So the position compounds in
    LP terms, and the share price (denominated in LP) grows. This is exactly the case
    Yearn's single-token swappers don't cover: here "reward -> asset" means
    "reward -> pool coin -> add_liquidity -> LP".

  HOW USER FUNDS ARE USED
    deposit  -> _investCapital -> booster.deposit(pid, lp, stake=true) -> LP staked in Convex
    yield    -> Convex accrues CRV + CVX for the staked LP
    report   -> getReward() claims CRV/CVX; each is swapped to `addToken` (a pool coin)
                on Uniswap V3, then add_liquidity mints new LP (the asset); the new LP is
                re-staked. Profit (in LP) is locked and released smoothly.
    withdraw -> _divestCapital -> withdrawAndUnwrap -> LP returned to the user

  VALUATION  : _positionValue() = staked LP balance (already denominated in `asset`)
  EXIT       : unstake is immediate; the LP itself is as liquid as the Curve pool
  REWARD FLOW: CRV/CVX -> Uniswap V3 -> addToken -> Curve add_liquidity -> LP (asset) -> re-stake
 ════════════════════════════════════════════════════════════════════════════════
*/

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "./BaseStrategy.sol";
import "./interfaces/IProtocols.sol";

contract CurveConvexStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    ICurvePool public immutable curvePool;   // the pool that mints `asset` (the LP)
    IConvexBooster public immutable booster;
    IConvexRewards public immutable convexRewards;
    ISwapRouter public immutable router;
    uint256 public immutable pid;            // Convex pool id
    uint256 public immutable addIndex;       // which pool coin we deposit to re-add liquidity
    address public immutable addToken;       // = curvePool.coins(addIndex)

    mapping(address => bytes) public rewardPath; // reward -> ... -> addToken

    event RewardPathSet(address reward, bytes path);

    constructor(
        IERC20 _lpAsset,          // the Curve LP token = the vault asset
        ICurvePool _curvePool,
        IConvexBooster _booster,
        IConvexRewards _convexRewards,
        ISwapRouter _router,
        uint256 _pid,
        uint256 _addIndex,        // 0 or 1
        string memory _name,
        string memory _symbol,
        address _management,
        address _keeper
    ) BaseStrategy(_lpAsset, _name, _symbol, _management, _keeper) {
        curvePool = _curvePool;
        booster = _booster;
        convexRewards = _convexRewards;
        router = _router;
        pid = _pid;
        addIndex = _addIndex;
        address coin = _curvePool.coins(_addIndex);
        addToken = coin;

        _lpAsset.forceApprove(address(_booster), type(uint256).max); // LP -> Convex
        IERC20(coin).forceApprove(address(_curvePool), type(uint256).max); // coin -> Curve add_liquidity
    }

    function setRewardPath(address reward, bytes calldata path) external onlyManagement {
        rewardPath[reward] = path;
        if (!isRewardToken[reward]) {
            isRewardToken[reward] = true;
            rewardTokens.push(reward);
        }
        IERC20(reward).forceApprove(address(router), type(uint256).max);
        emit RewardPathSet(reward, path);
    }

    function _investCapital(uint256 lpAmount) internal override {
        booster.deposit(pid, lpAmount, true); // stake LP in Convex
    }

    function _divestCapital(uint256 lpAmount) internal override {
        convexRewards.withdrawAndUnwrap(lpAmount, false); // LP back to this contract
    }

    function _claimRewards() internal override {
        if (rewardTokens.length == 0) return;
        convexRewards.getReward(); // CRV + CVX to this contract
    }

    /// @dev reward -> addToken (Uniswap V3), then add_liquidity -> new LP (the asset).
    function _swapRewardToAsset(address reward, uint256 amount) internal override {
        bytes memory path = rewardPath[reward];
        if (path.length == 0) return;
        router.exactInput(
            ISwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0 // production: guard with oracle / private mempool
            })
        );
        // convert the pool coin we now hold into LP by adding liquidity
        uint256 coinBal = IERC20(addToken).balanceOf(address(this));
        if (coinBal > 0) {
            uint256[2] memory amounts;
            amounts[addIndex] = coinBal;
            curvePool.add_liquidity(amounts, 0); // mints LP (asset) to this contract
        }
    }

    function _positionValue() internal view override returns (uint256) {
        // staked LP balance is denominated in the LP token = the vault asset
        return convexRewards.balanceOf(address(this));
    }

    function _emergencyLiquidate(uint256 lpAmount) internal override {
        convexRewards.withdrawAndUnwrap(lpAmount, false);
    }
}
