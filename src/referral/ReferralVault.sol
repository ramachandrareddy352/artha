// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "./ReferralSystem.sol";

/**
 * @title  ReferralVault
 * @notice Top layer of the chain — holds the ARTHA and pays code OWNERS based on
 *         HOW MUCH referred capital they bring and HOW LONG it stays. Because it
 *         inherits ReferralSystem (registry) and ReferralVaultManager (admin), it
 *         reads codeOwner / traderToCode directly, with no external calls.
 *
 *             ReferralVaultManager  <-  ReferralSystem  <-  ReferralVault  (deployed)
 *
 *  ─────────────────────────────────────────────────────────────────────────
 *  THREE POOLS, DIFFERENT RATES (high risk => higher rate => more reward).
 *  Everything is tracked PER POOL: each pool has its own rate, its own
 *  accumulator, and its own per-code balances. poolId: 0=LOW, 1=MEDIUM, 2=HIGH.
 *
 *  THE MECHANISM (per pool): one accumulator, updated only when something changes.
 *      accArthaPerToken += currentRate * dt * ACC / (USDC_UNIT * YEAR)
 *      earned(code) = referredBalance(code) * accArthaPerToken / ACC - rewardDebt
 *  More capital -> bigger balance; more time -> bigger accumulator. No daily cron,
 *  O(1) gas, and the OWNER can claim any time (claim settles to `now` first).
 *
 *  RATE CHANGE: setRate() calls _updateIndex() FIRST (banks the old rate up to
 *  now), then writes the new rate — so old accrual keeps the old rate and only
 *  future accrual uses the new one. Zero retroactivity.
 *
 *  DECIMALS: balances are raw USDC (6 dp). A rate is ARTHA-wei per ONE whole USDC
 *  per year (1e18 = "1.0 ARTHA/USDC/yr"); USDC_UNIT (1e6) converts raw -> whole.
 *
 *  FUNDING: does NOT mint. Mint ARTHA into this contract up front; claims transfer
 *  from balance. Admin can sweep genuine excess ARTHA or any stray token via rescue.
 */
