// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import {MockERC20} from "./Mocks.sol";
import {ReserveDataLegacy} from "../../src/strategies/common/AaveV3LendStrategy.sol";
import {ICometRewards} from "../../src/strategies/common/CompoundV3Strategy.sol";

contract MockAToken is ERC20 {
    uint8 private immutable _decimals;
    address public immutable pool;
    address public immutable underlying;

    constructor(address _pool, address _underlying) ERC20("Mock aToken", "maTKN") {
        pool = _pool;
        underlying = _underlying;
        _decimals = MockERC20(_underlying).decimals();
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == pool, "ONLY_POOL");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == pool, "ONLY_POOL");
        _burn(from, amount);
    }

    function accrue(address holder, uint256 bps) external {
        _mint(holder, (balanceOf(holder) * bps) / 10_000);
    }

    function slash(address holder, uint256 bps) external {
        _burn(holder, (balanceOf(holder) * bps) / 10_000);
    }

    function payOut(address to, uint256 amount) external {
        require(msg.sender == pool, "ONLY_POOL");
        SafeERC20.safeTransfer(IERC20(underlying), to, amount);
    }
}

contract MockAavePool {
    using SafeERC20 for IERC20;

    mapping(address => address) public aTokenOf;
    bool public paused;
    uint128 public liquidityRate = 3e25;

    function register(address asset, address aToken) external {
        aTokenOf[asset] = aToken;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setLiquidityRate(uint128 r) external {
        liquidityRate = r;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(!paused, "RESERVE_PAUSED");
        IERC20(asset).safeTransferFrom(msg.sender, aTokenOf[asset], amount);
        MockAToken(aTokenOf[asset]).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(!paused, "RESERVE_PAUSED");
        MockAToken a = MockAToken(aTokenOf[asset]);
        uint256 held = a.balanceOf(msg.sender);
        if (amount == type(uint256).max || amount > held) amount = held;

        uint256 liquidity = IERC20(asset).balanceOf(address(a));
        require(amount <= liquidity, "NOT_ENOUGH_LIQUIDITY");

        a.burn(msg.sender, amount);
        a.payOut(to, amount);
        return amount;
    }

    function drainLiquidity(address asset, uint256 amount) external {
        MockAToken(aTokenOf[asset]).payOut(address(0xdead), amount);
    }

    function getReserveData(address asset) external view returns (ReserveDataLegacy memory d) {
        d.currentLiquidityRate = liquidityRate;
        d.aTokenAddress = aTokenOf[asset];
    }
}

contract MockAaveRewardsController {
    mapping(address => address) public claimers;
    mapping(address => mapping(address => uint256)) public owed;
    address[] public rewardList;

    function setClaimer(address user, address claimer) external {
        claimers[user] = claimer;
    }

    function getClaimer(address user) external view returns (address) {
        return claimers[user];
    }

    function addReward(address token) external {
        rewardList.push(token);
    }

    function accrue(address user, address reward, uint256 amount) external {
        owed[user][reward] += amount;
    }

    function getUserRewards(address[] calldata, address user, address reward) external view returns (uint256) {
        return owed[user][reward];
    }

    function getAllUserRewards(address[] calldata, address user)
        external
        view
        returns (address[] memory list, uint256[] memory amounts)
    {
        list = rewardList;
        amounts = new uint256[](list.length);
        for (uint256 i; i < list.length; ++i) {
            amounts[i] = owed[user][list[i]];
        }
    }

    function claimAllRewardsOnBehalf(address[] calldata, address user, address to)
        external
        returns (address[] memory list, uint256[] memory amounts)
    {
        require(claimers[user] == msg.sender, "NOT_CLAIMER");
        list = rewardList;
        amounts = new uint256[](list.length);
        for (uint256 i; i < list.length; ++i) {
            uint256 amount = owed[user][list[i]];
            if (amount == 0) continue;
            owed[user][list[i]] = 0;
            amounts[i] = amount;
            MockERC20(list[i]).mint(to, amount);
        }
    }
}

contract MockComet {
    using SafeERC20 for IERC20;

    address public immutable baseToken;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint64) public baseTrackingAccrued;
    bool public supplyPaused;
    bool public withdrawPaused;

    constructor(address _base) {
        baseToken = _base;
    }

    function setSupplyPaused(bool p) external {
        supplyPaused = p;
    }

    function setWithdrawPaused(bool p) external {
        withdrawPaused = p;
    }

    function isSupplyPaused() external view returns (bool) {
        return supplyPaused;
    }

    function isWithdrawPaused() external view returns (bool) {
        return withdrawPaused;
    }

    function supply(address asset, uint256 amount) external {
        require(!supplyPaused, "SUPPLY_PAUSED");
        require(asset == baseToken, "BAD_ASSET");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
    }

    function withdraw(address asset, uint256 amount) external {
        require(!withdrawPaused, "WITHDRAW_PAUSED");
        require(asset == baseToken, "BAD_ASSET");
        require(balanceOf[msg.sender] >= amount, "INSUFFICIENT");
        require(IERC20(asset).balanceOf(address(this)) >= amount, "NO_LIQUIDITY");
        balanceOf[msg.sender] -= amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function accrue(address account, uint256 bps) external {
        uint256 gain = (balanceOf[account] * bps) / 10_000;
        balanceOf[account] += gain;
        MockERC20(baseToken).mint(address(this), gain);
    }

    function accrueRewards(address account, uint64 amount) external {
        baseTrackingAccrued[account] += amount;
    }

    function drainLiquidity(uint256 amount) external {
        IERC20(baseToken).safeTransfer(address(0xdead), amount);
    }

    function getReserves() external pure returns (int256) {
        return 0;
    }

    function getUtilization() external pure returns (uint256) {
        return 5e17;
    }

    function getSupplyRate(uint256) external pure returns (uint64) {
        return 1e9;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function totalBorrow() external pure returns (uint256) {
        return 0;
    }
}

contract MockCometRewards {
    address public immutable comp;
    mapping(address => uint256) public rewardsClaimedOf;
    bool public legacyLayout;

    constructor(address _comp) {
        comp = _comp;
    }

    function setLegacyLayout(bool on) external {
        legacyLayout = on;
    }

    function rewardConfig(address) external view returns (ICometRewards.RewardConfig memory c) {
        require(!legacyLayout, "OLD_LAYOUT");
        c.token = comp;
        c.rescaleFactor = 1e12;
        c.shouldUpscale = true;
        c.multiplier = 1e18;
    }

    function legacyRewardConfig() external view returns (address, uint64, bool) {
        return (comp, 1e12, true);
    }

    function rewardsClaimed(address, address account) external view returns (uint256) {
        return rewardsClaimedOf[account];
    }

    function claim(address cometAddr, address src, bool) external {
        uint256 accrued = uint256(MockComet(cometAddr).baseTrackingAccrued(src)) * 1e12;
        uint256 already = rewardsClaimedOf[src];
        if (accrued <= already) return;
        uint256 owed = accrued - already;
        rewardsClaimedOf[src] = accrued;
        MockERC20(comp).mint(src, owed);
    }
}

contract MockCometRewardsLegacy {
    struct LegacyRewardConfig {
        address token;
        uint64 rescaleFactor;
        bool shouldUpscale;
    }

    address public immutable comp;
    mapping(address => uint256) public rewardsClaimedOf;

    constructor(address _comp) {
        comp = _comp;
    }

    function rewardConfig(address) external view returns (LegacyRewardConfig memory c) {
        c.token = comp;
        c.rescaleFactor = 1e12;
        c.shouldUpscale = true;
    }

    function rewardsClaimed(address, address account) external view returns (uint256) {
        return rewardsClaimedOf[account];
    }

    function claim(address cometAddr, address src, bool) external {
        uint256 accrued = uint256(MockComet(cometAddr).baseTrackingAccrued(src)) * 1e12;
        uint256 already = rewardsClaimedOf[src];
        if (accrued <= already) return;
        uint256 owed = accrued - already;
        rewardsClaimedOf[src] = accrued;
        MockERC20(comp).mint(src, owed);
    }
}

contract MockCurvePool {
    using SafeERC20 for IERC20;

    address[] public coinList;
    address public immutable lp;
    uint256 public virtualPrice = 1e18;
    uint256 public exitLossBps;

    constructor(address[] memory _coins, address _lp) {
        coinList = _coins;
        lp = _lp;
    }

    function coins(uint256 i) external view returns (address) {
        return coinList[i];
    }

    function get_virtual_price() external view returns (uint256) {
        return virtualPrice;
    }

    function accrueFeesBps(uint256 bps) external {
        virtualPrice = (virtualPrice * (10_000 + bps)) / 10_000;
    }

    function setExitLossBps(uint256 bps) external {
        exitLossBps = bps;
    }

    function add_liquidity(uint256[3] calldata amounts, uint256 minMint) external {
        _add(amounts[0], amounts[1], amounts[2], 0, minMint, 3);
    }

    function add_liquidity(uint256[2] calldata amounts, uint256 minMint) external {
        _add(amounts[0], amounts[1], 0, 0, minMint, 2);
    }

    function add_liquidity(uint256[4] calldata amounts, uint256 minMint) external {
        _add(amounts[0], amounts[1], amounts[2], amounts[3], minMint, 4);
    }

    function _add(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 minMint, uint256 n) private {
        uint256 minted;
        uint256[4] memory amounts = [a0, a1, a2, a3];
        for (uint256 i; i < n; ++i) {
            if (amounts[i] == 0) continue;
            IERC20(coinList[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            uint256 scale = 10 ** (36 - MockERC20(coinList[i]).decimals());
            minted += Math.mulDiv(amounts[i], scale, virtualPrice);
        }
        require(minted >= minMint, "SLIPPAGE");
        MockERC20(lp).mint(msg.sender, minted);
    }

    function remove_liquidity_one_coin(uint256 lpAmount, int128 i, uint256 minOut) external {
        address coin = coinList[uint256(int256(i))];
        uint256 scale = 10 ** (36 - MockERC20(coin).decimals());
        uint256 out = Math.mulDiv(lpAmount, virtualPrice, scale);
        out = (out * (10_000 - exitLossBps)) / 10_000;
        require(out >= minOut, "SLIPPAGE");
        MockERC20(lp).burn(msg.sender, lpAmount);
        uint256 held = IERC20(coin).balanceOf(address(this));
        if (held < out) MockERC20(coin).mint(address(this), out - held);
        IERC20(coin).safeTransfer(msg.sender, out);
    }
}

contract MockConvexRewards {
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public earnedOf;
    address public immutable lp;
    address public immutable crv;
    address public immutable cvx;
    address public booster;
    bool public broken;

    constructor(address _lp, address _crv, address _cvx) {
        lp = _lp;
        crv = _crv;
        cvx = _cvx;
    }

    function setBooster(address b) external {
        booster = b;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function stakeFor(address account, uint256 amount) external {
        require(msg.sender == booster, "ONLY_BOOSTER");
        balanceOf[account] += amount;
    }

    function accrue(address account, uint256 amount) external {
        earnedOf[account] += amount;
    }

    function earned(address account) external view returns (uint256) {
        return earnedOf[account];
    }

    function getReward() external returns (bool) {
        uint256 amount = earnedOf[msg.sender];
        earnedOf[msg.sender] = 0;
        if (amount != 0) {
            MockERC20(crv).mint(msg.sender, amount);
            MockERC20(cvx).mint(msg.sender, amount / 2);
        }
        return true;
    }

    function withdrawAndUnwrap(uint256 amount, bool) external returns (bool) {
        require(!broken, "GAUGE_BROKEN");
        require(balanceOf[msg.sender] >= amount, "INSUFFICIENT");
        balanceOf[msg.sender] -= amount;
        MockERC20(lp).mint(msg.sender, amount);
        return true;
    }
}

contract MockConvexBooster {
    using SafeERC20 for IERC20;

    address public immutable lp;
    MockConvexRewards public immutable rewards;

    constructor(address _lp, address _rewards) {
        lp = _lp;
        rewards = MockConvexRewards(_rewards);
    }

    function deposit(uint256, uint256 amount, bool) external returns (bool) {
        IERC20(lp).safeTransferFrom(msg.sender, address(this), amount);
        MockERC20(lp).burn(address(this), amount);
        rewards.stakeFor(msg.sender, amount);
        return true;
    }
}

contract MockWstEth is ERC20 {
    uint256 public rate = 1.1e18;

    constructor() ERC20("Mock wstETH", "wstETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function accrueBps(uint256 bps) external {
        rate = (rate * (10_000 + bps)) / 10_000;
    }

    function getStETHByWstETH(uint256 wst) external view returns (uint256) {
        return Math.mulDiv(wst, rate, 1e18);
    }

    function getWstETHByStETH(uint256 st) external view returns (uint256) {
        return Math.mulDiv(st, 1e18, rate);
    }
}

contract MockBeefyVault is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable wantToken;
    uint256 public pps = 1e18;

    constructor(address _want) ERC20("Mock moo", "mooTKN") {
        wantToken = IERC20(_want);
    }

    function want() external view returns (address) {
        return address(wantToken);
    }

    function getPricePerFullShare() external view returns (uint256) {
        return pps;
    }

    function accrueBps(uint256 bps) external {
        pps = (pps * (10_000 + bps)) / 10_000;
    }

    function deposit(uint256 amount) external {
        wantToken.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, Math.mulDiv(amount, 1e18, pps));
    }

    function withdraw(uint256 shares) external {
        uint256 amount = Math.mulDiv(shares, pps, 1e18);
        _burn(msg.sender, shares);
        uint256 held = wantToken.balanceOf(address(this));
        if (held < amount) MockERC20(address(wantToken)).mint(address(this), amount - held);
        wantToken.safeTransfer(msg.sender, amount);
    }
}
