// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 ════════════════════════════════════════════════════════════════════════════════
  AaveV3Strategy — supply lending on Aave V3
 ════════════════════════════════════════════════════════════════════════════════
  STRATEGY
    Lends the base asset (USDC, DAI, WETH…) to the Aave V3 pool and earns the
    borrower-paid supply interest. Deposited asset is exchanged 1:1 for an interest-
    bearing `aToken` whose balance grows automatically as interest accrues.

  HOW USER FUNDS ARE USED
    deposit  -> base calls _investCapital -> pool.supply(asset) -> we hold aTokens
    yield    -> the aToken balance grows continuously (interest)
    report   -> if the market emits incentive rewards, they are claimed and swapped
                back into `asset` via a Uniswap V3 path, then re-supplied (compounding)
    withdraw -> _divestCapital -> pool.withdraw(asset) -> asset returned to the user

  VALUATION  : _positionValue() = aToken.balanceOf(this)  (already asset-denominated)
  EXIT       : instant (unless Aave utilisation is ~100%)
  REWARD FLOW: reward token -> Uniswap V3 exactInput(path) -> asset -> re-supply
 ════════════════════════════════════════════════════════════════════════════════
*/

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "./BaseStrategy.sol";
import "./interfaces/IProtocols.sol";

contract AaveV3Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IAaveV3Pool public immutable pool;
    IERC20 public immutable aToken;
    IAaveRewards public immutable rewardsController;
    ISwapRouter public immutable router;

    /// @notice reward token => Uniswap V3 encoded path (reward -> ... -> asset)
    mapping(address => bytes) public rewardPath;

    event RewardPathSet(address reward, bytes path);

    constructor(
        IERC20 _asset,
        IERC20 _aToken,
        IAaveV3Pool _pool,
        IAaveRewards _rewards,
        ISwapRouter _router,
        string memory _name,
        string memory _symbol,
        address _management,
        address _keeper
    ) BaseStrategy(_asset, _name, _symbol, _management, _keeper) {
        aToken = _aToken;
        pool = _pool;
        rewardsController = _rewards;
        router = _router;
        _asset.forceApprove(address(_pool), type(uint256).max);
    }

    /// @notice Set the Uniswap V3 swap route for a reward token (also register it).
    /// @param  path abi.encodePacked(reward, fee, [mid, fee,] asset)
    function setRewardPath(address reward, bytes calldata path) external onlyManagement {
        rewardPath[reward] = path;
        if (!isRewardToken[reward]) {
            isRewardToken[reward] = true;
            rewardTokens.push(reward);
        }
        IERC20(reward).forceApprove(address(router), type(uint256).max);
        emit RewardPathSet(reward, path);
    }

    function _investCapital(uint256 assets) internal override {
        pool.supply(asset(), assets, address(this), 0);
    }

    function _divestCapital(uint256 assets) internal override {
        pool.withdraw(asset(), assets, address(this));
    }

    function _claimRewards() internal override {
        if (rewardTokens.length == 0) return;
        address[] memory assets = new address[](1);
        assets[0] = address(aToken);
        rewardsController.claimAllRewards(assets, address(this));
    }

    function _swapRewardToAsset(address reward, uint256 amount) internal override {
        bytes memory path = rewardPath[reward];
        if (path.length == 0) return; // no route configured -> leave for management
        router.exactInput(
            ISwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0 // NOTE: guard via oracle/private-mempool keeper in production
            })
        );
    }

    function _positionValue() internal view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    function _emergencyLiquidate(uint256 assets) internal override {
        pool.withdraw(asset(), assets, address(this));
    }
}
