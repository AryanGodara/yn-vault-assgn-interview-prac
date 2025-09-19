// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAToken} from "@aave/core-v3/contracts/interfaces/IAToken.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface ICurvePool {
    function exchange(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);
    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256);
}

/**
 * @title AaveV3LoopingStrategy
 * @notice Leveraged looping strategy that supplies WETH to Aave, borrows cbETH, swaps to WETH via Curve
 * @dev This strategy implements a leveraged loop to amplify WETH yields
 *
 * Key Design Decisions:
 * 1. WETH supply to Aave V3 as collateral
 * 2. cbETH borrowing against WETH collateral
 * 3. Curve cbETH/WETH swapping for loop closure
 * 4. Multiple loop iterations for leverage amplification
 * 5. Health factor monitoring for safety
 * 6. Position unwinding for withdrawals
 */
contract AaveV3LoopingStrategy is IStrategy, Ownable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Protocol addresses (Ethereum Mainnet)
    IPool public constant AAVE_POOL =
        IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAaveOracle public constant AAVE_ORACLE =
        IAaveOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);
    ICurvePool public constant CURVE_CBETH_ETH_POOL =
        ICurvePool(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A);

    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant cbETH =
        IERC20(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704);

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    // Core addresses set at deployment
    address public immutable VAULT;
    address public immutable ASSET; // WETH
    address public immutable A_WETH; // aWETH token
    address public immutable DEBT_CBETH; // Variable debt cbETH token

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    // Strategy parameters
    uint256 public targetLTV = 7000; // 70% LTV target (basis points)
    uint256 public constant MAX_LTV = 7500; // 75% safety threshold
    uint256 public loopCount = 3; // Number of leverage loops
    uint256 public slippageTolerance = 1000; // 10% slippage tolerance (basis points)

    // Position tracking
    uint256 public totalCollateral; // Total WETH supplied to Aave
    uint256 public totalDebt; // Total cbETH borrowed from Aave
    uint256 public lastReportedBalance; // Balance at last harvest

    // Safety limits
    uint256 public maxSingleWithdraw = type(uint256).max;
    bool public emergencyPaused;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event LeverageExecuted(
        uint256 initialAmount,
        uint256 finalCollateral,
        uint256 finalDebt,
        uint256 healthFactor
    );
    event PositionUnwound(
        uint256 collateralWithdrawn,
        uint256 debtRepaid,
        uint256 healthFactor
    );
    event StrategyParametersUpdated(
        uint256 targetLTV,
        uint256 loopCount,
        uint256 slippageTolerance
    );
    event HarvestReport(uint256 totalAssets, uint256 profit, uint256 loss);
    event EmergencyWithdrawal(uint256 amount);
    event EmergencyPauseToggled(bool paused);

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error Strategy__NotVault();
    error Strategy__InvalidAsset();
    error Strategy__WithdrawFailed();
    error Strategy__EmergencyPaused();
    error Strategy__ZeroAddress();
    error Strategy__HealthFactorTooLow(uint256 healthFactor);
    error Strategy__InvalidLeverageParameters();
    error Strategy__SwapFailed();
    error Strategy__InsufficientLiquidity();

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
     * @notice Initializes the looping strategy with vault and asset addresses
     * @param _vault Address of the vault that will use this strategy
     * @param _asset Address of the asset to manage (WETH)
     * @dev Gets the aToken and debt token addresses from Aave and sets up approvals
     */
    constructor(address _vault, address _asset) Ownable(msg.sender) {
        if (_asset != address(WETH)) {
            revert Strategy__InvalidAsset();
        }

        VAULT = _vault;
        ASSET = _asset;

        // Get WETH reserve data from Aave
        DataTypes.ReserveData memory wethReserveData = AAVE_POOL.getReserveData(
            address(WETH)
        );
        if (wethReserveData.aTokenAddress == address(0))
            revert Strategy__InvalidAsset();
        A_WETH = wethReserveData.aTokenAddress;

        // Get cbETH reserve data from Aave
        DataTypes.ReserveData memory cbethReserveData = AAVE_POOL
            .getReserveData(address(cbETH));
        if (cbethReserveData.variableDebtTokenAddress == address(0))
            revert Strategy__InvalidAsset();
        DEBT_CBETH = cbethReserveData.variableDebtTokenAddress;

        // Approve Aave pool to spend our tokens
        IERC20(WETH).forceApprove(address(AAVE_POOL), type(uint256).max);
        IERC20(cbETH).forceApprove(address(AAVE_POOL), type(uint256).max);

        // Approve Curve pool to spend cbETH for swapping
        IERC20(cbETH).forceApprove(
            address(CURVE_CBETH_ETH_POOL),
            type(uint256).max
        );

        // Transfer ownership to vault for security (only if vault is not zero)
        if (_vault != address(0)) {
            transferOwnership(_vault);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        CORE STRATEGY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Executes leveraged looping strategy with available WETH
     * @dev Only callable by vault after user deposits
     *
     * Looping Strategy:
     * 1. Supply WETH to Aave as collateral
     * 2. Borrow cbETH against WETH collateral
     * 3. Swap cbETH to WETH via Curve
     * 4. Repeat for specified loop count
     */
    function deposit() external override onlyVault whenNotEmergencyPaused {
        uint256 wethBalance = IERC20(WETH).balanceOf(address(this));

        if (wethBalance > 0) {
            _executeLeverageLoop(wethBalance);
        }
    }

    /**
     * @notice Executes the leveraged looping strategy
     * @param initialAmount Initial WETH amount to start the loop
     */
    function _executeLeverageLoop(uint256 initialAmount) internal {
        uint256 currentWethAmount = initialAmount;

        // Execute multiple loops for leverage amplification
        for (uint256 i = 0; i < loopCount; i++) {
            if (currentWethAmount == 0) break;

            // 1. Supply WETH to Aave
            AAVE_POOL.supply(
                address(WETH),
                currentWethAmount,
                address(this),
                0
            );
            totalCollateral += currentWethAmount;

            // 2. Calculate how much cbETH we can borrow
            uint256 borrowAmount = _calculateBorrowAmount(currentWethAmount);
            if (borrowAmount == 0) break;

            // 3. Borrow cbETH from Aave
            AAVE_POOL.borrow(address(cbETH), borrowAmount, 2, 0, address(this)); // 2 = variable rate
            totalDebt += borrowAmount;

            // 4. Swap cbETH to WETH via Curve
            currentWethAmount = _swapCbEthToWeth(borrowAmount);

            // Safety check: ensure we got some WETH back
            if (currentWethAmount == 0) break;
        }

        // Supply any remaining WETH
        if (currentWethAmount > 0) {
            AAVE_POOL.supply(
                address(WETH),
                currentWethAmount,
                address(this),
                0
            );
            totalCollateral += currentWethAmount;
        }

        // Check health factor after looping
        uint256 healthFactor = _getHealthFactor();
        if (healthFactor < 1.05e18) {
            // Minimum 1.05 health factor
            revert Strategy__HealthFactorTooLow(healthFactor);
        }

        emit LeverageExecuted(
            initialAmount,
            totalCollateral,
            totalDebt,
            healthFactor
        );
    }

    /**
     * @notice Withdraws assets by unwinding leveraged position
     * @param amount Amount of WETH to withdraw
     * @return withdrawn Actual amount withdrawn
     * @dev Unwinds position proportionally to maintain health factor
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
        if (amount == 0) return 0;

        // Cap withdrawal at available amount
        uint256 totalAssets_ = totalAssets();
        uint256 toWithdraw = amount > totalAssets_ ? totalAssets_ : amount;

        // Safety check for single withdrawal limit
        toWithdraw = toWithdraw > maxSingleWithdraw
            ? maxSingleWithdraw
            : toWithdraw;

        if (toWithdraw > 0) {
            withdrawn = _unwindPosition(toWithdraw);

            // Transfer withdrawn WETH to vault
            if (withdrawn > 0) {
                IERC20(WETH).safeTransfer(VAULT, withdrawn);
            }
        }

        return withdrawn;
    }

    /**
     * @notice Unwinds leveraged position to withdraw specified amount
     * @param targetWithdraw Target amount to withdraw
     * @return actualWithdrawn Actual amount withdrawn
     */
    function _unwindPosition(
        uint256 targetWithdraw
    ) internal returns (uint256 actualWithdrawn) {
        uint256 currentCollateral = IAToken(A_WETH).balanceOf(address(this));
        uint256 currentDebt = IERC20(DEBT_CBETH).balanceOf(address(this));

        if (currentCollateral == 0) return 0;

        // Calculate proportion to unwind
        uint256 withdrawRatio = (targetWithdraw * 1e18) / currentCollateral;
        if (withdrawRatio > 1e18) withdrawRatio = 1e18;

        uint256 debtToRepay = (currentDebt * withdrawRatio) / 1e18;
        uint256 collateralToWithdraw = (currentCollateral * withdrawRatio) /
            1e18;

        // Unwind position iteratively
        while (debtToRepay > 0 && collateralToWithdraw > 0) {
            // Calculate how much collateral we can withdraw while maintaining health factor
            uint256 maxWithdrawable = _calculateMaxWithdrawable();
            uint256 toWithdrawNow = collateralToWithdraw > maxWithdrawable
                ? maxWithdrawable
                : collateralToWithdraw;

            if (toWithdrawNow == 0) break;

            // Withdraw WETH collateral
            uint256 withdrawnWeth = AAVE_POOL.withdraw(
                address(WETH),
                toWithdrawNow,
                address(this)
            );

            // Calculate how much cbETH we can buy with withdrawn WETH
            uint256 cbEthToBuy = _calculateCbEthFromWeth(withdrawnWeth);
            uint256 debtToRepayNow = debtToRepay > cbEthToBuy
                ? cbEthToBuy
                : debtToRepay;

            if (debtToRepayNow > 0) {
                // Swap WETH to cbETH via Curve
                uint256 wethForSwap = _calculateWethForCbEth(debtToRepayNow);
                if (wethForSwap <= withdrawnWeth) {
                    uint256 cbEthReceived = _swapWethToCbEth(wethForSwap);

                    // Repay cbETH debt
                    if (cbEthReceived > 0) {
                        uint256 repayAmount = cbEthReceived > debtToRepayNow
                            ? debtToRepayNow
                            : cbEthReceived;
                        AAVE_POOL.repay(
                            address(cbETH),
                            repayAmount,
                            2,
                            address(this)
                        );
                        totalDebt -= repayAmount;
                        debtToRepay -= repayAmount;
                    }

                    actualWithdrawn += withdrawnWeth - wethForSwap;
                } else {
                    actualWithdrawn += withdrawnWeth;
                }
            } else {
                actualWithdrawn += withdrawnWeth;
            }

            totalCollateral -= toWithdrawNow;
            collateralToWithdraw -= toWithdrawNow;

            // Safety check
            if (_getHealthFactor() < 1.05e18) break;
        }

        uint256 healthFactor = _getHealthFactor();
        emit PositionUnwound(
            actualWithdrawn,
            currentDebt - IERC20(DEBT_CBETH).balanceOf(address(this)),
            healthFactor
        );
    }

    /**
     * @notice Returns total assets managed by this strategy
     * @return Total value in WETH terms (collateral - debt)
     * @dev Calculates net position value considering leverage
     */
    function totalAssets() external view override returns (uint256) {
        uint256 collateralValue = IAToken(A_WETH).balanceOf(address(this));
        uint256 debtValue = _convertCbEthToWeth(
            IERC20(DEBT_CBETH).balanceOf(address(this))
        );

        // Add any idle WETH balance
        uint256 idleWeth = IERC20(WETH).balanceOf(address(this));

        // Net position = collateral - debt + idle
        if (collateralValue + idleWeth > debtValue) {
            return collateralValue + idleWeth - debtValue;
        } else {
            return 0; // Prevent underflow in case of bad debt
        }
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
     */
    function harvestAndReport()
        external
        override
        returns (uint256 totalAssets_, uint256 profit, uint256 loss)
    {
        // Get current total assets (net position value)
        totalAssets_ = this.totalAssets();

        // Calculate performance since last report
        if (totalAssets_ > lastReportedBalance) {
            profit = totalAssets_ - lastReportedBalance;
            loss = 0;
        } else if (totalAssets_ < lastReportedBalance) {
            profit = 0;
            loss = lastReportedBalance - totalAssets_;
        } else {
            profit = 0;
            loss = 0;
        }

        // Update last reported balance for next harvest
        lastReportedBalance = totalAssets_;

        emit HarvestReport(totalAssets_, profit, loss);
        return (totalAssets_, profit, loss);
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates how much cbETH can be borrowed against WETH collateral
     * @param wethAmount Amount of WETH being supplied
     * @return borrowAmount Amount of cbETH that can be borrowed
     */
    function _calculateBorrowAmount(
        uint256 wethAmount
    ) internal view returns (uint256 borrowAmount) {
        // Get WETH price from Aave oracle
        uint256 wethPrice = AAVE_ORACLE.getAssetPrice(address(WETH));
        uint256 cbethPrice = AAVE_ORACLE.getAssetPrice(address(cbETH));

        if (wethPrice == 0 || cbethPrice == 0) return 0;

        // Calculate USD value of WETH collateral
        uint256 collateralValueUSD = (wethAmount * wethPrice) / 1e18;

        // Calculate maximum borrow value in USD (target LTV)
        uint256 maxBorrowValueUSD = (collateralValueUSD * targetLTV) / 10000;

        // Convert to cbETH amount
        borrowAmount = (maxBorrowValueUSD * 1e18) / cbethPrice;
    }

    /**
     * @notice Swaps cbETH to WETH via Curve
     * @param cbethAmount Amount of cbETH to swap
     * @return wethReceived Amount of WETH received
     */
    function _swapCbEthToWeth(
        uint256 cbethAmount
    ) internal returns (uint256 wethReceived) {
        if (cbethAmount == 0) return 0;

        // Get expected output with slippage protection
        uint256 expectedWeth = CURVE_CBETH_ETH_POOL.get_dy(1, 0, cbethAmount); // cbETH to ETH
        uint256 minWeth = (expectedWeth * (10000 - slippageTolerance)) / 10000;

        // Execute swap: cbETH (index 1) to ETH (index 0)
        try CURVE_CBETH_ETH_POOL.exchange(1, 0, cbethAmount, minWeth) returns (
            uint256 received
        ) {
            wethReceived = received;
        } catch {
            revert Strategy__SwapFailed();
        }
    }

    /**
     * @notice Swaps WETH to cbETH via Curve
     * @param wethAmount Amount of WETH to swap
     * @return cbethReceived Amount of cbETH received
     */
    function _swapWethToCbEth(
        uint256 wethAmount
    ) internal returns (uint256 cbethReceived) {
        if (wethAmount == 0) return 0;

        // Get expected output with slippage protection
        uint256 expectedCbeth = CURVE_CBETH_ETH_POOL.get_dy(0, 1, wethAmount); // ETH to cbETH
        uint256 minCbeth = (expectedCbeth * (10000 - slippageTolerance)) /
            10000;

        // Execute swap: ETH (index 0) to cbETH (index 1)
        try CURVE_CBETH_ETH_POOL.exchange(0, 1, wethAmount, minCbeth) returns (
            uint256 received
        ) {
            cbethReceived = received;
        } catch {
            revert Strategy__SwapFailed();
        }
    }

    /**
     * @notice Gets current health factor from Aave
     * @return healthFactor Current health factor (1e18 = 100%)
     */
    function _getHealthFactor() internal view returns (uint256 healthFactor) {
        (, , , , , uint256 hf) = AAVE_POOL.getUserAccountData(address(this));
        return hf;
    }

    /**
     * @notice Calculates maximum withdrawable collateral while maintaining health factor
     * @return maxWithdrawable Maximum WETH that can be withdrawn
     */
    function _calculateMaxWithdrawable()
        internal
        view
        returns (uint256 maxWithdrawable)
    {
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            ,
            uint256 currentLiquidationThreshold,
            ,

        ) = AAVE_POOL.getUserAccountData(address(this));

        if (totalDebtETH == 0) {
            return IAToken(A_WETH).balanceOf(address(this));
        }

        // Calculate minimum collateral needed to maintain health factor > 1.05
        uint256 minCollateralETH = (totalDebtETH * 10500) /
            currentLiquidationThreshold; // 1.05 safety margin

        if (totalCollateralETH > minCollateralETH) {
            uint256 withdrawableETH = totalCollateralETH - minCollateralETH;
            // Convert ETH value to WETH amount (assuming 1:1 for simplicity)
            maxWithdrawable = withdrawableETH;
        }
    }

    /**
     * @notice Converts cbETH amount to equivalent WETH using oracle prices
     * @param cbethAmount Amount of cbETH
     * @return wethAmount Equivalent WETH amount
     */
    function _convertCbEthToWeth(
        uint256 cbethAmount
    ) internal view returns (uint256 wethAmount) {
        if (cbethAmount == 0) return 0;

        uint256 wethPrice = AAVE_ORACLE.getAssetPrice(address(WETH));
        uint256 cbethPrice = AAVE_ORACLE.getAssetPrice(address(cbETH));

        if (wethPrice == 0) return 0;

        wethAmount = (cbethAmount * cbethPrice) / wethPrice;
    }

    /**
     * @notice Calculates how much cbETH can be bought with given WETH
     * @param wethAmount Amount of WETH
     * @return cbethAmount Equivalent cbETH amount
     */
    function _calculateCbEthFromWeth(
        uint256 wethAmount
    ) internal view returns (uint256 cbethAmount) {
        return CURVE_CBETH_ETH_POOL.get_dy(0, 1, wethAmount);
    }

    /**
     * @notice Calculates how much WETH needed to buy given cbETH
     * @param cbethAmount Amount of cbETH needed
     * @return wethAmount WETH amount needed
     */
    function _calculateWethForCbEth(
        uint256 cbethAmount
    ) internal view returns (uint256 wethAmount) {
        // This is an approximation - in practice you'd need to reverse the curve calculation
        uint256 wethPrice = AAVE_ORACLE.getAssetPrice(address(WETH));
        uint256 cbethPrice = AAVE_ORACLE.getAssetPrice(address(cbETH));

        if (wethPrice == 0) return 0;

        wethAmount = (cbethAmount * cbethPrice) / wethPrice;
        // Add small buffer for slippage
        wethAmount = (wethAmount * 10100) / 10000; // 1% buffer
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency withdrawal of all funds to vault
     * @dev Can only be called by vault in emergency situations
     * Unwinds entire position regardless of health factor
     */
    function emergencyWithdraw() external override onlyVault {
        uint256 currentDebt = IERC20(DEBT_CBETH).balanceOf(address(this));
        uint256 currentCollateral = IAToken(A_WETH).balanceOf(address(this));

        uint256 totalWithdrawn = 0;

        // If we have debt, try to repay it first
        if (currentDebt > 0) {
            // Withdraw some collateral to repay debt
            uint256 collateralToWithdraw = (currentCollateral * 8000) / 10000; // 80% of collateral
            if (collateralToWithdraw > 0) {
                uint256 withdrawnWeth = AAVE_POOL.withdraw(
                    address(WETH),
                    collateralToWithdraw,
                    address(this)
                );

                // Swap WETH to cbETH to repay debt
                uint256 cbethReceived = _swapWethToCbEth(withdrawnWeth / 2); // Use half for repayment
                if (cbethReceived > 0) {
                    uint256 repayAmount = cbethReceived > currentDebt
                        ? currentDebt
                        : cbethReceived;
                    AAVE_POOL.repay(
                        address(cbETH),
                        repayAmount,
                        2,
                        address(this)
                    );
                    totalDebt -= repayAmount;
                }

                totalWithdrawn += withdrawnWeth / 2; // Other half goes to vault
            }
        }

        // Withdraw remaining collateral
        uint256 remainingCollateral = IAToken(A_WETH).balanceOf(address(this));
        if (remainingCollateral > 0) {
            uint256 withdrawn = AAVE_POOL.withdraw(
                address(WETH),
                remainingCollateral,
                address(this)
            );
            totalWithdrawn += withdrawn;
        }

        // Transfer all WETH to vault
        uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
        if (wethBalance > 0) {
            IERC20(WETH).safeTransfer(VAULT, wethBalance);
            totalWithdrawn = wethBalance; // Update to actual transferred amount
        }

        // Reset tracking variables
        totalCollateral = 0;
        totalDebt = IERC20(DEBT_CBETH).balanceOf(address(this)); // Update to remaining debt
        lastReportedBalance = 0;

        emit EmergencyWithdrawal(totalWithdrawn);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates strategy parameters
     * @param _targetLTV New target LTV in basis points
     * @param _loopCount New loop count
     * @param _slippageTolerance New slippage tolerance in basis points
     */
    function updateStrategyParameters(
        uint256 _targetLTV,
        uint256 _loopCount,
        uint256 _slippageTolerance
    ) external onlyOwner {
        if (_targetLTV > MAX_LTV) revert Strategy__InvalidLeverageParameters();
        if (_loopCount > 10) revert Strategy__InvalidLeverageParameters(); // Max 10 loops
        if (_slippageTolerance > 5000)
            revert Strategy__InvalidLeverageParameters(); // Max 50% slippage

        targetLTV = _targetLTV;
        loopCount = _loopCount;
        slippageTolerance = _slippageTolerance;

        emit StrategyParametersUpdated(
            _targetLTV,
            _loopCount,
            _slippageTolerance
        );
    }

    /**
     * @notice Sets maximum single withdrawal amount
     * @param _max New maximum in WETH units
     */
    function setMaxSingleWithdraw(uint256 _max) external onlyOwner {
        maxSingleWithdraw = _max;
    }

    /**
     * @notice Toggle emergency pause state
     */
    function toggleEmergencyPause() external onlyOwner {
        emergencyPaused = !emergencyPaused;
        emit EmergencyPauseToggled(emergencyPaused);
    }

    /**
     * @notice Emergency function to recover stuck tokens
     * @param token Address of token to recover
     * @param amount Amount to recover
     */
    function recoverToken(address token, uint256 amount) external onlyOwner {
        if (
            token == address(WETH) ||
            token == address(cbETH) ||
            token == A_WETH ||
            token == DEBT_CBETH
        ) {
            revert Strategy__InvalidAsset();
        }
        IERC20(token).safeTransfer(owner(), amount);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the vault address
     */
    function vault() external view override returns (address) {
        return VAULT;
    }

    /**
     * @notice Returns the asset address (WETH)
     */
    function asset() external view override returns (address) {
        return ASSET;
    }

    /**
     * @notice Returns current position metrics
     * @return collateral Total WETH collateral in Aave
     * @return debt Total cbETH debt in Aave
     * @return healthFactor Current health factor
     * @return netValue Net position value in WETH
     */
    function getPositionMetrics()
        external
        view
        returns (
            uint256 collateral,
            uint256 debt,
            uint256 healthFactor,
            uint256 netValue
        )
    {
        collateral = IAToken(A_WETH).balanceOf(address(this));
        debt = IERC20(DEBT_CBETH).balanceOf(address(this));
        healthFactor = _getHealthFactor();
        netValue = this.totalAssets();
    }

    /**
     * @notice Returns current strategy parameters
     */
    function getStrategyParameters()
        external
        view
        returns (
            uint256 _targetLTV,
            uint256 _loopCount,
            uint256 _slippageTolerance
        )
    {
        return (targetLTV, loopCount, slippageTolerance);
    }

    /**
     * @notice Checks if WETH or cbETH reserves are paused in Aave
     * @return wethPaused True if WETH is paused
     * @return cbethPaused True if cbETH is paused
     */
    function areAssetsPaused()
        external
        view
        returns (bool wethPaused, bool cbethPaused)
    {
        DataTypes.ReserveData memory wethReserveData = AAVE_POOL.getReserveData(
            address(WETH)
        );
        DataTypes.ReserveData memory cbethReserveData = AAVE_POOL
            .getReserveData(address(cbETH));

        wethPaused = (wethReserveData.configuration.data >> 60) & 1 == 1;
        cbethPaused = (cbethReserveData.configuration.data >> 60) & 1 == 1;
    }

    /**
     * @notice Returns current leverage ratio
     * @return leverageRatio Current leverage (collateral / net value)
     */
    function getCurrentLeverageRatio()
        external
        view
        returns (uint256 leverageRatio)
    {
        uint256 collateral = IAToken(A_WETH).balanceOf(address(this));
        uint256 netValue = this.totalAssets();

        if (netValue > 0) {
            leverageRatio = (collateral * 1e18) / netValue;
        }
    }
}
