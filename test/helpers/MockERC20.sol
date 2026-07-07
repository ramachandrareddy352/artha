// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/*//////////////////////////////////////////////////////////////////////////
                           MockERC20  (test helper)
//////////////////////////////////////////////////////////////////////////*/
/**
 * @title  MockERC20
 * @notice Open-mint ERC20 for tests. Used as the "stray token someone sent
 *         to the vault by mistake" in the rescue() tests, with configurable
 *         decimals (e.g. 6 to imitate USDC).
 */
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Anyone can mint in tests.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
