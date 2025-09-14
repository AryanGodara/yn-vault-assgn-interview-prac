// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {BaseVault} from "yieldnest-vault/BaseVault.sol";
import {IERC20, SafeERC20} from "yieldnest-vault/Common.sol";

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
 * @title YieldNestLoopingVault
 * @author YieldNest Assignment
 * @notice Leveraged looping strategy vault for YieldNest's MAX LRT system
 * @dev Standalone vault that implements cbETH/WETH looping using Aave V3 and Curve
 */
contract YieldNestLoopingVault is BaseVault {
    using SafeERC20 for IERC20;

    // ============ Role Management ============
    /// @notice Role for allocator permissions (MAX vault)
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    /// @notice Role for strategy parameter management
    bytes32 public constant STRATEGY_MANAGER_ROLE =
        keccak256("STRATEGY_MANAGER_ROLE");

    /// @notice Role for emergency operations
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // ============ Protocol Integrations ============
    IPool public constant AAVE_POOL =
        IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2); // Ethereum Aave V3
    IAaveOracle public constant AAVE_ORACLE =
        IAaveOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2); // Ethereum Aave Oracle
    ICurvePool public constant CURVE_CBETH_ETH_POOL =
        ICurvePool(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A); // Curve cbETH/WETH pool

    // ============ Assets ============
    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // Ethereum WETH
    IERC20 public constant cbETH =
        IERC20(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704); // Ethereum cbETH

    // ============ Strategy Parameters ============
    uint256 public targetLTV = 7000; // 70% LTV target (adjustable)
    uint256 public constant MAX_LTV = 7500; // 75% safety threshold
    uint256 public loopCount = 3; // Number of leverage loops (adjustable)
    uint256 public slippageTolerance = 1000; // 10% slippage tolerance for Curve (adjustable)

    // ============ Strategy Storage ============
    struct LoopingStorage {
        bool syncDeposit; // Whether to execute loops on deposit
        bool syncWithdraw; // Whether to unwind on withdraw
        bool hasAllocators; // Whether allocator restrictions are active
        uint256 totalCollateral; // Total WETH supplied to Aave
        uint256 totalDebt; // Total cbETH borrowed from Aave
    }

    // ============ Events ============
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
    event EmergencyDeleveraged(uint256 collateralWithdrawn, uint256 debtRepaid);

    // ============ Errors ============
    error HealthFactorTooLow(uint256 healthFactor);
    error InvalidLeverageParameters();
    error SwapFailed();
    error InsufficientLiquidity();

    /**
     * @notice Initialize the vault (must be called after deployment)
     * @param admin The admin address
     * @param name The vault name
     * @param symbol The vault symbol
     */
    function initialize(
        address admin,
        string memory name,
        string memory symbol
    ) external initializer {
        // Initialize the base vault
        _initialize(
            admin,
            name,
            symbol,
            18, // decimals
            true, // paused (start paused for safety)
            false, // countNativeAsset
            true, // alwaysComputeTotalAssets
            0 // defaultAssetIndex
        );

        // Add WETH as the primary asset (depositable and withdrawable)
        _addAsset(address(WETH), 18, true);

        // Add cbETH as non-depositable (internal use only)
        _addAsset(address(cbETH), 18, false);

        // Initialize strategy storage
        LoopingStorage storage loopingStorage = _getLoopingStorage();
        loopingStorage.syncDeposit = true;
        loopingStorage.syncWithdraw = true;
        loopingStorage.hasAllocators = true;

        // Grant additional roles to admin
        _grantRole(ALLOCATOR_ROLE, admin);
        _grantRole(STRATEGY_MANAGER_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
    }

    /**
     * @notice Override deposit to add leverage execution
     * @param assets Amount of WETH to deposit
     * @param receiver Address to receive vault shares
     * @return shares Amount of shares minted
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public virtual override onlyAllocator returns (uint256 shares) {
        // Call parent deposit which handles the standard ERC4626 logic
        shares = super.deposit(assets, receiver);
        
        // Execute leverage loops if enabled
        LoopingStorage storage loopingStorage = _getLoopingStorage();
        if (loopingStorage.syncDeposit) {
            _executeLeverageLoops(assets);
        }
        
        return shares;
    }

    /**
     * @notice Override withdraw to add position unwinding
     * @param assets Amount of WETH to withdraw
     * @param receiver Address to receive WETH
     * @param owner Owner of the shares
     * @return shares Amount of shares burned
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override onlyAllocator returns (uint256 shares) {
        // Unwind leveraged position if enabled
        LoopingStorage storage loopingStorage = _getLoopingStorage();
        if (loopingStorage.syncWithdraw) {
            _unwindPosition(assets);
        }
        
        // Call parent withdraw which handles the standard ERC4626 logic
        return super.withdraw(assets, receiver, owner);
    }

    /**
     * @notice Override redeem to add position unwinding
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive WETH
     * @param owner Owner of the shares
     * @return assets Amount of WETH withdrawn
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override onlyAllocator returns (uint256 assets) {
        // Calculate assets to withdraw
        assets = previewRedeem(shares);
        
        // Unwind leveraged position if enabled
        LoopingStorage storage loopingStorage = _getLoopingStorage();
        if (loopingStorage.syncWithdraw) {
            _unwindPosition(assets);
        }
        
        // Call parent redeem which handles the standard ERC4626 logic
        return super.redeem(shares, receiver, owner);
    }

    /**
     * @notice Override maxWithdraw to account for liquidity constraints
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        
        uint256 shares = balanceOf(owner);
        if (shares == 0) return 0;
        
        // For leveraged vault, we can withdraw by unwinding positions
        // Return the theoretical max based on share value
        return previewRedeem(shares);
    }

    /**
     * @notice Override maxRedeem to account for liquidity constraints
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        
        uint256 shares = balanceOf(owner);
        return shares;
    }

    /**
     * @notice Override buffer to return address(0) since we don't use a buffer strategy
     */
    function buffer() public view override returns (address) {
        return address(0);
    }

    /**
     * @notice Override _withdraw to handle our custom withdrawal logic
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        // Check actual WETH balance and adjust if necessary
        uint256 actualWETHBalance = WETH.balanceOf(address(this));
        uint256 actualAssets = assets;
        
        if (actualWETHBalance < assets) {
            // If we don't have enough WETH, transfer what we have
            actualAssets = actualWETHBalance;
        }
        
        _subTotalAssets(_convertAssetToBase(asset(), actualAssets));
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // Burn shares before withdrawing assets
        _burn(owner, shares);

        // Transfer actual WETH available
        if (actualAssets > 0) {
            WETH.safeTransfer(receiver, actualAssets);
        }

        emit Withdraw(caller, receiver, owner, actualAssets, shares);
    }


    /**
     * @notice Execute leveraged looping strategy
     * @param initialWETH Amount of WETH to start the loops with
     */
    function _executeLeverageLoops(uint256 initialWETH) internal {
        if (initialWETH == 0) return;

        uint256 collateralAmount = initialWETH;

        for (uint256 i = 0; i < loopCount; i++) {
            // 1. Supply WETH as collateral
            WETH.forceApprove(address(AAVE_POOL), collateralAmount);
            AAVE_POOL.supply(
                address(WETH),
                collateralAmount,
                address(this),
                0 // referral code
            );

            // 2. Calculate borrow amount in cbETH using oracle prices
            uint256 wethPrice = AAVE_ORACLE.getAssetPrice(address(WETH));
            uint256 cbETHPrice = AAVE_ORACLE.getAssetPrice(address(cbETH));
            uint256 borrowValueUSD = (collateralAmount *
                wethPrice *
                targetLTV) / 10000;
            uint256 borrowAmount = borrowValueUSD / cbETHPrice;

            // 3. Borrow cbETH against WETH collateral
            AAVE_POOL.borrow(
                address(cbETH),
                borrowAmount,
                2, // variable interest rate mode
                0, // referral
                address(this)
            );

            // 4. Swap borrowed cbETH to WETH for next loop
            if (i < loopCount - 1) {
                collateralAmount = _swapcbETHToWETH(borrowAmount);
            }
        }

        // Update position tracking and validate health factor
        _updatePositionMetrics();
        _validateHealthFactor();

        LoopingStorage storage loopingStorage = _getLoopingStorage();
        (, , , , , uint256 healthFactor) = AAVE_POOL.getUserAccountData(
            address(this)
        );

        emit LeverageExecuted(
            initialWETH,
            loopingStorage.totalCollateral,
            loopingStorage.totalDebt,
            healthFactor
        );
    }

    /**
     * @notice Unwind leveraged position for withdrawals
     * @param targetWithdrawAmount Amount of WETH to withdraw
     */
    function _unwindPosition(uint256 targetWithdrawAmount) internal {
        if (targetWithdrawAmount == 0) return;

        // Check if this is a full withdrawal (close to total vault value)
        uint256 totalVaultValue = _getTotalValue();
        bool isFullWithdrawal = targetWithdrawAmount >= (totalVaultValue * 95) / 100; // 95% threshold

        uint256 totalCollateralWithdrawn = 0;
        uint256 totalDebtRepaid = 0;

        if (isFullWithdrawal) {
            // For full withdrawal, completely unwind the position
            _completelyUnwindPosition();
        } else {
            // For partial withdrawal, unwind proportionally
            _partiallyUnwindPosition(targetWithdrawAmount);
        }

        // Update position tracking
        _updatePositionMetrics();

        (, , , , , uint256 healthFactor) = AAVE_POOL.getUserAccountData(
            address(this)
        );
        emit PositionUnwound(
            totalCollateralWithdrawn,
            totalDebtRepaid,
            healthFactor
        );
    }

    /**
     * @notice Completely unwind the leveraged position
     */
    function _completelyUnwindPosition() internal {
        // Repay all debt iteratively using actual debt token balance
        uint256 iterations = 0;
        uint256 maxIterations = 15; // Increased safety limit
        
        while (iterations < maxIterations) {
            iterations++;
            
            // Get current debt from Aave (this is the actual debt balance)
            (, uint256 totalDebtUSD, , , , ) = AAVE_POOL.getUserAccountData(address(this));
            if (totalDebtUSD < 1e6) break; // Less than $1 USD debt, consider it zero
            
            // Get cbETH price to convert USD debt to cbETH amount
            uint256 cbETHPrice = AAVE_ORACLE.getAssetPrice(address(cbETH));
            uint256 debtInCbETH = (totalDebtUSD * 1e18) / cbETHPrice; // Convert to cbETH amount
            
            if (debtInCbETH < 1e15) break; // Less than 0.001 cbETH
            
            // Calculate WETH needed to get enough cbETH (with generous buffer)
            uint256 wethNeeded = (debtInCbETH * 11000) / 10000; // 110% of debt in WETH terms
            
            // Try to withdraw WETH collateral
            try AAVE_POOL.withdraw(address(WETH), wethNeeded, address(this)) returns (uint256 withdrawn) {
                if (withdrawn == 0) break;
                
                // Swap WETH to cbETH to repay debt
                uint256 cbETHReceived = _swapWETHTocbETH(withdrawn);
                
                // Repay all available cbETH debt
                if (cbETHReceived > 0) {
                    cbETH.forceApprove(address(AAVE_POOL), cbETHReceived);
                    AAVE_POOL.repay(address(cbETH), type(uint256).max, 2, address(this));
                }
                
            } catch {
                // If withdrawal fails, try with 50% of the amount
                try AAVE_POOL.withdraw(address(WETH), wethNeeded / 2, address(this)) returns (uint256 withdrawn) {
                    if (withdrawn > 0) {
                        uint256 cbETHReceived = _swapWETHTocbETH(withdrawn);
                        if (cbETHReceived > 0) {
                            cbETH.forceApprove(address(AAVE_POOL), cbETHReceived);
                            AAVE_POOL.repay(address(cbETH), type(uint256).max, 2, address(this));
                        }
                    }
                } catch {
                    // If still failing, break out
                    break;
                }
            }
        }
        
        // Final cleanup: withdraw any remaining WETH collateral
        try AAVE_POOL.withdraw(address(WETH), type(uint256).max, address(this)) {} catch {}
    }

    /**
     * @notice Partially unwind position for partial withdrawals
     */
    function _partiallyUnwindPosition(uint256 targetWithdrawAmount) internal {
        // Check current WETH balance
        uint256 currentWETHBalance = WETH.balanceOf(address(this));
        if (currentWETHBalance >= targetWithdrawAmount) {
            return; // Already have enough WETH
        }

        uint256 wethNeeded = targetWithdrawAmount - currentWETHBalance;

        // Get current debt balance
        uint256 currentDebt = cbETH.balanceOf(address(this));
        if (currentDebt == 0) {
            // No debt, just withdraw WETH collateral directly
            AAVE_POOL.withdraw(address(WETH), wethNeeded, address(this));
            return;
        }

        // Unwind position iteratively until we have enough WETH
        uint256 iterations = 0;
        uint256 maxIterations = loopCount + 2; // Safety limit
        
        while (WETH.balanceOf(address(this)) < targetWithdrawAmount && iterations < maxIterations) {
            iterations++;
            
            // Calculate how much debt to repay (start with smaller amounts)
            uint256 debtToRepay = currentDebt / (maxIterations - iterations + 1);
            if (debtToRepay == 0) debtToRepay = 1e15; // Minimum 0.001 cbETH
            
            // Calculate collateral to withdraw (with buffer for slippage)
            uint256 collateralToWithdraw = (debtToRepay * 12000) / 10000; // 120% buffer
            
            // Ensure we don't withdraw more than available
            try AAVE_POOL.withdraw(address(WETH), collateralToWithdraw, address(this)) returns (uint256 withdrawn) {
                if (withdrawn == 0) break;
                
                // Swap only what's needed to repay debt
                uint256 wethForSwap = withdrawn;
                
                // If we have more WETH than needed for debt repayment, keep some
                if (withdrawn > debtToRepay) {
                    wethForSwap = debtToRepay;
                }
                
                if (wethForSwap > 0) {
                    // Swap WETH to cbETH to repay debt
                    uint256 cbETHReceived = _swapWETHTocbETH(wethForSwap);
                    
                    // Repay cbETH debt
                    if (cbETHReceived > 0) {
                        cbETH.forceApprove(address(AAVE_POOL), cbETHReceived);
                        AAVE_POOL.repay(address(cbETH), cbETHReceived, 2, address(this));
                    }
                }
                
                currentDebt = cbETH.balanceOf(address(this));
                
            } catch {
                // If withdrawal fails, try with smaller amount
                collateralToWithdraw = collateralToWithdraw / 2;
                if (collateralToWithdraw < 1e15) break; // Too small, exit
            }
        }
    }

    /**
     * @notice Swap cbETH to WETH using Curve pool
     */
    function _swapcbETHToWETH(
        uint256 cbETHAmount
    ) internal returns (uint256 wethReceived) {
        if (cbETHAmount == 0) return 0;

        // Get expected output from Curve
        uint256 expectedWETH = CURVE_CBETH_ETH_POOL.get_dy(1, 0, cbETHAmount);
        uint256 minOutput = (expectedWETH * (10000 - slippageTolerance)) /
            10000;

        // Approve and swap
        cbETH.forceApprove(address(CURVE_CBETH_ETH_POOL), cbETHAmount);
        wethReceived = CURVE_CBETH_ETH_POOL.exchange(
            1,
            0,
            cbETHAmount,
            minOutput
        );

        if (wethReceived == 0) revert SwapFailed();
    }

    /**
     * @notice Swap WETH to cbETH using Curve pool
     */
    function _swapWETHTocbETH(
        uint256 wethAmount
    ) internal returns (uint256 cbETHReceived) {
        if (wethAmount == 0) return 0;

        // Get expected output from Curve
        uint256 expectedcbETH = CURVE_CBETH_ETH_POOL.get_dy(0, 1, wethAmount);
        uint256 minOutput = (expectedcbETH * (10000 - slippageTolerance)) /
            10000;

        // Approve and swap
        WETH.forceApprove(address(CURVE_CBETH_ETH_POOL), wethAmount);
        cbETHReceived = CURVE_CBETH_ETH_POOL.exchange(
            0,
            1,
            wethAmount,
            minOutput
        );

        if (cbETHReceived == 0) revert SwapFailed();
    }

    /**
     * @notice Calculate safe withdrawal amount maintaining health factor
     */
    function _calculateSafeWithdrawal(
        uint256 debtToRepay
    ) internal view returns (uint256 collateralToWithdraw) {
        // Conservative calculation: withdraw slightly more than needed
        collateralToWithdraw = (debtToRepay * 11000) / 10000; // 110% of debt amount
    }

    /**
     * @notice Get current position metrics
     * @return collateral Total collateral in USD (8 decimals)
     * @return debt Total debt in USD (8 decimals)
     * @return healthFactor Current health factor (18 decimals)
     */
    function getPositionMetrics()
        external
        view
        returns (uint256 collateral, uint256 debt, uint256 healthFactor)
    {
        (collateral, debt, , , , healthFactor) = AAVE_POOL.getUserAccountData(
            address(this)
        );
    }

    /**
     * @notice Get the current value of 1 strategy token in ETH terms
     * @dev This represents the share price - how much ETH value each share represents
     * @return rate The value of 1 strategy token in ETH (18 decimals)
     */
    function getStrategyTokenRate() external view returns (uint256 rate) {
        uint256 totalShares = totalSupply();
        if (totalShares == 0) {
            return 1e18; // 1:1 if no shares exist
        }

        // Get total vault value in ETH terms
        uint256 totalVaultValue = _getTotalValue();

        // Rate = total vault value / total shares
        rate = (totalVaultValue * 1e18) / totalShares;
    }

    /**
     * @notice Override totalAssets to include leveraged position value
     * @return Total assets under management in base units
     */
    function totalAssets() public view override returns (uint256) {
        return _getTotalValue();
    }

    /**
     * @notice Calculate total vault value including leveraged positions
     * @return Total value in ETH terms (18 decimals)
     */
    function _getTotalValue() internal view returns (uint256) {
        // Get WETH balance held directly
        uint256 wethBalance = WETH.balanceOf(address(this));

        // Get Aave position data directly
        (uint256 totalCollateralETH, uint256 totalDebtETH, , , , ) = AAVE_POOL.getUserAccountData(address(this));

        if (totalCollateralETH == 0) {
            return wethBalance; // No leveraged position
        }

        // Aave returns values in USD with 8 decimal precision
        // Convert to ETH using WETH price
        uint256 wethPrice = AAVE_ORACLE.getAssetPrice(address(WETH));
        uint256 collateralETH = (totalCollateralETH * 1e18) / wethPrice;
        uint256 debtETH = (totalDebtETH * 1e18) / wethPrice;
        
        // Net equity = collateral - debt + direct WETH holdings
        uint256 netEquity = collateralETH > debtETH ? collateralETH - debtETH : 0;
            
        return netEquity + wethBalance;
    }

    /**
     * @notice Update position metrics from Aave
     */
    function _updatePositionMetrics() internal {
        (uint256 totalCollateralETH, uint256 totalDebtETH, , , , ) = AAVE_POOL
            .getUserAccountData(address(this));

        LoopingStorage storage loopingStorage = _getLoopingStorage();
        loopingStorage.totalCollateral = totalCollateralETH;
        loopingStorage.totalDebt = totalDebtETH;
    }


    /**
     * @notice Validate health factor is above minimum threshold
     */
    function _validateHealthFactor() internal view {
        (, , , , , uint256 healthFactor) = AAVE_POOL.getUserAccountData(
            address(this)
        );

        if (healthFactor < 1.1e18) {
            revert HealthFactorTooLow(healthFactor);
        }
    }

    /**
     * @notice Emergency rebalance function
     */
    function emergencyRebalance() external onlyRole(EMERGENCY_ROLE) {
        (, , , , , uint256 healthFactor) = AAVE_POOL.getUserAccountData(
            address(this)
        );

        if (healthFactor < 1.3e18) {
            _emergencyDeleverage();
        }
    }

    /**
     * @notice Emergency deleveraging function
     */
    function _emergencyDeleverage() internal {
        LoopingStorage storage loopingStorage = _getLoopingStorage();

        // Withdraw 10% of collateral and repay debt
        uint256 collateralToWithdraw = loopingStorage.totalCollateral / 10;

        if (collateralToWithdraw > 0) {
            uint256 withdrawn = AAVE_POOL.withdraw(
                address(WETH),
                collateralToWithdraw,
                address(this)
            );

            uint256 cbETHReceived = _swapWETHTocbETH(withdrawn);

            cbETH.forceApprove(address(AAVE_POOL), cbETHReceived);
            AAVE_POOL.repay(address(cbETH), cbETHReceived, 2, address(this));

            _updatePositionMetrics();

            emit EmergencyDeleveraged(withdrawn, cbETHReceived);
        }
    }

    /**
     * @notice Set strategy parameters
     */
    function setStrategyParameters(
        uint256 _targetLTV,
        uint256 _loopCount,
        uint256 _slippageTolerance
    ) external onlyRole(STRATEGY_MANAGER_ROLE) {
        if (
            _targetLTV >= MAX_LTV ||
            _loopCount == 0 ||
            _slippageTolerance > 1000
        ) {
            revert InvalidLeverageParameters();
        }

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
     * @notice Get strategy storage
     */
    function _getLoopingStorage()
        internal
        pure
        returns (LoopingStorage storage $)
    {
        assembly {
            // keccak256("yieldnest.storage.looping")
            $.slot := 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
        }
    }

    /**
     * @notice Modifier to restrict access to allocator roles
     */
    modifier onlyAllocator() {
        LoopingStorage storage loopingStorage = _getLoopingStorage();
        if (
            loopingStorage.hasAllocators && !hasRole(ALLOCATOR_ROLE, msg.sender)
        ) {
            revert AccessControlUnauthorizedAccount(msg.sender, ALLOCATOR_ROLE);
        }
        _;
    }

    // ============ Fee Functions (Required by BaseVault) ============

    /**
     * @notice Returns the fee on raw assets (no fees for this vault)
     */
    function _feeOnRaw(uint256) public pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Returns the fee on total assets (no fees for this vault)
     */
    function _feeOnTotal(uint256) public pure override returns (uint256) {
        return 0;
    }
}
