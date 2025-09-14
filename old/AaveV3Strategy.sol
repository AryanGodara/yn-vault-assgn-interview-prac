// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAToken} from "@aave/core-v3/contracts/interfaces/IAToken.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";

/**
 * @title AaveV3Strategy
 * @notice Strategy that deposits assets into Aave V3 for yield generation
 * @dev This strategy is designed to be simple and gas-efficient
 *
 * Key Design Decisions:
 * 1. Direct integration with Aave V3 (no SDK needed)
 * 2. Simple deposit/withdraw pattern (no complex rebalancing)
 * 3. Accurate yield tracking through aToken balance
 * 4. Emergency withdrawal capability
 */
contract AaveV3Strategy is IStrategy, Ownable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Aave V3 Pool address - will be set based on chain
    IPool public immutable AAVE_POOL;

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    // Core addresses set at deployment
    address public immutable VAULT;
    address public immutable ASSET;
    address public immutable A_TOKEN;

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    // Performance tracking
    uint256 public lastReportedBalance; // Balance at last harvest
    uint256 public totalDeposited; // Total ever deposited
    uint256 public totalWithdrawn; // Total ever withdrawn

    // Safety limits
    uint256 public maxSingleWithdraw = type(uint256).max;

    // Emergency pause state
    bool public emergencyPaused;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount, uint256 actualWithdrawn);
    event HarvestReport(uint256 totalAssets, uint256 profit, uint256 loss);
    event EmergencyWithdrawal(uint256 amount);
    event EmergencyPauseToggled(bool paused);
    event MaxWithdrawUpdated(uint256 newMax);

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error Strategy__NotVault();
    error Strategy__InvalidAsset();
    error Strategy__WithdrawFailed();
    error Strategy__EmergencyPaused();
    error Strategy__ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensures only the vault can call certain functions
     * @dev This is critical for security - only vault manages user funds
     */
    modifier onlyVault() {
        if (msg.sender != VAULT) revert Strategy__NotVault();
        _;
    }

    /**
     * @notice Prevents operations when emergency paused
     */
    modifier whenNotEmergencyPaused() {
        if (emergencyPaused) revert Strategy__EmergencyPaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the strategy with vault and asset addresses
     * @param _vault Address of the vault that will use this strategy
     * @param _asset Address of the asset to manage (USDC)
     * @dev Gets the aToken address from Aave and sets up approvals
     */
    constructor(address _vault, address _asset) Ownable(msg.sender) {
        if (_asset == address(0)) {
            revert Strategy__ZeroAddress();
        }
        // Allow _vault to be zero initially for deployment purposes

        VAULT = _vault;
        ASSET = _asset;

        // Set Aave pool address based on chain ID
        uint256 chainId = block.chainid;
        if (chainId == 1) {
            // Ethereum Mainnet
            AAVE_POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
        } else if (chainId == 84532) {
            // Base Sepolia
            AAVE_POOL = IPool(0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27);
        } else if (chainId == 8453) {
            // Base Mainnet
            AAVE_POOL = IPool(0xA238Dd80C259a72e81d7e4664a9801593F98d1c5);
        } else {
            revert Strategy__InvalidAsset(); // Unsupported chain
        }

        // Get the reserve data from Aave to find the aToken address
        // This is more reliable than hardcoding the aToken address
        DataTypes.ReserveData memory reserveData = AAVE_POOL.getReserveData(
            _asset
        );
        address aTokenAddress = reserveData.aTokenAddress;

        if (aTokenAddress == address(0)) revert Strategy__InvalidAsset();
        A_TOKEN = aTokenAddress;

        // Approve Aave pool to spend our assets
        // Using max approval to save gas on future deposits
        IERC20(_asset).forceApprove(address(AAVE_POOL), type(uint256).max);

        // Transfer ownership to vault for security (only if vault is not zero)
        if (_vault != address(0)) {
            transferOwnership(_vault);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        CORE STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits all available assets into Aave
     * @dev Only callable by vault after user deposits
     *
     * How Aave deposits work:
     * 1. We supply assets to the pool
     * 2. Aave mints aTokens to us 1:1
     * 3. aTokens increase in balance over time as interest accrues
     */
    function deposit() external override onlyVault whenNotEmergencyPaused {
        uint256 balance = IERC20(ASSET).balanceOf(address(this));

        if (balance > 0) {
            // Supply assets to Aave
            // Parameters: asset, amount, onBehalfOf, referralCode
            AAVE_POOL.supply(ASSET, balance, address(this), 0);

            totalDeposited += balance;

            emit Deposited(balance);
        }
    }

    /**
     * @notice Withdraws assets from Aave back to vault
     * @param amount Amount of assets to withdraw
     * @return withdrawn Actual amount withdrawn (may differ due to rounding)
     * @dev Handles edge cases where requested amount exceeds available
     *
     * How Aave withdrawals work:
     * 1. We request withdrawal of underlying assets
     * 2. Aave burns equivalent aTokens
     * 3. Assets are sent directly to specified receiver (vault)
     */
    function withdraw(
        uint256 amount
    )
        external
        override
        onlyVault
        whenNotEmergencyPaused
        returns (uint256 withdrawn)
    {
        // Check available balance (aTokens represent our assets 1:1+yield)
        uint256 available = IAToken(A_TOKEN).balanceOf(address(this));

        // Cap withdrawal at available amount
        uint256 toWithdraw = amount > available ? available : amount;

        // Safety check for single withdrawal limit
        toWithdraw = toWithdraw > maxSingleWithdraw
            ? maxSingleWithdraw
            : toWithdraw;

        if (toWithdraw > 0) {
            // Withdraw from Aave directly to vault
            // This saves gas vs withdrawing here then transferring
            withdrawn = AAVE_POOL.withdraw(ASSET, toWithdraw, VAULT);

            if (withdrawn == 0) revert Strategy__WithdrawFailed();

            totalWithdrawn += withdrawn;

            emit Withdrawn(toWithdraw, withdrawn);
        }

        return withdrawn;
    }

    /**
     * @notice Returns total assets managed by this strategy
     * @return Total value in underlying asset terms
     * @dev aToken balance represents principal + accrued interest
     *
     * Understanding aToken accounting:
     * - aTokens are rebasing tokens that increase in balance
     * - The balance automatically reflects accrued interest
     * - No need for complex calculations or oracle calls
     */
    function totalAssets() external view override returns (uint256) {
        // aToken balance directly represents our total assets
        // This includes both principal and accrued yield
        return IAToken(A_TOKEN).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        HARVEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Harvests yield and reports performance to vault
     * @return totalAssets_ Current total assets
     * @return profit Amount gained since last report
     * @return loss Amount lost since last report
     * @dev Called by vault during harvest() to calculate fees
     *
     * Yield calculation methodology:
     * - Compare current aToken balance to last reported
     * - Difference is the yield (profit) or loss
     * - Update last reported for next harvest
     */
    function harvestAndReport()
        external
        override
        returns (uint256 totalAssets_, uint256 profit, uint256 loss)
    {
        // Get current total assets from aToken balance
        totalAssets_ = IAToken(A_TOKEN).balanceOf(address(this));

        // Calculate performance since last report
        if (totalAssets_ > lastReportedBalance) {
            // We made profit from Aave yield
            profit = totalAssets_ - lastReportedBalance;
            loss = 0;
        } else if (totalAssets_ < lastReportedBalance) {
            // We have a loss (shouldn't happen with Aave, but handle it)
            profit = 0;
            loss = lastReportedBalance - totalAssets_;
        } else {
            // No change
            profit = 0;
            loss = 0;
        }

        // Update last reported balance for next harvest
        lastReportedBalance = totalAssets_;

        emit HarvestReport(totalAssets_, profit, loss);

        return (totalAssets_, profit, loss);
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency withdrawal of all funds to vault
     * @dev Can only be called by vault in emergency situations
     *
     * When to use emergency withdrawal:
     * 1. Strategy is being replaced
     * 2. Critical bug discovered
     * 3. Aave protocol issue
     * 4. Vault emergency shutdown
     */
    function emergencyWithdraw() external override onlyVault {
        uint256 balance = IAToken(A_TOKEN).balanceOf(address(this));

        if (balance > 0) {
            // Withdraw everything directly to vault
            uint256 withdrawn = AAVE_POOL.withdraw(ASSET, balance, VAULT);

            totalWithdrawn += withdrawn;
            lastReportedBalance = 0;

            emit EmergencyWithdrawal(withdrawn);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets maximum single withdrawal amount
     * @param _max New maximum in asset units
     * @dev Safety mechanism to prevent large atomic withdrawals
     */
    function setMaxSingleWithdraw(uint256 _max) external onlyOwner {
        maxSingleWithdraw = _max;
        emit MaxWithdrawUpdated(_max);
    }

    /**
     * @notice Toggle emergency pause state
     * @dev Prevents deposits/withdrawals when paused
     */
    function toggleEmergencyPause() external onlyOwner {
        emergencyPaused = !emergencyPaused;
        emit EmergencyPauseToggled(emergencyPaused);
    }

    /**
     * @notice Emergency function to recover stuck tokens
     * @param token Address of token to recover
     * @param amount Amount to recover
     * @dev Only recovers tokens that aren't the main asset or aToken
     */
    function recoverToken(address token, uint256 amount) external onlyOwner {
        if (token == ASSET || token == A_TOKEN) revert Strategy__InvalidAsset();
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Migrates strategy to a new vault
     * @param _newVault Address of the new vault
     * @dev Used for vault upgrades - must withdraw all funds first
     */
    function migrate(address _newVault) external onlyOwner {
        if (_newVault == address(0)) revert Strategy__ZeroAddress();

        // First withdraw all funds to current vault
        uint256 balance = IAToken(A_TOKEN).balanceOf(address(this));
        if (balance > 0) {
            AAVE_POOL.withdraw(ASSET, balance, VAULT);
            totalWithdrawn += balance;
            lastReportedBalance = 0;
        }

        // Transfer ownership to new vault
        transferOwnership(_newVault);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the vault address
     * @return Address of the vault
     */
    function vault() external view override returns (address) {
        return VAULT;
    }

    /**
     * @notice Returns the asset address
     * @return Address of the underlying asset
     */
    function asset() external view override returns (address) {
        return ASSET;
    }

    /**
     * @notice Returns the current APY from Aave
     * @return Current supply APY in ray units (1e27)
     * @dev Useful for frontend display and monitoring
     */
    function getCurrentApy() external view returns (uint256) {
        DataTypes.ReserveData memory reserveData = AAVE_POOL.getReserveData(
            ASSET
        );

        // Rate is in ray (1e27), representing per-second interest
        return reserveData.currentLiquidityRate;
    }

    /**
     * @notice Checks if the asset reserve is paused in Aave
     * @return True if paused, false otherwise
     * @dev Important for monitoring and emergency procedures
     */
    function isAssetPaused() external view returns (bool) {
        DataTypes.ReserveData memory reserveData = AAVE_POOL.getReserveData(
            ASSET
        );
        // Check bit 60 of the configuration data (asset is paused)
        return (reserveData.configuration.data >> 60) & 1 == 1;
    }

    /**
     * @notice Returns utilization metrics for monitoring
     * @return deposited Total ever deposited
     * @return withdrawn Total ever withdrawn
     * @return current Current balance in Aave
     */
    function getMetrics()
        external
        view
        returns (uint256 deposited, uint256 withdrawn, uint256 current)
    {
        return (
            totalDeposited,
            totalWithdrawn,
            IAToken(A_TOKEN).balanceOf(address(this))
        );
    }
}
