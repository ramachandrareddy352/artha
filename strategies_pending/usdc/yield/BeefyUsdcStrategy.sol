// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BeefyStrategy} from "../../common/BeefyStrategy.sol";

/**
 * @title  BeefyUsdcStrategy  —  hold a Beefy auto-compounding USDC vault
 * @notice Beefy vaults harvest and compound their underlying farm internally, so from
 *         our side this is a Shape-2 holding: deposit USDC into a Beefy mooVault whose
 *         want() == USDC, value via getPricePerFullShare, no harvest. Deploy per token
 *         pointed at the matching Beefy vault.
 */
contract BeefyUsdcStrategy is BeefyStrategy {
    constructor(address _vault, address _usdc, address _oracle, address _swapper, address _beefyVault)
        BeefyStrategy(_vault, _usdc, _oracle, _swapper, _beefyVault)
    {}
}
