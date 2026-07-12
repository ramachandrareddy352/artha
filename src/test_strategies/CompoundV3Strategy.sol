// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 ════════════════════════════════════════════════════════════════════════════════
  CompoundV3Strategy — supply lending on Compound III (Comet)
 ════════════════════════════════════════════════════════════════════════════════
  STRATEGY
    Supplies the Comet market's base token (e.g. USDC) and earns supply interest plus
    COMP incentive rewards. A Comet market has exactly one base (borrowable) asset;
    this strategy's `asset` MUST be that base token.

  HOW USER FUNDS ARE USED
    deposit  -> _investCapital -> comet.supply(asset) -> our Comet base balance grows
    yield    -> Comet.balanceOf(this) accrues supply interest continuously
    report   -> claim COMP from the rewards contract, swap COMP -> asset on Uniswap V3,
                re-supply (compounding)
    withdraw -> _divestCapital -> comet.withdraw(asset) -> asset returned to the user

  VALUATION  : _positionValue() = comet.balanceOf(this)  (present value of supply)
  EXIT       : instant (unless utilisation ~100%)
  REWARD FLOW: COMP -> Uniswap V3 exactInput(path) -> asset -> re-supply
 ════════════════════════════════════════════════════════════════════════════════
*/

import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "./BaseStrategy.sol";
import "./interfaces/IProtocols.sol";

contract CompoundV3Strategy is BaseStrategy {
    using SafeERC20 for IERC20;

    IComet public immutable comet;
    ICometRewards public immutable cometRewards;
    ISwapRouter public immutable router;

    mapping(address => bytes) public rewardPath;

    event RewardPathSet(address reward, bytes path);

    constructor(
        IERC20 _asset, // must equal comet.baseToken()
        IComet _comet,
        ICometRewards _cometRewards,
        ISwapRouter _router,
        string memory _name,
        string memory _symbol,
        address _management,
        address _keeper
    ) BaseStrategy(_asset, _name, _symbol, _management, _keeper) {
        require(address(_asset) == _comet.baseToken(), "asset!=base");
        comet = _comet;
        cometRewards = _cometRewards;
        router = _router;
        _asset.forceApprove(address(_comet), type(uint256).max);
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

    function _investCapital(uint256 assets) internal override {
        comet.supply(asset(), assets);
    }

    function _divestCapital(uint256 assets) internal override {
        comet.withdraw(asset(), assets);
    }

    function _claimRewards() internal override {
        if (rewardTokens.length == 0) return;
        cometRewards.claim(address(comet), address(this), true);
    }

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
    }

    function _positionValue() internal view override returns (uint256) {
        return comet.balanceOf(address(this));
    }

    function _emergencyLiquidate(uint256 assets) internal override {
        comet.withdraw(asset(), assets);
    }
}
