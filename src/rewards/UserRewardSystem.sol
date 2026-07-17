// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UserRewardManager.sol";

/**
 * @title  UserRewardSystem
 * @notice The staking REGISTRY layer. It knows "how many shares each user staked in
 *         each vault", "what rate each vault paid over each stretch of time", and
 *         "how much USD each user has accrued but not yet taken". It holds no money.
 *
 *             UserRewardManager  <-  UserRewardSystem  <-  UserRewardVault
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   REWARDS ACCRUE ON USD VALUE, NOT ON SHARE COUNT
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  One share of the USDC vault and one share of the WETH vault are not remotely the
 *  same thing. If rewards accrued per SHARE, the WETH vault would have to run a rate
 *  ~1000x the USDC vault's to pay fairly, and every rate would need re-tuning the
 *  moment ETH moved. So accrual is priced on the USD VALUE staked:
 *
 *      sharePriceUSD = pricePerShare (18dp)  x  oracle.getPrice(baseAsset) (8dp)
 *                      └─ shares -> base ─┘     └─ base -> USD ──────────┘
 *
 *  One rate now serves every vault. At 10% APR:
 *      100 USDC of shares, one year  ->  ~10 USD  ->  ~10 ARTHA
 *      1 WETH of shares @ $1000, one year -> ~100 USD -> ~100 ARTHA
 *  Same knob, same code. The oracle does the work.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE SHARE PRICE MOVES EVERY SECOND. WE ONLY EVER LOOK TWICE.
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  pricePerShare rises continuously as strategies earn, and the oracle price moves
 *  on its own schedule. It is tempting to think accrual therefore needs a continuous
 *  integral over an unknowable curve. It does not -- because the value is only ever
 *  OBSERVED at settle points. Between two settles there are exactly two samples: the
 *  one stored last time, and the one read now. Nobody observes the in-between.
 *
 *  So each window [t0, t1] is represented by the average of its two endpoints:
 *
 *      V0 = shares * lastSharePriceUSD     <- stored at the last settle
 *      V1 = shares * sharePriceUSD(now)    <- read now
 *      accruedUSD = ((V0 + V1) / 2) * rateBps * elapsed / (RATIO_ONE * YEAR)
 *
 *  Exact for linear value growth, near-exact for any realistic yield curve. Using V1
 *  alone would over-pay the whole window at the top price; V0 alone would under-pay.
 *
 *  `lastSharePriceUSD` is written on EVERY settle without exception -- it is the left
 *  endpoint of the NEXT window, so skipping one silently corrupts all future accrual.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   THE INVARIANT THAT MAKES THE AVERAGE LEGAL
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  `shares` is CONSTANT across any accrual window. That is not an assumption, it is
 *  enforced: every share movement routes through notifyShareChange(), which settles
 *  at the OLD share balance BEFORE writing the new one. Settle-then-write. Reverse
 *  that ordering and the entire past window accrues at the new balance -- deposit 1
 *  wei after a year and get paid as though the new balance had been there all along.
 *
 *  ═══════════════════════════════════════════════════════════════════════════
 *   RATES ARE PROSPECTIVE. HISTORY IS APPEND-ONLY.
 *  ═══════════════════════════════════════════════════════════════════════════
 *
 *  setRewardRate() APPENDS a RateEpoch; it never mutates a past one. Money already
 *  staked keeps the rate it earned at the time, and the new rate applies from that
 *  timestamp forward. A user who staked at 10% and wakes up to find the last six
 *  months retroactively repriced to 2% has been robbed; a user who finds them
 *  repriced to 40% has robbed the treasury. Neither can happen here.
 *
 *  A settle spanning a rate change splits the window at the boundary and applies each
 *  epoch's rate to its own segment, interpolating the share price across each segment
 *  so the value used matches the sub-window, not the whole span. The walk is bounded
 *  by MAX_EPOCH_WALK: an unbounded loop over admin-controlled history is a griefing
 *  vector, and a user who cannot settle cannot withdraw.
 *
 *  NOTE ON `stakedAt`: recorded on first stake and never reset. It powers tenure
 *  displays and any future length-of-stake bonus. It is NOT used in the math today --
 *  the rate is flat per vault, per epoch, for everyone.
 */
