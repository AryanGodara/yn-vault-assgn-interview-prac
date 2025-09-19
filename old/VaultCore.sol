// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {VaultMath} from "./libraries/VaultMath.sol";

/**
 * @title VaultCore
 * @notice ERC4626 tokenized vault with WETH leveraged looping strategy
 * @dev This vault implements multiple security layers and gas optimizations
 *
 * Key Design Decisions:
 * 1. Decimal offset of 3 for inflation attack protection
 * 2. Modular strategy pattern for upgradability
 * 3. Time-delayed strategy updates for security
 * 4. Emergency mechanisms with role-based access
 * 5. WETH-based looping strategy for enhanced yields
 */
contract VaultCore is ERC4626, ReentrancyGuardTransient, Pausable, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using VaultMath for uint256;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Strategy initialization flag
    bool private strategyInitialized;

    // Time delay for strategy updates (security measure)
    uint256 public constant STRATEGY_UPDATE_DELAY = 48 hours;

    // Basis points constants for fee calculations
    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant MAX_PERFORMANCE_FEE = 3_000; // 30% max
    uint256 public constant MAX_MANAGEMENT_FEE = 500; // 5% max annually

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    // Strategy management - packed for gas efficiency
    IStrategy public strategy; // Current active strategy
    IStrategy public pendingStrategy; // Strategy awaiting activation
    uint256 public strategyUpdateTime; // Timestamp when strategy change was proposed

    // Fee configuration - packed into single storage slot
    uint128 public performanceFee = 1_000; // 10% default (in basis points)
    uint128 public managementFee = 200; // 2% annually default (in basis points)

    // Tracking for management fee calculation
    uint256 public lastHarvest; // Last harvest timestamp
    uint256 public lastTotalAssets; // Assets at last harvest

    // Security limits
    uint256 public maxDeposit_ = type(uint256).max;
    uint256 public maxWithdrawPerBlock = 1_000e18; // 1000 WETH per block
    mapping(uint256 => uint256) public blockWithdrawals;

    // Treasury address for fee collection
    address public treasury;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event StrategyProposed(address indexed newStrategy, uint256 activationTime);
    event StrategyUpdated(
        address indexed oldStrategy,
        address indexed newStrategy
    );
    event StrategyInitialized(address indexed strategy);
    event HarvestCompleted(
        uint256 profit,
        uint256 loss,
        uint256 performanceFee
    );
    event FeesUpdated(uint256 performanceFee, uint256 managementFee);
    event EmergencyShutdown(address indexed caller);

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error VaultCore__StrategyNotReady();
    error VaultCore__ExceedsMaxDeposit();
    error VaultCore__ExceedsWithdrawalLimit();
    error VaultCore__InvalidFee();
    error VaultCore__ZeroAddress();
    error VaultCore__NoStrategy();
    error VaultCore__StrategyAlreadySet();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the vault with the given asset
     * @param _asset The ERC20 token to use as the vault's asset (WETH)
     * @param _name Name of the vault token
     * @param _symbol Symbol of the vault token
     * @param _owner The initial owner of the vault
     * @dev Strategy will be set via initStrategy() after deployment
     */
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _owner
    ) ERC4626(_asset) ERC20(_name, _symbol) Ownable(_owner) {
        // Initialize harvest tracking
        lastHarvest = block.timestamp;

        // Set owner as initial treasury
        treasury = _owner;

        // Strategy will be set via initStrategy() after deployment
        strategy = IStrategy(address(0));
        strategyInitialized = false;
    }

    /*//////////////////////////////////////////////////////////////
                        DECIMAL OFFSET OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the decimal offset for share precision
     * @return offset The decimal offset (3 = 1000x multiplier)
     * @dev This is a critical security feature that makes inflation attacks
     *      economically unfeasible by requiring massive capital deployment
     */
    function _decimalsOffset() internal pure virtual override returns (uint8) {
        return 3;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits assets and mints shares to receiver
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive the shares
     * @return shares Amount of shares minted
     * @dev Includes reentrancy protection and strategy allocation
     */
    function deposit(
        uint256 assets,
        address receiver
    )
        public
        virtual
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        // Check deposit limit
        if (assets > maxDeposit(receiver)) {
            revert VaultCore__ExceedsMaxDeposit();
        }

        // Perform the deposit (handles share minting and asset transfer)
        shares = super.deposit(assets, receiver);

        // Allocate deposited funds to strategy for yield generation
        _allocateToStrategy();

        return shares;
    }

    /**
     * @notice Withdraws assets by burning owner's shares
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive the assets
     * @param owner Address whose shares are being burned
     * @return shares Amount of shares burned
     * @dev Includes withdrawal limit checks and strategy unwinding
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        virtual
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        // Check per-block withdrawal limit for security
        _checkWithdrawalLimit(assets);

        // Withdraw from strategy if vault doesn't have enough balance
        _withdrawFromStrategy(assets);

        // Perform the withdrawal (handles share burning and asset transfer)
        shares = super.withdraw(assets, receiver, owner);

        return shares;
    }

    /**
     * @notice Redeems shares for assets
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive the assets
     * @param owner Address whose shares are being redeemed
     * @return assets Amount of assets withdrawn
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        virtual
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        // Convert shares to assets for withdrawal limit check
        assets = previewRedeem(shares);
        _checkWithdrawalLimit(assets);

        // Withdraw from strategy if needed
        _withdrawFromStrategy(assets);

        // Perform the redemption
        assets = super.redeem(shares, receiver, owner);

        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                        TOTAL ASSETS OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns total assets under management
     * @return Total assets in vault + strategy
     * @dev This is called by share conversion functions, so it's critical
     *      for accurate share pricing
     */
    function totalAssets() public view virtual override returns (uint256) {
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        uint256 strategyBalance = address(strategy) != address(0)
            ? strategy.totalAssets()
            : 0;
        return vaultBalance + strategyBalance;
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the strategy (can only be called once)
     * @param _strategy Address of the strategy contract
     * @dev Must be called after deployment to set the strategy
     */
    function initStrategy(address _strategy) external onlyOwner {
        if (strategyInitialized) revert VaultCore__StrategyAlreadySet();
        if (_strategy == address(0)) revert VaultCore__ZeroAddress();

        strategy = IStrategy(_strategy);
        strategyInitialized = true;

        emit StrategyInitialized(_strategy);
    }

    /**
     * @notice Proposes a new strategy with time delay
     * @param _newStrategy Address of the new strategy contract
     * @dev Only owner can propose strategies
     */
    function proposeStrategy(address _newStrategy) external onlyOwner {
        if (_newStrategy == address(0)) revert VaultCore__ZeroAddress();

        pendingStrategy = IStrategy(_newStrategy);
        strategyUpdateTime = block.timestamp + STRATEGY_UPDATE_DELAY;

        emit StrategyProposed(_newStrategy, strategyUpdateTime);
    }

    /**
     * @notice Activates the pending strategy after time delay
     * @dev Migrates all funds from old strategy to new one
     */
    function updateStrategy() external onlyOwner {
        if (block.timestamp < strategyUpdateTime) {
            revert VaultCore__StrategyNotReady();
        }

        // Withdraw all funds from current strategy
        if (address(strategy) != address(0)) {
            strategy.emergencyWithdraw();
        }

        // Update strategy reference
        IStrategy oldStrategy = strategy;
        strategy = pendingStrategy;
        pendingStrategy = IStrategy(address(0));
        strategyUpdateTime = 0;

        // Allocate funds to new strategy
        _allocateToStrategy();

        emit StrategyUpdated(address(oldStrategy), address(strategy));
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allocates idle vault funds to the strategy
     * @dev Called after deposits to put funds to work immediately
     */
    function _allocateToStrategy() internal {
        if (address(strategy) == address(0)) return;

        uint256 availableBalance = IERC20(asset()).balanceOf(address(this));

        // Keep a small buffer in vault for gas efficiency on small withdrawals
        uint256 buffer = totalAssets() / 100; // 1% buffer

        if (availableBalance > buffer) {
            uint256 toAllocate = availableBalance - buffer;
            IERC20(asset()).safeTransfer(address(strategy), toAllocate);
            strategy.deposit();
        }
    }

    /**
     * @notice Withdraws assets from strategy if vault balance insufficient
     * @param amount Amount of assets needed
     */
    function _withdrawFromStrategy(uint256 amount) internal {
        if (address(strategy) == address(0)) return;

        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));

        if (vaultBalance < amount) {
            uint256 needed = amount - vaultBalance;
            strategy.withdraw(needed);
        }
    }

    /**
     * @notice Checks if withdrawal exceeds per-block limit
     * @param amount Amount to withdraw
     * @dev Prevents large withdrawals that could be attacks
     */
    function _checkWithdrawalLimit(uint256 amount) internal {
        uint256 currentBlock = block.number;
        uint256 totalThisBlock = blockWithdrawals[currentBlock] + amount;

        if (totalThisBlock > maxWithdrawPerBlock) {
            revert VaultCore__ExceedsWithdrawalLimit();
        }

        blockWithdrawals[currentBlock] = totalThisBlock;
    }

    /*//////////////////////////////////////////////////////////////
                        HARVEST & FEE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Harvests yield from strategy and collects fees
     * @dev Can be called by anyone but fees go to treasury
     */
    function harvest() external returns (uint256 profit, uint256 loss) {
        if (address(strategy) == address(0)) revert VaultCore__NoStrategy();

        // Get performance from strategy
        uint256 currentAssets;
        (currentAssets, profit, loss) = strategy.harvestAndReport();

        // Calculate fees
        uint256 performanceFeeAmount = 0;
        uint256 managementFeeAmount = 0;

        if (profit > 0) {
            // Performance fee on profit
            performanceFeeAmount = profit.mulDiv(
                performanceFee,
                MAX_BPS,
                Math.Rounding.Floor
            );
        }

        // Management fee calculation (annual rate adjusted for time passed)
        uint256 timePassed = block.timestamp - lastHarvest;
        uint256 avgAssets = (lastTotalAssets + currentAssets) / 2;
        managementFeeAmount = avgAssets.mulDiv(
            managementFee * timePassed,
            MAX_BPS * 365 days,
            Math.Rounding.Floor
        );

        // Mint fee shares to treasury
        uint256 totalFees = performanceFeeAmount + managementFeeAmount;
        if (totalFees > 0) {
            // Use enhanced VaultMath for precise fee share calculation
            uint256 feeShares = VaultMath.calculateFeeShares(
                totalFees,
                totalSupply(),
                currentAssets
            );
            // Mint fee shares to treasury
            _mint(treasury, feeShares);
        }

        // Update tracking variables
        lastHarvest = block.timestamp;
        lastTotalAssets = currentAssets;

        emit HarvestCompleted(profit, loss, performanceFeeAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency pause - stops deposits but allows withdrawals
     * @dev Only EMERGENCY_ROLE can trigger this
     */
    function emergencyPause() external onlyOwner {
        _pause();

        // Pull all funds from strategy
        if (address(strategy) != address(0)) {
            strategy.emergencyWithdraw();
        }

        emit EmergencyShutdown(msg.sender);
    }

    /**
     * @notice Resume normal operations after emergency
     */
    function unpause() external onlyOwner {
        _unpause();

        // Reallocate to strategy
        _allocateToStrategy();
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns maximum deposit amount for a receiver
     * @return Maximum deposit amount
     */
    function maxDeposit(
        address /* receiver */
    ) public view virtual override returns (uint256) {
        if (paused()) return 0;
        return maxDeposit_;
    }

    /**
     * @notice Returns maximum shares that can be minted to receiver
     * @return Maximum mintable shares
     */
    function maxMint(
        address /* receiver */
    ) public view virtual override returns (uint256) {
        if (paused()) return 0;
        return
            VaultMath.convertToShares(
                maxDeposit_,
                totalSupply(),
                totalAssets(),
                false
            );
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates fee configuration
     * @param _performanceFee New performance fee in basis points
     * @param _managementFee New management fee in basis points
     */
    function setFees(
        uint128 _performanceFee,
        uint128 _managementFee
    ) external onlyOwner {
        if (
            _performanceFee > MAX_PERFORMANCE_FEE ||
            _managementFee > MAX_MANAGEMENT_FEE
        ) {
            revert VaultCore__InvalidFee();
        }

        performanceFee = _performanceFee;
        managementFee = _managementFee;

        emit FeesUpdated(_performanceFee, _managementFee);
    }

    /**
     * @notice Updates withdrawal limit per block
     * @param _newLimit New limit in asset units
     */
    function setWithdrawalLimit(uint256 _newLimit) external onlyOwner {
        maxWithdrawPerBlock = _newLimit;
    }

    /**
     * @notice Updates treasury address for fee collection
     * @param _newTreasury New treasury address
     */
    function setTreasury(address _newTreasury) external onlyOwner {
        if (_newTreasury == address(0)) revert VaultCore__ZeroAddress();
        treasury = _newTreasury;
    }

    /*//////////////////////////////////////////////////////////////
                        ENHANCED MATH FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the current share price with high precision
     * @return price Share price in assets per share (scaled by 1e18)
     */
    function getSharePrice() external view returns (uint256 price) {
        return VaultMath.getSharePrice(totalSupply(), totalAssets());
    }

    /**
     * @notice Checks if the vault is in bootstrap phase
     * @return isBootstrap True if in bootstrap phase
     */
    function isBootstrapPhase() external view returns (bool isBootstrap) {
        return VaultMath.isBootstrapPhase(totalSupply(), totalAssets());
    }

    /**
     * @notice Estimates the cost of an inflation attack
     * @param targetRatio The ratio the attacker wants to achieve (scaled by 1e18)
     * @return attackCost Minimum assets needed for the attack
     */
    function estimateInflationAttackCost(
        uint256 targetRatio
    ) external view returns (uint256 attackCost) {
        return
            VaultMath.estimateInflationAttackCost(
                targetRatio,
                totalSupply(),
                totalAssets()
            );
    }
}
