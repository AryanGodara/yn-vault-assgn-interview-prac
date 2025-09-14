// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title VaultMath
 * @notice Enhanced share/asset conversion library with inflation attack protection
 * @dev Based on YieldBox rebase math with improvements for ERC4626 vaults
 *
 * Key Features:
 * 1. Virtual shares/assets to prevent ratio manipulation
 * 2. Explicit rounding control for precise calculations
 * 3. Enhanced first depositor protection
 * 4. Gas-optimized calculations
 */
library VaultMath {
    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Virtual offset for shares to prevent inflation attacks
    /// @dev 1e8 provides excellent precision while being gas efficient
    uint256 internal constant VIRTUAL_SHARES_OFFSET = 1e8;

    /// @notice Virtual offset for assets to prevent zero division
    uint256 internal constant VIRTUAL_ASSETS_OFFSET = 1;

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error VaultMath__InvalidInput();
    error VaultMath__Overflow();

    /*//////////////////////////////////////////////////////////////
                        CONVERSION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Converts assets to shares with inflation attack protection
     * @param assets Amount of assets to convert
     * @param totalShares Current total shares in circulation
     * @param totalAssets Current total assets under management
     * @param roundUp Whether to round up the result (favors user)
     * @return shares Amount of shares calculated
     * @dev Uses virtual offsets to prevent ratio manipulation attacks
     */
    function convertToShares(uint256 assets, uint256 totalShares, uint256 totalAssets, bool roundUp)
        internal
        pure
        returns (uint256 shares)
    {
        if (assets == 0) return 0;

        // Apply virtual offsets for inflation attack protection
        uint256 virtualAssets = totalAssets + VIRTUAL_ASSETS_OFFSET;
        uint256 virtualShares = totalShares + VIRTUAL_SHARES_OFFSET;

        // Calculate shares: shares = (assets * virtualShares) / virtualAssets
        shares = (assets * virtualShares) / virtualAssets;

        // Round up if requested and rounding occurred
        if (roundUp && (shares * virtualAssets) / virtualShares < assets) {
            shares++;
        }
    }

    /**
     * @notice Converts shares to assets with inflation attack protection
     * @param shares Amount of shares to convert
     * @param totalShares Current total shares in circulation
     * @param totalAssets Current total assets under management
     * @param roundUp Whether to round up the result (favors user)
     * @return assets Amount of assets calculated
     * @dev Uses virtual offsets to prevent ratio manipulation attacks
     */
    function convertToAssets(uint256 shares, uint256 totalShares, uint256 totalAssets, bool roundUp)
        internal
        pure
        returns (uint256 assets)
    {
        if (shares == 0) return 0;

        // Apply virtual offsets for inflation attack protection
        uint256 virtualAssets = totalAssets + VIRTUAL_ASSETS_OFFSET;
        uint256 virtualShares = totalShares + VIRTUAL_SHARES_OFFSET;

        // Calculate assets: assets = (shares * virtualAssets) / virtualShares
        assets = (shares * virtualAssets) / virtualShares;

        // Round up if requested and rounding occurred
        if (roundUp && (assets * virtualShares) / virtualAssets < shares) {
            assets++;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        SPECIALIZED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates shares for deposit (rounds down to favor protocol)
     * @param assets Amount of assets being deposited
     * @param totalShares Current total shares
     * @param totalAssets Current total assets
     * @return shares Amount of shares to mint
     */
    function calculateDepositShares(uint256 assets, uint256 totalShares, uint256 totalAssets)
        internal
        pure
        returns (uint256 shares)
    {
        return convertToShares(assets, totalShares, totalAssets, false);
    }

    /**
     * @notice Calculates assets for withdrawal (rounds up to favor user)
     * @param shares Amount of shares being redeemed
     * @param totalShares Current total shares
     * @param totalAssets Current total assets
     * @return assets Amount of assets to withdraw
     */
    function calculateWithdrawAssets(uint256 shares, uint256 totalShares, uint256 totalAssets)
        internal
        pure
        returns (uint256 assets)
    {
        return convertToAssets(shares, totalShares, totalAssets, true);
    }

    /**
     * @notice Calculates shares for fee collection (rounds down to favor protocol)
     * @param feeAssets Amount of fee assets
     * @param totalShares Current total shares
     * @param totalAssets Current total assets
     * @return feeShares Amount of fee shares to mint
     */
    function calculateFeeShares(uint256 feeAssets, uint256 totalShares, uint256 totalAssets)
        internal
        pure
        returns (uint256 feeShares)
    {
        return convertToShares(feeAssets, totalShares, totalAssets, false);
    }

    /*//////////////////////////////////////////////////////////////
                        UTILITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if the vault is in bootstrap phase (very low liquidity)
     * @param totalShares Current total shares
     * @return isBootstrap True if in bootstrap phase
     */
    function isBootstrapPhase(uint256 totalShares, uint256 /* totalAssets */ )
        internal
        pure
        returns (bool isBootstrap)
    {
        // Bootstrap if total shares is less than virtual offset
        // This indicates very early stage of the vault
        return totalShares < VIRTUAL_SHARES_OFFSET;
    }

    /**
     * @notice Calculates the current share price with high precision
     * @param totalShares Current total shares
     * @param totalAssets Current total assets
     * @return price Share price in assets per share (scaled by 1e18)
     */
    function getSharePrice(uint256 totalShares, uint256 totalAssets) internal pure returns (uint256 price) {
        if (totalShares == 0) return 1e18; // 1:1 ratio initially

        uint256 virtualAssets = totalAssets + VIRTUAL_ASSETS_OFFSET;
        uint256 virtualShares = totalShares + VIRTUAL_SHARES_OFFSET;

        // Price = assets per share, scaled by 1e18 for precision
        price = (virtualAssets * 1e18) / virtualShares;
    }

    /**
     * @notice Estimates the cost of an inflation attack
     * @param targetRatio The ratio the attacker wants to achieve (scaled by 1e18)
     * @param totalShares Current total shares
     * @param totalAssets Current total assets
     * @return attackCost Minimum assets needed for the attack
     */
    function estimateInflationAttackCost(uint256 targetRatio, uint256 totalShares, uint256 totalAssets)
        internal
        pure
        returns (uint256 attackCost)
    {
        uint256 virtualShares = totalShares + VIRTUAL_SHARES_OFFSET;
        uint256 virtualAssets = totalAssets + VIRTUAL_ASSETS_OFFSET;

        // Calculate required assets to achieve target ratio
        uint256 requiredAssets = (targetRatio * virtualShares) / 1e18;

        if (requiredAssets > virtualAssets) {
            attackCost = requiredAssets - virtualAssets;
        } else {
            attackCost = 0; // Attack not possible or not needed
        }
    }
}
