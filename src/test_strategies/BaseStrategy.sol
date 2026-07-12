// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 ════════════════════════════════════════════════════════════════════════════════
  BaseStrategy — Artha's single-source yield strategy base (improved over Yearn V3)
 ════════════════════════════════════════════════════════════════════════════════

  WHAT THIS IS
  ------------
  An abstract, self-contained ERC-4626 vault that connects ONE asset to ONE external
  yield source. A concrete strategy (Aave, Compound, Curve/Convex, a 4626 wrapper…)
  inherits this and fills in a handful of hooks. Users deposit the `asset`, receive
  strategy shares, and the share price rises as yield accrues.

  HOW USER FUNDS ARE USED (the deposit → yield → withdraw path)
  ------------------------------------------------------------
    deposit(assets)   -> shares minted at the current price-per-share
                      -> the base immediately calls _investCapital(idle), pushing the
                         deposited asset into the external protocol (supply, stake, …)
    (time passes)     -> the position earns interest / rewards
    report()  [keeper]-> _claimRewards() pulls reward tokens in,
                         _swapRewardToAsset() converts EACH reward into `asset`,
                         proceeds are re-invested, and the realised profit is LOCKED
                         and released linearly (sandwich-resistant, see PROFIT LOCK)
    withdraw(assets)  -> the base calls _divestCapital() to pull just enough back from
                         the protocol, then transfers `asset` to the user

  THE IMPROVEMENT OVER YEARN — "reward → asset" where asset may be an LP token
  ---------------------------------------------------------------------------
  Yearn's swappers convert a reward token into a single ERC-20 underlying. Here the
  base makes ZERO assumption about what `asset` is: it can be USDC, DAI, WETH — OR a
  liquidity-provider token (a Curve LP, a Balancer BPT…). The base just loops the
  registered reward tokens and calls the strategy's `_swapRewardToAsset(reward, amt)`:
    • ERC-20 asset  : that hook swaps reward -> asset on a DEX.
    • LP-token asset: that hook swaps reward -> a pool coin, then adds liquidity so the
                      produced LP *is* the asset — the position compounds in LP terms.
  Either way the base's accounting is identical, because everything is denominated in
  `asset`. This is what lets one base serve both "USDC lenders" and "LP compounders".

  PROFIT LOCK (why report() doesn't spike the share price)
  -------------------------------------------------------
  A discrete reward harvest would jump the price-per-share, letting someone deposit
  right before and withdraw right after. So realised profit is added to `lockedProfit`
  and released linearly over `profitMaxUnlockTime`. `totalAssets()` subtracts the
  still-locked amount, so the price rises smoothly instead of in a sandwichable step.

  RENAMED LIFECYCLE (vs Yearn) — a concrete strategy overrides only these:
      _investCapital(assets)               (Yearn: _deployFunds)     put asset to work
      _divestCapital(assets)               (Yearn: _freeFunds)       pull asset back
      _claimRewards()                      (part of _harvestAndReport) claim reward tokens
      _swapRewardToAsset(reward, amount)   (Yearn: swappers)         reward -> asset / LP
      _positionValue()                     (part of _harvestAndReport) asset value in protocol
      _emergencyLiquidate(assets)          (Yearn: _emergencyWithdraw) shutdown-only exit
      _adjustPosition()  [optional]        (Yearn: _tend)            maintenance, no report

  ROLES
      management       : config (fees, unlock time, reward tokens, roles). 2-step handover.
      keeper           : calls report()/tend().
      emergencyAdmin   : can shutdown + emergency-withdraw.
 ════════════════════════════════════════════════════════════════════════════════
*/

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

abstract contract BaseStrategy is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_BPS = 10_000;

    // ---- roles ----
    address public management;
    address public pendingManagement;
    address public keeper;
    address public emergencyAdmin;

    // ---- accounting ----
    /// @dev Recorded total assets (principal + recognised profit, incl. still-locked).
    ///      Adjusted on deposit (+), withdraw (−) and report (± profit/loss). NOT a
    ///      live protocol read — that is what keeps the price flat between reports.
    uint256 public recordedAssets;
    uint256 public lockedProfit;          // profit still releasing
    uint256 public lastReport;            // timestamp of last report
    uint256 public profitMaxUnlockTime;   // linear release window (e.g. 7 days)

    // ---- fees (charged only on harvested reward proceeds; base yield flows to users) ----
    uint16  public performanceFee;        // bps of reward proceeds, ≤ 5000
    address public feeRecipient;

    // ---- reward tokens the harvest will sell into `asset` ----
    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;

    // ---- lifecycle ----
    bool public shutdown;

    event Reported(uint256 profit, uint256 loss, uint256 newRecordedAssets);
    event RewardTokenSet(address token, bool enabled);
    event PerformanceFeeSet(uint16 bps, address recipient);
    event ProfitUnlockTimeSet(uint256 seconds_);
    event KeeperSet(address keeper);
    event EmergencyAdminSet(address admin);
    event ManagementTransferStarted(address pending);
    event ManagementTransferred(address newManagement);
    event Shutdown();

    modifier onlyManagement() {
        require(msg.sender == management, "!management");
        _;
    }
    modifier onlyKeepers() {
        require(msg.sender == keeper || msg.sender == management, "!keeper");
        _;
    }
    modifier onlyEmergency() {
        require(msg.sender == emergencyAdmin || msg.sender == management, "!emergency");
        _;
    }

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _management,
        address _keeper
    ) ERC20(_name, _symbol) ERC4626(_asset) {
        require(_management != address(0), "mgmt=0");
        management = _management;
        keeper = _keeper;
        emergencyAdmin = _management;
        feeRecipient = _management;
        profitMaxUnlockTime = 7 days;
        lastReport = block.timestamp;
    }

    /* ─────────────────────────── ERC-4626 accounting ─────────────────────────── */

    /// @notice Assets backing the shares = recorded assets minus profit still locked.
    function totalAssets() public view override returns (uint256) {
        uint256 locked = _lockedProfitRemaining();
        return recordedAssets > locked ? recordedAssets - locked : 0;
    }

    function _lockedProfitRemaining() internal view returns (uint256) {
        uint256 window = profitMaxUnlockTime;
        if (window == 0) return 0;
        uint256 elapsed = block.timestamp - lastReport;
        if (elapsed >= window) return 0;
        return (lockedProfit * (window - elapsed)) / window;
    }

    /// @dev On deposit: pull + mint (super), record the assets, then invest them.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        require(!shutdown, "shutdown");
        super._deposit(caller, receiver, assets, shares); // transfers asset in, mints shares
        recordedAssets += assets;
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle > 0) _investCapital(idle);
    }

    /// @dev On withdraw: free enough from the protocol, reduce record, then burn + transfer.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) _divestCapital(assets - idle);
        // reduce record by exactly what leaves (rounding favors the vault via ERC4626 math)
        recordedAssets = recordedAssets > assets ? recordedAssets - assets : 0;
        super._withdraw(caller, receiver, owner, assets, shares); // burns shares, transfers asset out
    }

    /* ─────────────────────────── report / harvest ─────────────────────────── */

    /// @notice Keeper entrypoint: harvest rewards into `asset`, reinvest, recognise P&L,
    ///         and lock the profit so the share price rises smoothly.
    function report() external onlyKeepers nonReentrant returns (uint256 profit, uint256 loss) {
        _harvest();

        uint256 actual = IERC20(asset()).balanceOf(address(this)) + _positionValue();
        uint256 recorded = recordedAssets;
        uint256 lockedRem = _lockedProfitRemaining();

        if (actual >= recorded) {
            profit = actual - recorded;
            lockedProfit = lockedRem + profit;   // lock new profit; releases over the window
        } else {
            loss = recorded - actual;
            lockedProfit = lockedRem > loss ? lockedRem - loss : 0; // loss eats locked profit first
        }
        recordedAssets = actual;
        lastReport = block.timestamp;
        emit Reported(profit, loss, actual);
    }

    /// @dev claim → sell each reward into `asset` → take fee on proceeds → reinvest.
    function _harvest() internal {
        IERC20 a = IERC20(asset());
        uint256 balBefore = a.balanceOf(address(this));

        _claimRewards();

        uint256 len = rewardTokens.length;
        for (uint256 i; i < len; ++i) {
            address r = rewardTokens[i];
            if (r == address(a)) continue;
            uint256 bal = IERC20(r).balanceOf(address(this));
            if (bal > 0) _swapRewardToAsset(r, bal); // ERC20 -> asset, or reward -> LP add
        }

        uint256 proceeds = a.balanceOf(address(this)) - balBefore; // new `asset` from rewards
        if (proceeds > 0 && performanceFee > 0 && feeRecipient != address(0)) {
            uint256 fee = (proceeds * performanceFee) / MAX_BPS;
            if (fee > 0) a.safeTransfer(feeRecipient, fee);
        }

        if (!shutdown) {
            uint256 idle = a.balanceOf(address(this));
            if (idle > 0) _investCapital(idle);
        }
    }

    /// @notice Optional maintenance (rebalance, re-peg leverage) with no full report.
    function tend() external onlyKeepers nonReentrant {
        _adjustPosition();
    }

    /* ─────────────────────────── reward-token registry ─────────────────────────── */

    function addRewardToken(address token) external onlyManagement {
        require(token != address(0) && token != asset(), "bad reward");
        require(!isRewardToken[token], "exists");
        isRewardToken[token] = true;
        rewardTokens.push(token);
        emit RewardTokenSet(token, true);
    }

    function removeRewardToken(address token) external onlyManagement {
        require(isRewardToken[token], "!reward");
        isRewardToken[token] = false;
        uint256 len = rewardTokens.length;
        for (uint256 i; i < len; ++i) {
            if (rewardTokens[i] == token) {
                rewardTokens[i] = rewardTokens[len - 1];
                rewardTokens.pop();
                break;
            }
        }
        emit RewardTokenSet(token, false);
    }

    function rewardTokensLength() external view returns (uint256) {
        return rewardTokens.length;
    }

    /* ─────────────────────────── config ─────────────────────────── */

    function setPerformanceFee(uint16 _bps, address _recipient) external onlyManagement {
        require(_bps <= 5_000, "fee>50%");
        require(_recipient != address(0) || _bps == 0, "recipient=0");
        performanceFee = _bps;
        feeRecipient = _recipient;
        emit PerformanceFeeSet(_bps, _recipient);
    }

    function setProfitMaxUnlockTime(uint256 _seconds) external onlyManagement {
        require(_seconds <= 30 days, "too long");
        // settle current lock into the price before shortening/lengthening the window
        recordedAssets = recordedAssets; // no-op marker; totalAssets uses live remaining
        profitMaxUnlockTime = _seconds;
        emit ProfitUnlockTimeSet(_seconds);
    }

    function setKeeper(address _keeper) external onlyManagement {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    function setEmergencyAdmin(address _admin) external onlyManagement {
        require(_admin != address(0), "admin=0");
        emergencyAdmin = _admin;
        emit EmergencyAdminSet(_admin);
    }

    function transferManagement(address _pending) external onlyManagement {
        pendingManagement = _pending;
        emit ManagementTransferStarted(_pending);
    }

    function acceptManagement() external {
        require(msg.sender == pendingManagement, "!pending");
        management = pendingManagement;
        pendingManagement = address(0);
        emit ManagementTransferred(msg.sender);
    }

    /* ─────────────────────────── emergency ─────────────────────────── */

    function shutdownStrategy() external onlyEmergency {
        shutdown = true;
        emit Shutdown();
    }

    /// @notice Pull `assets` out of the yield source to idle (only when shut down), so
    ///         depositors can withdraw even if the source is impaired.
    function emergencyWithdraw(uint256 assets) external onlyEmergency {
        require(shutdown, "!shutdown");
        _emergencyLiquidate(assets);
    }

    /* ─────────────────────────── views ─────────────────────────── */

    function pricePerShare() external view returns (uint256) {
        return convertToAssets(10 ** decimals());
    }

    function lockedProfitRemaining() external view returns (uint256) {
        return _lockedProfitRemaining();
    }

    /* ═══════════════════════ hooks a concrete strategy MUST implement ═══════════════════════ */

    /// @dev Put `assets` of the base asset to work in the external protocol.
    function _investCapital(uint256 assets) internal virtual;

    /// @dev Pull `assets` of the base asset back from the protocol to idle.
    function _divestCapital(uint256 assets) internal virtual;

    /// @dev Claim reward tokens FROM the protocol INTO this contract (no swapping).
    function _claimRewards() internal virtual;

    /// @dev Convert `amount` of `reward` into the base `asset`. If `asset` is an LP
    ///      token, this swaps to a pool coin and adds liquidity so the output IS `asset`.
    function _swapRewardToAsset(address reward, uint256 amount) internal virtual;

    /// @dev Current value, denominated in `asset`, of everything held in the protocol.
    function _positionValue() internal view virtual returns (uint256);

    /// @dev Shutdown-only: move `assets` from the protocol to idle.
    function _emergencyLiquidate(uint256 assets) internal virtual;

    /// @dev Optional maintenance; default no-op. Override for loopers etc.
    function _adjustPosition() internal virtual {}
}
