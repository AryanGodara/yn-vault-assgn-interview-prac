// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IProvider} from "yieldnest-vault/interface/IProvider.sol";

/**
 * @title LoopingVaultProvider
 * @notice Simple rate provider for the YieldNest Looping Vault
 * @dev Returns 1:1 rates for WETH and cbETH since we handle conversions internally
 */
contract LoopingVaultProvider is IProvider {
    uint256 public constant RATE_PRECISION = 1e18;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant cbETH = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704;

    error UnsupportedAsset(address asset);

    /**
     * @notice Get the rate for converting an asset to base units
     * @param asset The asset address
     * @return rate The conversion rate (18 decimals)
     */
    function getRate(address asset) external pure override returns (uint256 rate) {
        if (asset == WETH || asset == cbETH) {
            // Return 1:1 rate since both assets have 18 decimals
            // The actual cbETH/WETH conversion is handled in the vault's swap logic
            return RATE_PRECISION;
        }

        revert UnsupportedAsset(asset);
    }
}
