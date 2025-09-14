// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStrategy
 * @notice Interface for yield-generating strategies that integrate with the vault
 * @dev All strategies must implement this interface to be compatible with the vault
 */
interface IStrategy {
    /**
     * @notice Deposits all available assets from vault into the strategy
     * @dev Only callable by the vault contract
     */
    function deposit() external;

    /**
     * @notice Withdraws specified amount of assets to the vault
     * @param amount The amount of assets to withdraw
     * @return withdrawn The actual amount withdrawn (may be less due to slippage)
     * @dev Should handle cases where requested amount exceeds available balance
     */
    function withdraw(uint256 amount) external returns (uint256 withdrawn);

    /**
     * @notice Returns total value of assets managed by the strategy
     * @return Total assets under management in base asset units
     * @dev This should reflect the real-time value including any accrued yield
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Harvests yield and reports performance to vault
     * @return totalAssets_ Current total assets after harvest
     * @return profit Amount of profit generated since last report
     * @return loss Amount of loss incurred since last report
     */
    function harvestAndReport() external returns (uint256 totalAssets_, uint256 profit, uint256 loss);

    /**
     * @notice Emergency function to withdraw all funds to vault
     * @dev Should only be called in emergency situations
     */
    function emergencyWithdraw() external;

    /**
     * @notice Returns the address of the vault this strategy serves
     */
    function vault() external view returns (address);

    /**
     * @notice Returns the address of the asset this strategy manages
     */
    function asset() external view returns (address);
}
