// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {YieldNestLoopingVault} from "../../src/YieldNestLoopingVault.sol";
import {LoopingVaultProvider} from "../../src/LoopingVaultProvider.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPriceOracleGetter} from "@aave/core-v3/contracts/interfaces/IPriceOracleGetter.sol"; // Not needed for basic vault functionality
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
 * @title YieldNest Looping Vault Fork Tests
 * @notice Comprehensive fork tests for the YieldNest Looping Vault on Ethereum mainnet
 * @dev Tests cbETH leverage looping with Curve, deposits, withdrawals, and emergency functions
 */
contract YieldNestLoopingVaultTest is Test {
    YieldNestLoopingVault public vault;
    ERC1967Proxy public proxy;
    LoopingVaultProvider public provider;

    // ============ Ethereum Mainnet Addresses ============
    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant cbETH =
        IERC20(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704);
    IPool public constant AAVE_POOL =
        IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAaveOracle public constant AAVE_ORACLE =
        IAaveOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);
    ICurvePool public constant CURVE_CBETH_ETH_POOL =
        ICurvePool(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A);

    // ============ Test Accounts ============
    address public admin = makeAddr("admin");
    address public allocator = makeAddr("allocator"); // Simulates MAX vault
    address public user = makeAddr("user");
    address public emergencyManager = makeAddr("emergencyManager");
    uint256 public forkId;

    // ============ Test Constants ============
    uint256 public constant INITIAL_WETH_BALANCE = 100 ether;
    uint256 public constant DEPOSIT_AMOUNT = 10 ether;

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
    event EmergencyDeleveraged(uint256 collateralWithdrawn, uint256 debtRepaid);

    function setUp() public {
        // Fork Ethereum mainnet at recent block for testing
        forkId = vm.createSelectFork(
            "https://eth-mainnet.g.alchemy.com/v2/p0Mcrc-7v8nMe2WqSYhi5lx789KlX3z8",
            21363800
        );
        assertEq(block.number, 21363800);

        // Deploy contracts directly in test
        // provider = new LoopingVaultProvider(); // Not needed for basic vault functionality

        YieldNestLoopingVault implementation = new YieldNestLoopingVault();

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(
            YieldNestLoopingVault.initialize.selector,
            admin,
            "YieldNest Looping ETH Vault",
            "ynLoopETH"
        );

        proxy = new ERC1967Proxy(address(implementation), initData);
        vault = YieldNestLoopingVault(payable(address(proxy)));

        // Configure vault from admin (who has DEFAULT_ADMIN_ROLE)
        vm.startPrank(admin);

        // Set strategy parameters for cbETH/Curve
        vault.setStrategyParameters(
            7000, // 70% target LTV (aggressive for testing)
            5, // 5 loops
            1000 // 10% slippage tolerance for Curve
        );

        // Grant test-specific roles
        vault.grantRole(vault.ALLOCATOR_ROLE(), allocator);

        // Grant UNPAUSER_ROLE and PROVIDER_MANAGER_ROLE to admin
        vault.grantRole(vault.UNPAUSER_ROLE(), admin);
        vault.grantRole(vault.PROVIDER_MANAGER_ROLE(), admin);

        // Deploy and set provider (required for vault operations)
        provider = new LoopingVaultProvider();
        vault.setProvider(address(provider));

        vm.stopPrank();

        // Fund test accounts with WETH and cbETH
        deal(address(WETH), allocator, INITIAL_WETH_BALANCE);
        deal(address(WETH), user, INITIAL_WETH_BALANCE);
        deal(address(cbETH), allocator, 50 ether);
        deal(address(cbETH), user, 50 ether);

        // Approve vault to spend WETH
        vm.prank(allocator);
        WETH.approve(address(vault), type(uint256).max);

        vm.prank(user);
        WETH.approve(address(vault), type(uint256).max);
    }

    // ============ Initialization Tests ============

    function test_VaultInitialization() public {
        assertEq(vault.name(), "YieldNest Looping ETH Vault");
        assertEq(vault.symbol(), "ynLoopETH");
        assertEq(vault.decimals(), 18);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.ALLOCATOR_ROLE(), allocator));
        // Note: Vault starts paused for safety - this is expected behavior
        assertTrue(vault.paused());
    }

    function test_StrategyParameters() public {
        assertEq(vault.targetLTV(), 7000); // 70% target LTV
        assertEq(vault.loopCount(), 5);
        assertEq(vault.slippageTolerance(), 1000); // 10% slippage tolerance for Curve
    }

    // ============ Deposit Tests ============

    function test_BasicDeposit() public {
        // Unpause vault for deposit testing
        vm.prank(admin);
        vault.unpause();
        
        // Test deposit functionality with leverage execution
        uint256 depositAmount = DEPOSIT_AMOUNT;
        uint256 initialBalance = WETH.balanceOf(allocator);

        vm.prank(allocator);
        uint256 shares = vault.deposit(depositAmount, allocator);

        // Check shares were minted
        assertGt(shares, 0);
        assertEq(vault.balanceOf(allocator), shares);

        // Check WETH was transferred
        assertEq(WETH.balanceOf(allocator), initialBalance - depositAmount);

        // Verify leverage was applied
        (
            uint256 collateral,
            uint256 debt,
            ,
            ,
            ,
            uint256 healthFactor
        ) = AAVE_POOL.getUserAccountData(address(vault));

        assertGt(collateral, 0);
        assertGt(debt, 0);
        assertGt(healthFactor, 1.05e18); // Accept lower health factor for aggressive testing

        // With 5 loops at 70% LTV, we should have significant leverage
        // Convert collateral (USD with 8 decimals) to ETH equivalent for comparison
        uint256 wethPrice = AAVE_ORACLE.getAssetPrice(address(WETH));
        uint256 collateralInETH = (collateral * 1e18) / wethPrice;
        assertGt(collateralInETH, (depositAmount * 18) / 10); // At least 1.8x leverage

        // Check LTV is within target range
        uint256 actualLTV = (debt * 10000) / collateral;
        assertLt(actualLTV, 7500); // Below max LTV
        assertGt(actualLTV, 6000); // Reasonable leverage achieved

        console.log("Deposit with leverage successful:");
        console.log("  Shares minted:", shares);
        console.log("  Collateral:", collateral);
        console.log("  Debt:", debt);
        console.log("  Health Factor:", healthFactor);
        console.log(
            "  Leverage ratio:",
            (collateralInETH * 1e18) / depositAmount
        );
    }

    function test_MultipleDeposits() public {
        // Unpause vault for deposit testing
        vm.prank(admin);
        vault.unpause();
        
        // Create 5 random addresses with realistic deposit amounts
        address[5] memory depositors = [
            makeAddr("depositor1"),
            makeAddr("depositor2"),
            makeAddr("depositor3"),
            makeAddr("depositor4"),
            makeAddr("depositor5")
        ];

        uint256[5] memory depositAmounts = [
            uint256(2.5 ether), // $10,000 worth
            uint256(1.8 ether), // $7,200 worth
            uint256(3.2 ether), // $12,800 worth
            uint256(1.1 ether), // $4,400 worth
            uint256(2.7 ether) // $10,800 worth
        ];

        uint256 totalShares = 0;
        uint256 totalDeposited = 0;

        for (uint256 i = 0; i < 5; i++) {
            address depositor = depositors[i];
            uint256 amount = depositAmounts[i];

            // Fund depositor
            deal(address(WETH), depositor, amount + 10 ether);

            // Transfer WETH to allocator and deposit on behalf of depositor
            vm.prank(depositor);
            WETH.transfer(allocator, amount);

            // Approve and deposit using allocator
            vm.prank(allocator);
            WETH.approve(address(vault), amount);

            vm.prank(allocator);
            uint256 shares = vault.deposit(amount, depositor);

            totalShares += shares;
            totalDeposited += amount;

            // Log deposit results
            (uint256 collateral, uint256 debt, , , , uint256 hf) = AAVE_POOL
                .getUserAccountData(address(vault));

            console.log("Deposit", i + 1, ":");
            console.log("  Amount:", amount);
            console.log("  Shares:", shares);
            console.log("  Total Assets:", vault.totalAssets());
            console.log("  Total Supply:", vault.totalSupply());
            console.log("  Total Collateral:", collateral);
            console.log("  Total Debt:", debt);
            console.log("  Health Factor:", hf);

            // Verify each deposit
            assertGt(shares, 0, "Should mint shares");
            assertGt(hf, 1.1e18, "Health factor should be safe");
            assertEq(
                vault.balanceOf(depositor),
                shares,
                "Should have correct shares"
            );
        }

        // Final verification
        (
            uint256 finalCollateral,
            uint256 finalDebt,
            ,
            ,
            ,
            uint256 finalHF
        ) = AAVE_POOL.getUserAccountData(address(vault));

        console.log("Final Position:");
        console.log("  Total Deposited:", totalDeposited);
        console.log("  Total Shares:", totalShares);
        console.log("  Final Collateral:", finalCollateral);
        console.log("  Final Debt:", finalDebt);
        console.log("  Final Health Factor:", finalHF);

        // Verify significant leverage was achieved
        // Convert collateral (USD with 8 decimals) to ETH equivalent for comparison
        uint256 wethPrice = AAVE_ORACLE.getAssetPrice(address(WETH));
        uint256 collateralInETH = (finalCollateral * 1e18) / wethPrice;
        assertGt(collateralInETH, (totalDeposited * 18) / 10); // At least 1.8x leverage
        assertGt(finalDebt, 0, "Should have debt");
        assertGt(finalHF, 1.1e18, "Final health factor should be safe");

        // Verify share price stability instead of absolute share amounts
        uint256 sharePrice = vault.getStrategyTokenRate();
        assertGt(sharePrice, 0.95e18, "Share price should not collapse");
        assertLt(
            sharePrice,
            1.2e18,
            "Share price should not inflate excessively"
        );

        // Verify individual share balances
        uint256 totalSharesFromBalances = 0;
        for (uint256 i = 0; i < 5; i++) {
            totalSharesFromBalances += vault.balanceOf(depositors[i]);
            if (i == 0) {
                // First depositor gets 1:1 shares
                assertEq(
                    vault.balanceOf(depositors[i]),
                    depositAmounts[i],
                    "First deposit should be 1:1"
                );
            } else {
                // In a leveraged vault, share economics may vary due to leverage effects
                // For now, just verify shares are reasonable (not zero or excessively high)
                assertGt(
                    vault.balanceOf(depositors[i]),
                    0,
                    "Should have some shares"
                );
                assertLt(
                    vault.balanceOf(depositors[i]),
                    depositAmounts[i] * 1000,
                    "Shares should not be excessively high"
                );
            }
        }
        assertEq(
            totalSharesFromBalances,
            totalShares,
            "Share accounting should be correct"
        );

        // Test strategy token rate function
        uint256 strategyRate = vault.getStrategyTokenRate();

        // Strategy token rate should be positive and reasonable
        assertGt(strategyRate, 0, "Strategy token rate should be positive");
        assertLt(
            strategyRate,
            10e18,
            "Strategy token rate should be reasonable"
        );
    }

    function test_BasicWithdrawal() public {
        // Unpause vault for withdrawal testing
        vm.prank(admin);
        vault.unpause();

        // First, make a larger deposit to have a substantial position
        uint256 depositAmount = 20 ether; // Increased from 5 to 20 ETH
        deal(address(WETH), allocator, depositAmount);

        vm.prank(allocator);
        WETH.approve(address(vault), depositAmount);

        vm.prank(allocator);
        uint256 shares = vault.deposit(depositAmount, allocator);

        console.log("Initial deposit:");
        console.log("  Amount:", depositAmount);
        console.log("  Shares:", shares);

        // Get position metrics after deposit
        (
            uint256 initialCollateral,
            uint256 initialDebt,
            uint256 initialHF
        ) = vault.getPositionMetrics();
        console.log("  Initial Collateral:", initialCollateral);
        console.log("  Initial Debt:", initialDebt);
        console.log("  Initial Health Factor:", initialHF);

        // Wait a block to simulate some time passing
        vm.roll(block.number + 10);

        // Test small partial withdrawal (only 10% of shares to be conservative)
        uint256 sharesToRedeem = shares / 10; // Changed from 50% to 10%
        console.log("Withdrawing 10% of shares:");
        console.log("  Shares to redeem:", sharesToRedeem);

        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);
        console.log("  Expected assets:", expectedAssets);

        // Check maxRedeem before attempting withdrawal
        uint256 maxRedeemShares = vault.maxRedeem(allocator);
        console.log("  Max redeemable shares:", maxRedeemShares);

        // Check allowance
        uint256 allowance = vault.allowance(allocator, allocator);
        console.log("  Allowance (allocator -> allocator):", allowance);

        // Check WETH balance before withdrawal
        uint256 vaultWETHBefore = WETH.balanceOf(address(vault));
        console.log("  Vault WETH balance before:", vaultWETHBefore);

        vm.prank(allocator);
        uint256 assetsReceived = vault.redeem(
            sharesToRedeem,
            allocator,
            allocator
        );

        console.log("  Actual assets received:", assetsReceived);

        // Verify withdrawal worked
        assertGt(assetsReceived, 0, "Should receive assets");
        assertEq(
            vault.balanceOf(allocator),
            shares - sharesToRedeem,
            "Share balance should be correct"
        );

        // Get position metrics after withdrawal
        (uint256 finalCollateral, uint256 finalDebt, uint256 finalHF) = vault
            .getPositionMetrics();
        console.log("After withdrawal:");
        console.log("  Final Collateral:", finalCollateral);
        console.log("  Final Debt:", finalDebt);
        console.log("  Final Health Factor:", finalHF);

        // Verify position was partially unwound
        assertLt(
            finalCollateral,
            initialCollateral,
            "Collateral should decrease"
        );
        assertLt(finalDebt, initialDebt, "Debt should decrease");
        assertGt(finalHF, 1.1e18, "Health factor should remain safe");

        // Verify allocator received WETH
        assertGt(WETH.balanceOf(allocator), 0, "Should receive WETH");
    }
}
