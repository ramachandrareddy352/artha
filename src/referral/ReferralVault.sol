// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "./VaultManager.sol";

/// @dev Minimal view the vault needs from the standalone ReferralSystem registry.
interface IReferralSystem {
    function getCodeOwner(bytes32 code) external view returns (address);
    function isValidCode(bytes32 code) external view returns (bool);
    function deactivateCode(bytes32 code) external;
}

/*//////////////////////////////////////////////////////////////////////////
                               ReferralVault
//////////////////////////////////////////////////////////////////////////*/
/**
 * @title  ReferralVault
 * @notice Holds the ARTHA earmarked for referral rewards and pays code OWNERS
 *         based on HOW MUCH referred capital they bring and HOW LONG it stays.
 *         The code owner can withdraw at ANY time — they never have to wait for
 *         the investor to do anything.
 *
 *  ─────────────────────────────────────────────────────────────────────────
 *  THE MECHANISM: one global accumulator, updated only when something changes.
 *
 *  We never loop over codes and never run a daily job. Instead we keep a single
 *  running number, `accArthaPerToken` = "ARTHA earned per 1 USDC of referred
 *  capital, integrated over time". It advances by (rate x elapsed time):
 *
 *      accArthaPerToken += currentRate * dt * ACC / (USDC_UNIT * YEAR)
 *
 *  Each code stores its referred balance and a checkpoint (`rewardDebt`). Its
 *  earned amount at any moment is:
 *
 *      earned = referredBalance * accArthaPerToken / ACC - rewardDebt
 *
 *  Because the accumulator already folds in "rate x time", multiplying by the
 *  code's balance gives exactly "amount x time x rate". More capital -> bigger
 *  balance; more time -> bigger accumulator. Both increase the reward for free,
 *  with O(1) gas and no cron.
 *
 *  RATE CHANGES (different reward ratio per day/week):
 *  The rate is ONE variable. `setRate` calls `_updateIndex()` FIRST, which banks
 *  everything the OLD rate earned up to that instant into the accumulator; only
 *  then is the new rate written, so it applies purely going forward. Old rate up
 *  to the change, new rate after — zero retroactivity.
 *
 *  ─────────────────────────────────────────────────────────────────────────
 *  WORKED EXAMPLE (matches the hand calculation, 1 month per step = 1/12 year):
 *
 *    User-1 deposits 1,000 USDC under code C.        rate = 1.0 ARTHA/yr/USDC
 *    +1 month -> rate set to 0.5
 *    +1 month -> User-2 deposits 1,000 USDC (code C) [balance now 2,000]
 *    +1 month -> rate set to 0.75
 *    +1 month -> owner withdraws
 *
 *    Segment payouts = balance * rate * (1/12):
 *      A: 1,000 * 1.00 /12 = 83.3333
 *      B: 1,000 * 0.50 /12 = 41.6667
 *      C: 2,000 * 0.50 /12 = 83.3333
 *      D: 2,000 * 0.75 /12 = 125.0000
 *    Owner total = 333.33 ARTHA  <-- the vault produces exactly this.
 *  ─────────────────────────────────────────────────────────────────────────
 *
 *  DECIMALS: referred balances are raw USDC (6 dp). The rate is ARTHA-wei per
 *  ONE whole USDC per year (e.g. 1e18 == "1.0 ARTHA per USDC per year"). The
 *  USDC_UNIT (1e6) in the formula converts raw balance -> whole USDC.
 *
 *  FUNDING: this vault does NOT mint. Mint ARTHA into it up front; claims just
 *  transfer from the balance. Admin can sweep genuine excess ARTHA, or any token
 *  sent here by mistake, via one `rescue`.
 */