contract UserRewardSystem is UserRewardManager {
    /// @notice 100_000 = 100%, 1_000 = 1%.
    uint32 public constant RATIO_ONE = 100_000;

    /// @notice Seconds in a reward year.
    uint256 public constant YEAR = 365 days;

    /// @dev Oracle prices are 8dp; ARTHA and the normalised value are 18dp.
    uint256 internal constant PRICE_ONE = 1e8;
    uint256 internal constant WAD = 1e18;

    /// @notice Ceiling on any vault's rate: 100% APR. Above this the incentive is
    ///         almost certainly a fat-finger, and the budget drains in weeks.
    uint256 public constant MAX_RATE = RATIO_ONE;

    /// @notice Upper bound on rate epochs walked in one settle. See the note above.
    uint256 public constant MAX_EPOCH_WALK = 50;

    /**
     * @notice One user's staked position in one vault.
     * @param shares            Shares currently staked. Constant across every window.
     * @param lastAccrualAt     Timestamp of the last settle. 0 => never touched.
     * @param lastSharePriceUSD Share price in USD (18dp) at the last settle. The left
     *                          endpoint of the next window.
     * @param earnedUSD         Settled, unclaimed reward in USD (18dp).
     * @param stakedAt          First-ever stake. Never reset. Display/tenure only.
     */
    struct Stake {
        uint256 shares;
        uint256 lastAccrualAt;
        uint256 lastSharePriceUSD;
        uint256 earnedUSD;
        uint256 stakedAt;
    }

    /**
     * @notice One stretch of time at one rate for one vault.
     * @param startTime When this rate took effect.
     * @param rateBps   APR. 1_000 = 1%, 10_000 = 10%.
     */
    struct RateEpoch {
        uint256 startTime;
        uint256 rateBps;
    }

    /// @notice vault => append-only rate history. Index 0 is set at registration.
    mapping(address => RateEpoch[]) internal _rateEpochs;

    /// @notice vault => user => staked position.
    mapping(address => mapping(address => Stake)) internal _stake;

    /// @notice vault => total shares staked by everyone.
    mapping(address => uint256) public totalStakedShares;

    event RewardRateUpdated(address indexed vault, uint256 oldRate, uint256 newRate, uint256 epochIndex);
    event Settled(
        address indexed vault,
        address indexed user,
        uint256 accruedUSD,
        uint256 elapsed,
        uint256 fromSharePriceUSD,
        uint256 toSharePriceUSD
    );
    event ShareChanged(address indexed vault, address indexed user, uint256 oldShares, uint256 newShares);

    constructor(address _admin) UserRewardManager(_admin) {}

    // ─────────────────────────────── views ──────────────────────────────────────

    /// @notice The rate in force right now for a vault. 0 if never registered.
    function currentRate(address _vault) public view returns (uint256) {
        RateEpoch[] storage eps = _rateEpochs[_vault];
        if (eps.length == 0) return 0;
        return eps[eps.length - 1].rateBps;
    }

    function rateEpochs(address _vault) external view returns (RateEpoch[] memory) {
        return _rateEpochs[_vault];
    }

    function rateEpochCount(address _vault) external view returns (uint256) {
        return _rateEpochs[_vault].length;
    }

    function rateEpochAt(address _vault, uint256 _i) external view returns (uint256 startTime, uint256 rateBps) {
        RateEpoch storage e = _rateEpochs[_vault][_i];
        return (e.startTime, e.rateBps);
    }

    function stakeOf(address _vault, address _user) external view returns (Stake memory) {
        return _stake[_vault][_user];
    }

    function stakedShares(address _vault, address _user) external view returns (uint256) {
        return _stake[_vault][_user].shares;
    }

    // ────────────────────────── accrual internals ───────────────────────────────

    /**
     * @dev USD accrued for one window, split at every rate-epoch boundary inside it.
     *
     *  Each segment gets the share price interpolated at ITS OWN endpoints, not the
     *  window's. A window that spans a rate change at the midpoint must not value the
     *  second segment at the first segment's price -- that is the whole reason the
     *  interpolation exists rather than just averaging V0 and V1 once.
     *
     * @param _vault     The vault being accrued.
     * @param _shares    Share balance, constant across [_from, _to] by construction.
     * @param _from      Window start (the user's lastAccrualAt).
     * @param _to        Window end (now).
     * @param _priceFrom Share price USD (18dp) at _from.
     * @param _priceTo   Share price USD (18dp) at _to.
     */
    function _accrue(
        address _vault,
        uint256 _shares,
        uint256 _from,
        uint256 _to,
        uint256 _priceFrom,
        uint256 _priceTo
    ) internal view returns (uint256 accruedUSD) {
        if (_shares == 0 || _to <= _from) return 0;

        RateEpoch[] storage eps = _rateEpochs[_vault];
        uint256 n = eps.length;
        if (n == 0) return 0;

        uint256 window = _to - _from;
        uint256 i = _epochIndexAt(eps, _from);
        uint256 walked;
        uint256 segStart = _from;

        while (segStart < _to) {
            require(++walked <= MAX_EPOCH_WALK, "EPOCH_WALK_TOO_LONG");

            uint256 segEnd = _to;
            if (i + 1 < n && eps[i + 1].startTime < _to) {
                segEnd = eps[i + 1].startTime;
            }

            // Same-block rate changes can produce zero-length epochs. Skip them.
            if (segEnd <= segStart) {
                if (i + 1 >= n) break;
                unchecked { ++i; }
                segStart = eps[i].startTime;
                continue;
            }

            uint256 rate = eps[i].rateBps;
            if (rate != 0) {
                uint256 pStart = _interpolate(_priceFrom, _priceTo, segStart - _from, window);
                uint256 pEnd = _interpolate(_priceFrom, _priceTo, segEnd - _from, window);

                // avgValueUSD (18dp) = shares * avg(pStart, pEnd) / WAD
                uint256 avgValueUSD = (_shares * (pStart + pEnd)) / (2 * WAD);
                accruedUSD += (avgValueUSD * rate * (segEnd - segStart)) / (RATIO_ONE * YEAR);
            }

            segStart = segEnd;
            if (i + 1 < n) {
                unchecked { ++i; }
            } else {
                break;
            }
        }
    }

    /// @dev Linear interpolation between two prices. Handles falling prices too --
    ///      WETH does not only go up.
    function _interpolate(uint256 _pFrom, uint256 _pTo, uint256 _offset, uint256 _window)
        internal
        pure
        returns (uint256)
    {
        if (_window == 0 || _offset == 0) return _pFrom;
        if (_offset >= _window) return _pTo;
        if (_pTo >= _pFrom) {
            return _pFrom + ((_pTo - _pFrom) * _offset) / _window;
        }
        return _pFrom - ((_pFrom - _pTo) * _offset) / _window;
    }

    /// @dev Binary search for the last epoch with startTime <= _ts. Linear scan here
    ///      would be O(history) on every settle, forever.
    function _epochIndexAt(RateEpoch[] storage _eps, uint256 _ts) internal view returns (uint256) {
        uint256 lo;
        uint256 hi = _eps.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_eps[mid].startTime <= _ts) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo == 0 ? 0 : lo - 1;
    }

    /// @dev Append a prospective rate epoch. Never mutates history. Public entry
    ///      point lives in UserRewardVault.setRewardRate().
    ///
    ///      Same-block changes OVERWRITE the head instead of appending: two epochs
    ///      with an identical startTime describe a zero-length stretch of time that
    ///      can never be accrued, and would just pad the walk toward its cap.
    function _setRewardRate(address _vault, uint256 _newRate) internal {
        require(_newRate <= MAX_RATE, "RATE_GT_MAX");

        RateEpoch[] storage eps = _rateEpochs[_vault];
        require(eps.length != 0, "NOT_REGISTERED");

        uint256 old = eps[eps.length - 1].rateBps;

        if (eps[eps.length - 1].startTime == block.timestamp) {
            eps[eps.length - 1].rateBps = _newRate;
        } else {
            eps.push(RateEpoch({startTime: block.timestamp, rateBps: _newRate}));
        }

        emit RewardRateUpdated(_vault, old, _newRate, eps.length - 1);
    }

    /// @dev Open a vault's rate history at registration.
    function _initRate(address _vault, uint256 _rate) internal {
        require(_rate <= MAX_RATE, "RATE_GT_MAX");
        require(_rateEpochs[_vault].length == 0, "RATE_ALREADY_INIT");
        _rateEpochs[_vault].push(RateEpoch({startTime: block.timestamp, rateBps: _rate}));
    }
}
