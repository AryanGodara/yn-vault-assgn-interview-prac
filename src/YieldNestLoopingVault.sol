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
    IPool public constant AAVE_POOL =
        IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAaveOracle public constant AAVE_ORACLE =
        IAaveOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);
    ICurvePool public constant CURVE_CBETH_ETH_POOL =
        ICurvePool(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A);

    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant cbETH =
        IERC20(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704); // Ethereum cbETH

    // ============ Strategy Parameters ============
    uint256 public targetLTV = 7000; // 70% LTV target (adjustable)
    uint256 public constant MAX_LTV = 7500; // 75% safety threshold
    uint256 public loopCount = 3; // Number of leverage loops (adjustable)
    uint256 public slippageTolerance = 1000; // 10% slippage tolerance for Curve (adjustable)

    // ============ Virtual Shares for Inflation Protection ============
    uint256 public constant DECIMAL_OFFSET = 3; // 1 asset = 1000 shares (10^3)

    // ============ Strategy Storage ============
    struct LoopingStorage {
        bool syncDeposit; // Whether to execute loops on deposit
        bool syncWithdraw; // Whether to unwind on withdraw
        bool hasAllocators; // Whether allocator restrictions are active
        uint256 totalCollateralUSD; // Total collateral value in USD (8 decimals)
        uint256 totalDebtUSD; // Total debt value in USD (8 decimals)
    }

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

    error HealthFactorTooLow(uint256 healthFactor);
    error InvalidLeverageParameters();
    error SwapFailed();
    error InsufficientLiquidity();

    // State variables for looping strategy
    using SafeERC20 for IERC20;

    // ============ Decimal Conversion Helpers ============

    /**
     * @notice Convert USD amount (8 decimals) to token amount (18 decimals)
     * @param usdAmount Amount in USD with 8 decimals
     * @param token Token address to get price for
     * @return tokenAmount Amount in token with 18 decimals
     */
    function _convertUSDToTokenAmount(
        uint256 usdAmount,
        address token
    ) internal view returns (uint256 tokenAmount) {
        uint256 tokenPrice = AAVE_ORACLE.getAssetPrice(token);
        // Aave prices are in USD with 8 decimals, convert to token amount with 18 decimals
        return (usdAmount * 1e18) / tokenPrice;
    }

    /**
     * @notice Convert token amount (18 decimals) to USD amount (8 decimals)
     * @param tokenAmount Amount in token with 18 decimals
     * @param token Token address to get price for
     * @return usdAmount Amount in USD with 8 decimals
     */
    function _convertTokenAmountToUSD(
        uint256 tokenAmount,
        address token
    ) internal view returns (uint256 usdAmount) {
        uint256 tokenPrice = AAVE_ORACLE.getAssetPrice(token);
        // Convert from 18 decimal token to 8 decimal USD
        return (tokenAmount * tokenPrice) / 1e18;
    }

    /**
     * @notice Convert assets to shares using virtual shares for inflation protection
     * @param assets Amount of assets to convert
     * @return shares Amount of shares (with virtual offset)
     */
    function _convertToShares(uint256 assets) internal view returns (uint256) {
        // Use virtual shares logic for inflation protection
        // totalAssets() includes leveraged Aave positions via _getTotalValue()
        return
            (assets * (totalSupply() + 10 ** DECIMAL_OFFSET)) /
            (totalAssets() + 1);
    }

    /**
     * @notice Convert shares to assets using virtual shares for inflation protection
     * @param shares Amount of shares to convert
     * @return assets Amount of assets
     */
    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();

        if (supply == 0) {
            return shares / (10 ** DECIMAL_OFFSET);
        } else {
            return
                (shares * (totalAssets() + 1)) /
                (totalSupply() + 10 ** DECIMAL_OFFSET);
        }
    }

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

        // Note: Dead shares protection is handled in first deposit via virtual shares + dead share minting
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
        require(assets > 0, "Cannot deposit 0");

        uint256 supply = totalSupply();
        
        // First deposit: mint dead shares for belt-and-suspenders protection
        if (supply == 0) {
            _mint(address(1), 10 ** DECIMAL_OFFSET); // 1000 dead shares
        }

        // Calculate shares accounting for current leveraged state
        shares = _convertToShares(assets);

        // Transfer WETH from depositor to vault
        WETH.safeTransferFrom(msg.sender, address(this), assets);

        // Mint shares to receiver BEFORE leverage
        _mint(receiver, shares);

        // Update base vault's asset tracking
        _addTotalAssets(_convertAssetToBase(asset(), assets));

        // Execute leverage loops AFTER share calculation
        LoopingStorage storage loopingStorage = _getLoopingStorage();
        if (loopingStorage.syncDeposit) {
            _executeLeverageLoops(assets);
        }

        emit Deposit(msg.sender, receiver, assets, shares);

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
     * @notice Override convertToShares to use virtual shares logic
     * @param assets Amount of assets to convert
     * @return shares Amount of shares
     */
    function convertToShares(
        uint256 assets
    ) public view override returns (uint256 shares) {
        return _convertToShares(assets);
    }

    /**
     * @notice Override convertToAssets to use virtual shares logic
     * @param shares Amount of shares to convert
     * @return assets Amount of assets
     */
    function convertToAssets(
        uint256 shares
    ) public view override returns (uint256 assets) {
        return _convertToAssets(shares);
    }

    /**
     * @notice Override previewDeposit to use virtual shares logic
     * @param assets Amount of assets to deposit
     * @return shares Amount of shares that would be minted
     */
    function previewDeposit(
        uint256 assets
    ) public view override returns (uint256 shares) {
        return _convertToShares(assets);
    }

    /**
     * @notice Override previewWithdraw to use virtual shares logic
     * @param assets Amount of assets to withdraw
     * @return shares Amount of shares that would be burned
     */
    function previewWithdraw(
        uint256 assets
    ) public view override returns (uint256 shares) {
        return _convertToShares(assets);
    }

    /**
     * @notice Override previewRedeem to use virtual shares logic
     * @param shares Amount of shares to redeem
     * @return assets Amount of assets that would be received
     */
    function previewRedeem(
        uint256 shares
    ) public view override returns (uint256 assets) {
        assets = _convertToAssets(shares);
        return assets - _feeOnTotal(assets);
    }

    /**
     * @notice Override buffer to return address(0) since we don't use a buffer strategy
     */
    function buffer() public view override returns (address) {
        return address(0);
    }

    /**
     * @notice Override _withdraw to handle internal withdrawals without buffer
     * @param caller The address of the caller
     * @param receiver Address to receive the assets
     * @param owner Owner of the shares
     * @param assets Amount of assets to withdraw
     * @param shares Amount of shares being redeemed
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // NOTE: burn shares before withdrawing the assets
        _burn(owner, shares);

        // Ensure we have enough WETH by unwinding position if needed
        uint256 currentWETHBalance = WETH.balanceOf(address(this));
        if (currentWETHBalance < assets) {
            uint256 shortfall = assets - currentWETHBalance;
            _unwindPosition(shortfall);
        }

        // Transfer WETH directly since we don't use a buffer strategy
        WETH.safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
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
            // Convert WETH collateral to USD, apply LTV, then convert to cbETH
            uint256 collateralValueUSD = _convertTokenAmountToUSD(
                collateralAmount,
                address(WETH)
            );
            uint256 borrowValueUSD = (collateralValueUSD * targetLTV) / 10000;
            uint256 borrowAmount = _convertUSDToTokenAmount(
                borrowValueUSD,
                address(cbETH)
            );

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
            loopingStorage.totalCollateralUSD,
            loopingStorage.totalDebtUSD,
            healthFactor
        );
    }

    /**
     * @notice Unwind leveraged position for withdrawals
     * @param targetWithdrawAmount Amount of WETH to withdraw
     */
    function _unwindPosition(uint256 targetWithdrawAmount) internal {
        if (targetWithdrawAmount == 0) return;

        // Get current position
        (, uint256 totalDebtUSD, , , , ) = AAVE_POOL.getUserAccountData(
            address(this)
        );

        if (totalDebtUSD == 0) {
            // No leverage, just withdraw from Aave if needed
            uint256 currentWETH = WETH.balanceOf(address(this));
            if (currentWETH < targetWithdrawAmount) {
                uint256 toWithdraw = targetWithdrawAmount - currentWETH;
                AAVE_POOL.withdraw(address(WETH), toWithdraw, address(this));
            }
            return;
        }

        // Calculate what percentage of the vault is being withdrawn
        uint256 totalVaultValue = _getTotalValue();
        uint256 withdrawPercentage = (targetWithdrawAmount * 10000) /
            totalVaultValue;

        // Unwind that percentage of the position
        uint256 debtToRepay = (totalDebtUSD * withdrawPercentage) / 10000;

        // Convert debt USD to cbETH amount using helper function
        uint256 cbETHToRepay = _convertUSDToTokenAmount(
            debtToRepay,
            address(cbETH)
        );

        // Calculate ACTUAL WETH needed using Curve pricing (replaces crude 110% buffer)
        uint256 wethForSwap = _getWETHNeededForCbETHDebt(cbETHToRepay);

        // Withdraw WETH from Aave
        AAVE_POOL.withdraw(
            address(WETH),
            wethForSwap + targetWithdrawAmount,
            address(this)
        );

        if (cbETHToRepay > 0) {
            // Verify we have enough WETH for the swap
            uint256 currentWETH = WETH.balanceOf(address(this));
            require(currentWETH >= wethForSwap + targetWithdrawAmount, "Insufficient WETH after unwind");

            // Swap WETH to cbETH
            uint256 cbETHReceived = _swapWETHTocbETH(wethForSwap);

            // Repay debt
            cbETH.forceApprove(address(AAVE_POOL), cbETHReceived);
            AAVE_POOL.repay(address(cbETH), cbETHReceived, 2, address(this));
        }

        // Update position metrics
        _updatePositionMetrics();

        // Emit position unwound event
        if (cbETHToRepay > 0) {
            (, , , , , uint256 healthFactor) = AAVE_POOL.getUserAccountData(
                address(this)
            );
            emit PositionUnwound(
                wethForSwap + targetWithdrawAmount,
                cbETHToRepay,
                healthFactor
            );
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
     * @notice Get total value of vault including leveraged positions
     * @return Total value in WETH terms
     */
    function _getTotalValue() internal view returns (uint256) {
        uint256 wethBalance = WETH.balanceOf(address(this));

        // Get Aave position value
        (uint256 totalCollateralUSD, uint256 totalDebtUSD, , , , ) = AAVE_POOL
            .getUserAccountData(address(this));

        if (totalCollateralUSD == 0) {
            return wethBalance;
        }

        // Get collateral in WETH terms (this is accurate since we deposited WETH)
        uint256 wethCollateral = _convertUSDToTokenAmount(
            totalCollateralUSD,
            address(WETH)
        );

        // Get debt in cbETH terms
        uint256 cbETHDebt = _convertUSDToTokenAmount(
            totalDebtUSD,
            address(cbETH)
        );

        // Calculate ACTUAL cost to repay cbETH debt using Curve pricing
        uint256 wethToRepayDebt = _getWETHNeededForCbETHDebt(cbETHDebt);

        // Net position = collateral - cost to repay debt
        uint256 netPositionWETH = wethCollateral > wethToRepayDebt
            ? wethCollateral - wethToRepayDebt
            : 0;

        return wethBalance + netPositionWETH;
    }

    /**
     * @notice Calculate WETH needed to acquire cbETH for debt repayment
     * @param cbETHAmount Amount of cbETH debt to repay
     * @return wethNeeded Amount of WETH needed (including slippage buffer)
     */
    function _getWETHNeededForCbETHDebt(uint256 cbETHAmount) internal view returns (uint256 wethNeeded) {
        if (cbETHAmount == 0) return 0;

        // Check the actual exchange rate: how much cbETH do we get for 1 WETH?
        try CURVE_CBETH_ETH_POOL.get_dy(0, 1, 1e18) returns (uint256 cbETHPer1WETH) {
            if (cbETHPer1WETH > 0) {
                // Calculate WETH needed based on actual Curve rate
                // If 1 WETH gets us cbETHPer1WETH cbETH, then we need:
                wethNeeded = (cbETHAmount * 1e18) / cbETHPer1WETH;
                
                // Add 5% buffer for slippage and potential rate changes during execution
                wethNeeded = (wethNeeded * 105) / 100;
            } else {
                // Fallback: assume 10% premium if rate is zero
                wethNeeded = (cbETHAmount * 110) / 100;
            }
        } catch {
            // Conservative fallback if Curve query fails: assume 10% premium
            wethNeeded = (cbETHAmount * 110) / 100;
        }

        // Sanity check: never less than 1:1 oracle rate
        if (wethNeeded < cbETHAmount) {
            wethNeeded = cbETHAmount;
        }

        return wethNeeded;
    }

    /**
     * @notice Update position metrics from Aave
     */
    function _updatePositionMetrics() internal {
        (uint256 totalCollateralUSD, uint256 totalDebtUSD, , , , ) = AAVE_POOL
            .getUserAccountData(address(this));

        LoopingStorage storage loopingStorage = _getLoopingStorage();
        loopingStorage.totalCollateralUSD = totalCollateralUSD;
        loopingStorage.totalDebtUSD = totalDebtUSD;
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
            $.slot := 0x42e745ea4022e8dc581c483cb861e0f15133ffc90d33ffc3731d5b96fbaac92a
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
