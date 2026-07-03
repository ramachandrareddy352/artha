// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/*//////////////////////////////////////////////////////////////////////////
                          ArthaToken  (ARTHA)
//////////////////////////////////////////////////////////////////////////*/
/**
 * @title  ArthaToken
 * @notice ERC-20 + ERC20Votes governance/reward token for the Artha protocol.
 *
 *  WHY ERC20Votes IS MANDATORY FOR GOVERNANCE
 *  ------------------------------------------
 *  The Governor never reads live `balanceOf`. It reads *historical
 *  checkpoints* at the proposal's snapshot timepoint:
 *
 *      votingPower(voter) = getPastVotes(voter, proposalSnapshot)
 *
 *  A plain ERC-20 has no checkpoints, so a plain ERC-20 CANNOT be used as a
 *  governance token. ERC20Votes writes a checkpoint on every transfer /
 *  mint / burn / delegate, which makes "buy tokens after the snapshot and
 *  vote" and "vote, transfer, vote again from another wallet" impossible.
 *
 *  DELEGATION (the #1 gotcha)
 *  --------------------------
 *  Voting power is ZERO until a holder calls `delegate()`. Holding 10M
 *  ARTHA gives 0 votes until you `delegate(yourself)` (self-delegate) or
 *  delegate to someone else. This is by design: checkpoint bookkeeping is
 *  only paid for by addresses that opt into governance.
 *
 *  CLOCK MODE = TIMESTAMP (ERC-6372)
 *  ---------------------------------
 *  Default OZ clock is `block.number`. On an L2 that is a footgun:
 *  block times differ per chain (Arbitrum ~0.25s, OP/Base 2s) and can
 *  change, silently changing your voting-period length. We override the
 *  clock to `block.timestamp`, so ALL governor timings (votingDelay,
 *  votingPeriod) are configured in SECONDS. The Governor auto-detects this
 *  through `CLOCK_MODE()` — token and governor must agree, and they do
 *  because GovernorVotes reads the mode from this token.
 *
 *  MINTING MODEL
 *  -------------
 *  Artha's 16-year emission schedule lives in the emissions controller
 *  (Diamond facet) and in the ReferralVault funding flow — the token itself
 *  only enforces WHO may mint (MINTER_ROLE) and HOW MUCH in total (CAP).
 *
 *      grant MINTER_ROLE -> emissions controller / diamond
 *      DEFAULT_ADMIN_ROLE -> ArthaTimelock (after deployment!)
 *
 *  so that adding/removing minters is itself a governance action.
 */
contract ArthaToken is ERC20, ERC20Permit, ERC20Votes, AccessControl {
    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Role allowed to mint new ARTHA (emissions controller).
    ///         keccak256("MINTER_ROLE")
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /*//////////////////////////////////////////////////////////////
                               SUPPLY CAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Hard cap on total supply. Immutable — cannot be raised even
    ///         by governance. Example: 1_000_000_000e18 (1B ARTHA).
    uint256 public immutable CAP;

    error CapExceeded(uint256 requested, uint256 remaining);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param cap_          Max total supply, 18-decimals (e.g. 1_000_000_000e18).
     * @param initialAdmin  Address that holds DEFAULT_ADMIN_ROLE at launch.
     *                      Use the DEPLOYER here, then — once the timelock is
     *                      live — run:
     *                        grantRole(DEFAULT_ADMIN_ROLE, timelock)
     *                        renounceRole(DEFAULT_ADMIN_ROLE, deployer)
     *                      so only governance can manage minters afterwards.
     */
    constructor(uint256 cap_, address initialAdmin)
        ERC20("Artha", "ARTHA")
        ERC20Permit("Artha") // EIP-2612 domain separator name
    {
        CAP = cap_;
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                                 MINT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mint `amount` ARTHA to `to`. Only MINTER_ROLE.
     *
     *  Cap check example:
     *    CAP           = 1_000_000_000e18
     *    totalSupply() =   999_900_000e18
     *    amount        =       200_000e18
     *    999_900_000e18 + 200_000e18 = 1_000_100_000e18 > CAP  -> revert
     *    remaining reported = 1_000_000_000e18 - 999_900_000e18 = 100_000e18
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        uint256 supply = totalSupply();
        if (supply + amount > CAP) {
            revert CapExceeded(amount, CAP - supply);
        }
        _mint(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                      ERC-6372 CLOCK  (timestamp mode)
    //////////////////////////////////////////////////////////////*/

    /// @dev Checkpoints are keyed by timestamp instead of block number.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @dev Machine-readable clock description; the Governor reads this.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /*//////////////////////////////////////////////////////////////
              OVERRIDES REQUIRED BY SOLIDITY (diamond inheritance)
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC20Votes hooks _update to write a checkpoint on every
    ///      balance change (transfer / mint / burn).
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    /// @dev Both ERC20Permit and Votes (via Nonces) track nonces.
    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