contract ReferralVault is ReferralSystem, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ACC = 1e18;      // accumulator precision
    uint256 public constant YEAR = 365 days; // seconds per year
    uint256 public constant USDC_UNIT = 1e6; // one whole USDC (6 decimals)

    uint8 public constant POOL_LOW = 0;
    uint8 public constant POOL_MEDIUM = 1;
    uint8 public constant POOL_HIGH = 2;
    uint8 public constant POOL_COUNT = 3;

    IERC20 public immutable artha;
 
    /// @notice Per-pool global reward state.
    struct PoolState {
        uint256 currentRate;      // ARTHA-wei per whole USDC per year
        uint256 accArthaPerToken; // accumulator (scaled by ACC)
        uint256 lastUpdate;       // last time the accumulator advanced
        uint256 totalReferred;    // total active referred USDC in this pool
    }

    /// @notice Per-pool, per-code account.
    struct CodeAccount {
        uint256 referredBalance;  // active referred USDC (raw 6dp)
        uint256 rewardDebt;       // checkpoint: balance * acc / ACC at last settle
        uint256 earned;           // settled, claimable ARTHA
        uint256 claimed;          // lifetime claimed ARTHA (tracking)
    }

    /// @notice poolId => pool state.
    mapping(uint8 => PoolState) public poolState;

    /// @notice poolId => code => account.
    mapping(uint8 => mapping(bytes32 => CodeAccount)) public codeAccount;

    // ---- vault-wide totals (rescue safety) ----
    uint256 public totalEarnedArtha;
    uint256 public totalClaimedArtha;

    event RateUpdated(uint8 indexed poolId, uint256 oldRate, uint256 newRate);
    event Referred(uint8 indexed poolId, bytes32 indexed code, uint256 principal, uint256 newBalance);
    event Unreferred(uint8 indexed poolId, bytes32 indexed code, uint256 principal, uint256 newBalance);
    event RewardSettled(uint8 indexed poolId, bytes32 indexed code, uint256 pending);
    event RewardClaimed(uint8 indexed poolId, bytes32 indexed code, address indexed owner, address to, uint256 amount);
    event Rescued(address indexed token, address to, uint256 amount);

    constructor(address _artha, address _admin) ReferralSystem(_admin) {
        require(_artha != address(0), "INVALID_ARTHA");
        artha = IERC20(_artha);
        // Start each pool's clock at deployment so the first rate period is measured
        // from now (not from timestamp 0).
        uint256 t = block.timestamp;
        poolState[POOL_LOW].lastUpdate = t;
        poolState[POOL_MEDIUM].lastUpdate = t;
        poolState[POOL_HIGH].lastUpdate = t;
    }

    function _validPool(uint8 poolId) private pure {
        require(poolId < POOL_COUNT, "INVALID_POOL_ID");
    }

    /// @dev Advance a pool's accumulator at its CURRENT rate over [lastUpdate, now].
    ///      Safe because setRate() calls this before changing the rate.
    function _updateIndex(uint8 poolId) internal {
        PoolState storage p = poolState[poolId];
        uint256 nowTs = block.timestamp;
        if (nowTs <= p.lastUpdate) return;
        if (p.currentRate != 0) {
            uint256 dt = nowTs - p.lastUpdate;
            p.accArthaPerToken += (p.currentRate * dt * ACC) / (USDC_UNIT * YEAR);
        }
        p.lastUpdate = nowTs;
    }

    /// @dev Bank a code's accrued reward into `earned` and refresh its checkpoint.
    function _settle(uint8 poolId, bytes32 code) internal {
        _updateIndex(poolId);
        CodeAccount storage a = codeAccount[poolId][code];
        uint256 accumulated = (a.referredBalance * poolState[poolId].accArthaPerToken) / ACC;
        uint256 pending = accumulated - a.rewardDebt;
        if (pending != 0) {
            a.earned += pending;
            totalEarnedArtha += pending;
            emit RewardSettled(poolId, code, pending);
        }
        a.rewardDebt = accumulated;
    }

    /**
     * @notice A referred deposit into `poolId`. The code is looked up from the
     *         investor's stored traderToCode — the investor never resends it.
     * @param  poolId    0=LOW, 1=MEDIUM, 2=HIGH.
     * @param  investor  The depositor.
     * @param  principal Referred USDC amount (raw, 6 decimals).
     */
    function notifyDeposit(uint8 poolId, address investor, uint256 principal)
        external
        onlyPool
        whenNotPaused
    {
        _validPool(poolId);
        if (principal == 0) return;

        bytes32 code = traderToCode[investor];
        if (code == bytes32(0)) return;                       // investor set no code
        address owner = codeOwner[code];
        if (owner == address(0) || owner == investor) return; // deactivated / self-referral

        _settle(poolId, code);                                // bank at OLD balance
        CodeAccount storage a = codeAccount[poolId][code];
        a.referredBalance += principal;
        poolState[poolId].totalReferred += principal;
        a.rewardDebt = (a.referredBalance * poolState[poolId].accArthaPerToken) / ACC; // re-checkpoint

        emit Referred(poolId, code, principal, a.referredBalance);
    }

    /**
     * @notice A referred position in `poolId` shrinks or fully exits.
     * @param  poolId    0=LOW, 1=MEDIUM, 2=HIGH.
     * @param  investor  The withdrawing depositor (its stored code is reduced).
     * @param  principal USDC leaving (raw, 6 decimals).
     */
    function notifyWithdraw(uint8 poolId, address investor, uint256 principal)
        external
        onlyPool
        whenNotPaused
    {
        _validPool(poolId);
        if (principal == 0) return;

        bytes32 code = traderToCode[investor];
        if (code == bytes32(0)) return;

        CodeAccount storage a = codeAccount[poolId][code];
        uint256 bal = a.referredBalance;
        if (bal == 0) return;

        _settle(poolId, code);                        // bank up to now first

        uint256 dec = principal > bal ? bal : principal; // clamp (defensive)
        a.referredBalance = bal - dec;
        poolState[poolId].totalReferred -= dec;
        a.rewardDebt = (a.referredBalance * poolState[poolId].accArthaPerToken) / ACC;

        emit Unreferred(poolId, code, dec, a.referredBalance);
    }

    /// @notice Permissionless: bring a code's `earned` up to date in a pool.
    function sync(uint8 poolId, bytes32 code) external {
        _validPool(poolId);
        _settle(poolId, code);
    }

    /**
     * @notice Set a pool's reward rate. Banks the old rate up to `now` FIRST, so
     *         the change is not retroactive. Higher pool = higher rate.
     * @param  poolId  0=LOW, 1=MEDIUM, 2=HIGH.
     * @param  newRate ARTHA-wei per whole USDC per year (e.g. 2e17 = 0.2, 1e18 = 1.0).
     */
    function setRate(uint8 poolId, uint256 newRate) external onlyReferralVaultManager {
        _validPool(poolId);
        _updateIndex(poolId); // freeze old-rate accrual up to this instant
        uint256 old = poolState[poolId].currentRate;
        poolState[poolId].currentRate = newRate;
        emit RateUpdated(poolId, old, newRate);
    }

    /// @notice The code's CURRENT owner withdraws its ARTHA from one pool.
    function claim(uint8 poolId, bytes32 code, address to, uint256 amount)
        public
        nonReentrant
        whenNotPaused
    {
        _validPool(poolId);
        require(to != address(0) && amount != 0, "INVALID_PARAMS");
        require(codeOwner[code] == msg.sender, "NOT_CODE_OWNER");

        _settle(poolId, code); // bring current to now
        CodeAccount storage a = codeAccount[poolId][code];
        require(a.earned >= amount, "INSUFFICIENT_REWARDS");

        a.earned -= amount;               // effect (checks-effects-interactions)
        a.claimed += amount;
        totalClaimedArtha += amount;
        artha.safeTransfer(to, amount);   // transfer rewards
        emit RewardClaimed(poolId, code, msg.sender, to, amount);
    }

    /// @notice Convenience: claim the full earned balance from every pool at once.
    function claimAll(bytes32 code, address to) external {
        require(codeOwner[code] == msg.sender, "NOT_CODE_OWNER");
        for (uint8 i = 0; i < POOL_COUNT; i++) {
            _settle(i, code);
            uint256 amt = codeAccount[i][code].earned;
            if (amt != 0) {
                claim(i, code, to, amt); // reuses owner check + transfer (nonReentrant per call)
            }
        }
    }

    /**
     * @notice Deactivate a code. Requires it to be fully wound down first: no
     *         active referred balance and no unclaimed rewards in ANY pool. This
     *         Executed by code owner or admin.
     */
    function deactivateCode(bytes32 code) external {
        for (uint8 i = 0; i < POOL_COUNT; i++) {
            _settle(i, code);
            CodeAccount storage a = codeAccount[i][code];
            require(a.referredBalance == 0, "HAS_ACTIVE_BALANCE");
            require(a.earned == 0, "HAS_UNCLAIMED_REWARDS");
        }
        _deactivateCode(code); // parent (registry) internal
    }

    /**
     * @notice ONE function to recover funds the vault should not keep:
     *           - excess ARTHA (above what is owed), or any other stray token.
     * @dev    For ARTHA, capped to `balance - settledUnclaimed`, so it can never
     *         touch rewards already credited. NOTE: reward still accruing on active
     *         codes is not reserved here — keep the vault funded above ongoing
     *         accrual and only sweep clear excess.
     */
    function rescue(address token, address to, uint256 amount) external onlyReferralVaultManager {
        require(to != address(0) && amount != 0, "INVALID_PARAMS");
        if (token == address(artha)) {
            uint256 owed = totalEarnedArtha - totalClaimedArtha;
            uint256 bal = artha.balanceOf(address(this));
            uint256 excess = bal > owed ? bal - owed : 0;
            require(amount <= excess, "EXCEEDS_EXCESS");
        }
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @notice Live claimable reward for a code in a pool (settled + accruing).
    function pendingReward(uint8 poolId, bytes32 code) public view returns (uint256) {
        PoolState storage p = poolState[poolId];
        uint256 accNow = p.accArthaPerToken;
        if (block.timestamp > p.lastUpdate && p.currentRate != 0) {
            uint256 dt = block.timestamp - p.lastUpdate;
            accNow += (p.currentRate * dt * ACC) / (USDC_UNIT * YEAR);
        }
        CodeAccount storage a = codeAccount[poolId][code];
        uint256 accumulated = (a.referredBalance * accNow) / ACC;
        return a.earned + (accumulated - a.rewardDebt);
    }

    /// @notice Total live claimable for a code across all three pools.
    function pendingRewardAllPools(bytes32 code) external view returns (uint256 total) {
        for (uint8 i = 0; i < POOL_COUNT; i++) {
            total += pendingReward(i, code);
        }
    }

}