contract ReferralVault is VaultManager, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant ACC = 1e18;               // accumulator precision
    uint256 public constant YEAR = 365 days;          // seconds per year
    uint256 public constant USDC_UNIT = 1e6;          // 1 whole USDC (6 decimals)

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The ARTHA token this vault distributes.
    IERC20 public immutable artha;

    /*//////////////////////////////////////////////////////////////
                         REWARD-TRACKING STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The registry the vault reads code/owner from.
    IReferralSystem public referralSystem;

    /// @notice Reward rate: ARTHA-wei per ONE whole USDC of referred capital per
    ///         year. Example: 1e18 = 1.0 ARTHA/yr/USDC, 5e17 = 0.5, 75e16 = 0.75.
    uint256 public currentRate;

    /// @notice THE reward accumulator (ARTHA per USDC of referred capital, scaled
    ///         by ACC), advanced lazily by _updateIndex().
    uint256 public accArthaPerToken;

    /// @notice Last time the accumulator was advanced.
    uint256 public lastUpdate;

    /// @notice Total referred USDC currently active across all codes (info/guard).
    uint256 public totalReferred;

    // ---- per-code accounting ----
    mapping(bytes32 => uint256) public referredBalance; // active referred USDC (raw 6dp) under a code
    mapping(bytes32 => uint256) public rewardDebt;      // checkpoint: balance * acc / ACC at last settle
    mapping(bytes32 => uint256) public earned;          // settled, claimable ARTHA for the code
    mapping(bytes32 => uint256) public claimed;         // lifetime ARTHA claimed by the code (tracking)

    // ---- vault-wide totals (for rescue safety) ----
    uint256 public totalEarnedArtha;   // cumulative ARTHA ever settled into `earned`
    uint256 public totalClaimedArtha;  // cumulative ARTHA ever claimed

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ReferralSystemUpdated(address oldSystem, address newSystem);
    event RateUpdated(uint256 oldRate, uint256 newRate);
    event Referred(bytes32 indexed code, uint256 principal, uint256 newBalance);
    event Unreferred(bytes32 indexed code, uint256 principal, uint256 newBalance);
    event RewardSettled(bytes32 indexed code, uint256 pending, uint256 totalEarned);
    event RewardClaimed(bytes32 indexed code, address indexed owner, address to, uint256 amount);
    event Rescued(address indexed token, address to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _artha, address _admin, address _referralSystem) VaultManager(_admin) {
        require(_artha != address(0), "INVALID_ARTHA");
        require(_referralSystem != address(0), "INVALID_REFERRAL_SYSTEM");
        artha = IERC20(_artha);
        referralSystem = IReferralSystem(_referralSystem);
        lastUpdate = block.timestamp; // start the clock at deployment
    }

    /*//////////////////////////////////////////////////////////////
                        CORE: ACCUMULATOR + SETTLE
    //////////////////////////////////////////////////////////////*/

    /// @dev Advance the global accumulator using the CURRENT rate over the time
    ///      since the last update. Because `setRate` calls this before changing
    ///      the rate, the rate is always constant across [lastUpdate, now].
    function _updateIndex() internal {
        uint256 nowTs = block.timestamp;
        if (nowTs <= lastUpdate) return;

        if (currentRate != 0) {
            uint256 dt = nowTs - lastUpdate;
            // acc += rate * dt * ACC / (USDC_UNIT * YEAR)   (multiply first, divide last)
            accArthaPerToken += (currentRate * dt * ACC) / (USDC_UNIT * YEAR);
        }
        lastUpdate = nowTs;
    }

    /// @dev Bank a code's accrued reward into `earned` and refresh its checkpoint.
    ///      Never changes the balance — callers change the balance around it.
    function _settle(bytes32 code) internal {
        _updateIndex();
        uint256 accumulated = (referredBalance[code] * accArthaPerToken) / ACC;
        uint256 pending = accumulated - rewardDebt[code];
        if (pending != 0) {
            earned[code] += pending;
            totalEarnedArtha += pending;
            emit RewardSettled(code, pending, earned[code]);
        }
        rewardDebt[code] = accumulated;
    }

    /*//////////////////////////////////////////////////////////////
              POSITION HOOKS (called by the Diamond / facets)
              onlyPool == the approved caller; see VaultManager
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A referred deposit was made: grow the code's referred balance.
     *         Settles the OLD balance first, then adds, then re-checkpoints so
     *         the new capital only earns from now on.
     * @param  code      The referral code the investor used.
     * @param  investor  The depositor (used only to block self-referral).
     * @param  principal The referred USDC amount (raw, 6 decimals).
     */
    function notifyDeposit(bytes32 code, address investor, uint256 principal)
        external
        onlyPool
        whenNotPaused
    {
        if (code == bytes32(0) || principal == 0) return; // no referral on this deposit
        address owner = referralSystem.getCodeOwner(code);
        if (owner == address(0) || owner == investor) return; // invalid code or self-referral

        _settle(code);                       // bank accrual at the OLD balance
        referredBalance[code] += principal;  // grow
        totalReferred += principal;
        rewardDebt[code] = (referredBalance[code] * accArthaPerToken) / ACC; // re-checkpoint at new balance

        emit Referred(code, principal, referredBalance[code]);
    }

    /**
     * @notice A referred position shrank or fully exited: reduce the code's
     *         referred balance so it stops earning on the withdrawn capital.
     * @param  code      The referral code.
     * @param  principal The USDC amount leaving (raw, 6 decimals).
     */
    function notifyWithdraw(bytes32 code, uint256 principal) external onlyPool whenNotPaused {
        if (code == bytes32(0) || principal == 0) return;
        uint256 bal = referredBalance[code];
        if (bal == 0) return;

        _settle(code); // bank accrual up to now first

        uint256 dec = principal > bal ? bal : principal; // clamp (defensive)
        referredBalance[code] = bal - dec;
        totalReferred -= dec;
        rewardDebt[code] = (referredBalance[code] * accArthaPerToken) / ACC;

        emit Unreferred(code, dec, referredBalance[code]);
    }

    /// @notice Permissionless: bring a code's `earned` up to date (e.g. so the
    ///         owner sees/claims the latest without any deposit/withdraw happening).
    function sync(bytes32 code) external {
        _settle(code);
    }

    /*//////////////////////////////////////////////////////////////
                                 RATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the reward rate. CRITICAL: banks the old rate up to `now`
     *         BEFORE writing the new one, so past accrual keeps the old rate and
     *         only future accrual uses the new rate.
     * @param  newRate ARTHA-wei per whole USDC per year (e.g. 5e17 = 0.5).
     */
    function setRate(uint256 newRate) external onlyVaultAdmin {
        _updateIndex(); // <-- freeze everything the OLD rate earned, up to this instant
        uint256 old = currentRate;
        currentRate = newRate;
        emit RateUpdated(old, newRate);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The code's CURRENT owner withdraws its ARTHA rewards. Can be called
     *         any time — it settles to `now` first, so nothing is left on the table.
     * @param  code   The code to claim for.
     * @param  to     Where to send the ARTHA.
     * @param  amount How much to withdraw (<= claimable).
     */
    function claim(bytes32 code, address to, uint256 amount) external nonReentrant whenNotPaused {
        require(to != address(0) && amount != 0, "INVALID_PARAMS");
        require(referralSystem.getCodeOwner(code) == msg.sender, "NOT_CODE_OWNER");

        _settle(code); // bring `earned[code]` current up to now

        uint256 bal = earned[code];
        require(bal >= amount, "INSUFFICIENT_REWARDS");

        earned[code] = bal - amount;         // effect (checks-effects-interactions)
        claimed[code] += amount;
        totalClaimedArtha += amount;
        artha.safeTransfer(to, amount);      // interaction
        emit RewardClaimed(code, msg.sender, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Repoint to a new referral registry.
    function setReferralSystem(address _newReferralSystem) external onlyVaultAdmin {
        require(_newReferralSystem != address(0), "INVALID_REFERRAL_SYSTEM");
        address old = address(referralSystem);
        referralSystem = IReferralSystem(_newReferralSystem);
        emit ReferralSystemUpdated(old, _newReferralSystem);
    }

    /**
     * @notice ONE function to recover funds the vault should not keep:
     *           - excess ARTHA (above what is owed), or
     *           - any other token sent here by mistake.
     * @dev    For ARTHA, capped to `balance - settledUnclaimed` so it can never
     *         touch rewards already credited to codes. NOTE: reward still accruing
     *         on active codes is NOT reserved here, so keep the vault funded above
     *         ongoing accrual and only sweep clear excess.
     */
    function rescue(address token, address to, uint256 amount) external onlyVaultAdmin {
        require(to != address(0) && amount != 0, "INVALID_PARAMS");

        if (token == address(artha)) {
            uint256 owed = totalEarnedArtha - totalClaimedArtha; // settled-but-unclaimed
            uint256 bal = artha.balanceOf(address(this));
            uint256 excess = bal > owed ? bal - owed : 0;
            require(amount <= excess, "EXCEEDS_EXCESS");
        }

        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Live claimable reward for a code = settled + not-yet-settled accrual.
    function pendingReward(bytes32 code) public view returns (uint256) {
        uint256 accNow = accArthaPerToken;
        if (block.timestamp > lastUpdate && currentRate != 0) {
            uint256 dt = block.timestamp - lastUpdate;
            accNow += (currentRate * dt * ACC) / (USDC_UNIT * YEAR);
        }
        uint256 accumulated = (referredBalance[code] * accNow) / ACC;
        uint256 unsettled = accumulated - rewardDebt[code];
        return earned[code] + unsettled;
    }

    /// @notice ARTHA the admin could currently rescue (balance minus settled owed).
    function rescuableArtha() external view returns (uint256) {
        uint256 owed = totalEarnedArtha - totalClaimedArtha;
        uint256 bal = artha.balanceOf(address(this));
        return bal > owed ? bal - owed : 0;
    }

    /// @notice Compact snapshot for a code.
    function codeInfo(bytes32 code)
        external
        view
        returns (address owner, uint256 balance, uint256 claimable, uint256 lifetimeClaimed)
    {
        owner = referralSystem.getCodeOwner(code);
        balance = referredBalance[code];
        claimable = pendingReward(code);
        lifetimeClaimed = claimed[code];
    }
}
