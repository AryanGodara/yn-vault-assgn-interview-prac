// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

/**
 * @title Aave V3 Supply Test
 * @notice Focused test for WETH supply and wstETH borrowing on Ethereum mainnet
 *         Tests the core Aave operations for leverage looping strategy
 */
contract AaveV3SupplyTest is Test {
    // ============ Ethereum Mainnet Addresses ============
    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant wstETH =
        IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IPool public constant AAVE_POOL =
        IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAaveOracle public constant AAVE_ORACLE =
        IAaveOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);

    // ============ Test Setup ============
    address public testAccount = makeAddr("testAccount");
    uint256 public forkId;

    function setUp() public {
        // Fork Ethereum mainnet at recent block
        forkId = vm.createSelectFork(
            "https://eth-mainnet.g.alchemy.com/v2/p0Mcrc-7v8nMe2WqSYhi5lx789KlX3z8",
            23360000
        );
        assertEq(block.number, 23360000);

        // Fund test account with WETH (for collateral) and some wstETH (for repayment)
        deal(address(WETH), testAccount, 10 ether);
        deal(address(wstETH), testAccount, 1 ether); // Extra for interest coverage

        console.log("=== Aave V3 Supply Test Setup ===");
        console.log("Block number:", block.number);
        console.log("Chain ID:", block.chainid);
        console.log("Test account WETH balance:", WETH.balanceOf(testAccount));
    }

    /**
     * @notice Helper function to convert USD amounts to token amounts using Aave Oracle
     * @param usdAmount Amount in USD (8 decimals)
     * @param token Token address to convert to
     * @return Token amount in token's native decimals
     */
    function _convertUSDToTokenAmount(
        uint256 usdAmount,
        address token
    ) internal view returns (uint256) {
        uint256 tokenPrice = AAVE_ORACLE.getAssetPrice(token);
        // Both USD amount and price are in 8 decimals, so we need to add token decimals
        return
            (usdAmount * 10 ** IERC20Metadata(token).decimals()) / tokenPrice;
    }

    /**
     * @notice Test WETH supply to Aave V3
     * @dev Validates: WETH collateral supply for leverage strategy
     */
    function test_SupplyWETH() public {
        uint256 supplyAmount = 2 ether;
        uint256 initialBalance = WETH.balanceOf(testAccount);

        console.log("=== Starting WETH Supply Test ===");
        console.log("Supply amount:", supplyAmount);
        console.log("Initial WETH balance:", initialBalance);

        vm.startPrank(testAccount);

        // Step 1: Approve Aave pool to spend WETH
        WETH.approve(address(AAVE_POOL), supplyAmount);
        console.log("PASS: Approved Aave pool to spend WETH");

        // Step 2: Supply WETH to Aave
        AAVE_POOL.supply(
            address(WETH),
            supplyAmount,
            testAccount,
            0 // referral code
        );
        console.log("PASS: Supplied WETH to Aave");

        vm.stopPrank();

        // Step 3: Verify WETH was transferred from account
        uint256 finalBalance = WETH.balanceOf(testAccount);
        assertEq(
            finalBalance,
            initialBalance - supplyAmount,
            "WETH balance incorrect after supply"
        );
        console.log("PASS: WETH transferred correctly");
        console.log("Final WETH balance:", finalBalance);

        // Step 4: Verify Aave position was created
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        ) = AAVE_POOL.getUserAccountData(testAccount);

        // Validate collateral was registered
        assertGt(totalCollateralBase, 0, "No collateral recorded in Aave");
        console.log(
            "PASS: Collateral registered:",
            totalCollateralBase,
            "(base units)"
        );

        // Validate no debt exists
        assertEq(totalDebtBase, 0, "Unexpected debt recorded");
        console.log("PASS: No debt recorded (as expected)");

        // Validate borrowing capacity was created
        assertGt(availableBorrowsBase, 0, "No borrowing capacity available");
        console.log(
            "PASS: Borrowing capacity available:",
            availableBorrowsBase,
            "(base units)"
        );

        // Validate LTV configuration
        assertGt(ltv, 0, "LTV not configured");
        assertLt(ltv, 10000, "LTV should be less than 100%");
        console.log("PASS: LTV configured:", ltv, "basis points");

        console.log("=== WETH Supply Test PASSED ===");
    }

    /**
     * @notice Test borrowing wstETH against WETH collateral
     * @dev Uses 0.7 ratio to avoid liquidation risk
     */
    function test_BorrowWstETH() public {
        uint256 supplyAmount = 2 ether;

        vm.startPrank(testAccount);

        // Step 1: Supply WETH as collateral
        WETH.approve(address(AAVE_POOL), supplyAmount);
        AAVE_POOL.supply(address(WETH), supplyAmount, testAccount, 0);
        console.log("PASS: Supplied WETH collateral:", supplyAmount);

        // Step 2: Calculate safe borrow amount (70% of available) - FIXED VERSION
        (, , uint256 availableBorrowsUSD, , , ) = AAVE_POOL.getUserAccountData(
            testAccount
        );
        console.log("Available to borrow (USD):", availableBorrowsUSD / 1e8);

        // Calculate 70% of available in USD
        uint256 borrowAmountUSD = (availableBorrowsUSD * 7000) / 10000;
        console.log("Target borrow (USD):", borrowAmountUSD / 1e8);

        // Convert USD to wstETH amount using helper function
        uint256 borrowAmount = _convertUSDToTokenAmount(
            borrowAmountUSD,
            address(wstETH)
        );
        console.log("wstETH to borrow (ether):", borrowAmount);

        uint256 initialWstETH = wstETH.balanceOf(testAccount);

        // Step 3: Borrow wstETH
        AAVE_POOL.borrow(
            address(wstETH),
            borrowAmount,
            2, // variable interest rate mode
            0, // referral
            testAccount
        );
        console.log("PASS: Borrowed wstETH from Aave");

        vm.stopPrank();

        // Step 4: Verify wstETH was received
        uint256 finalWstETH = wstETH.balanceOf(testAccount);
        assertEq(
            finalWstETH,
            initialWstETH + borrowAmount,
            "wstETH not received correctly"
        );
        console.log("PASS: wstETH received:", finalWstETH);

        // Step 5: Verify debt position
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 newAvailableBorrowsBase,
            ,
            ,
            uint256 healthFactor
        ) = AAVE_POOL.getUserAccountData(testAccount);

        assertGt(totalCollateralBase, 0, "Collateral should exist");
        assertGt(totalDebtBase, 0, "Debt should be recorded");
        assertLt(
            newAvailableBorrowsBase,
            availableBorrowsUSD,
            "Available borrows should decrease"
        );
        // Health factor should be around 1.4-1.5 for 70% borrow, not millions
        assertGt(healthFactor, 1.2e18, "Health factor should be safe (>1.2)");
        assertLt(
            healthFactor,
            2e18,
            "Health factor should be reasonable (<2.0)"
        );

        console.log("PASS: Total Collateral:", totalCollateralBase);
        console.log("PASS: Total Debt:", totalDebtBase);
        console.log(
            "PASS: Health Factor:",
            (healthFactor * 100) / 1e18,
            "/ 100"
        );
        console.log("=== Borrow Test PASSED ===");
    }

    /**
     * @notice Test withdrawal (repayment and collateral withdrawal)
     * @dev Tests unwinding a position - simplified approach
     */
    function test_WithdrawAndRepay() public {
        uint256 supplyAmount = 2 ether;

        vm.startPrank(testAccount);

        // Step 1: Create position (supply + borrow)
        WETH.approve(address(AAVE_POOL), supplyAmount);
        AAVE_POOL.supply(address(WETH), supplyAmount, testAccount, 0);

        (, , uint256 availableBorrowsUSD, , , ) = AAVE_POOL.getUserAccountData(
            testAccount
        );

        // Convert USD to wstETH amount using helper function (50% ratio for safety)
        uint256 borrowAmountUSD = (availableBorrowsUSD * 5000) / 10000;
        uint256 borrowAmount = _convertUSDToTokenAmount(
            borrowAmountUSD,
            address(wstETH)
        );

        AAVE_POOL.borrow(address(wstETH), borrowAmount, 2, 0, testAccount);
        console.log("PASS: Created position - supplied WETH, borrowed wstETH");

        // Step 2: Repay exact borrowed amount (not max)
        wstETH.approve(address(AAVE_POOL), borrowAmount);

        AAVE_POOL.repay(
            address(wstETH),
            borrowAmount, // repay exact amount borrowed
            2, // variable rate
            testAccount
        );
        console.log("PASS: Repaid wstETH debt:", borrowAmount);

        // Step 3: Check debt status (may have small remainder due to interest)
        (, uint256 totalDebtBase, , , , uint256 healthFactor) = AAVE_POOL
            .getUserAccountData(testAccount);
        console.log("Remaining debt (base):", totalDebtBase);
        console.log("Health factor:", healthFactor);

        // Accept small debt remainder due to interest accrual
        assertLt(totalDebtBase, 1000, "Debt should be minimal"); // Allow small remainder
        assertGt(healthFactor, 100e18, "Health factor should be very high");

        // Step 4: Withdraw partial WETH collateral (leave some for any remaining debt)
        uint256 withdrawAmount = (supplyAmount * 8000) / 10000; // 80% of supplied
        uint256 initialWETH = WETH.balanceOf(testAccount);

        AAVE_POOL.withdraw(address(WETH), withdrawAmount, testAccount);
        console.log("PASS: Withdrew WETH collateral:", withdrawAmount);

        vm.stopPrank();

        // Step 5: Verify WETH was returned
        uint256 finalWETH = WETH.balanceOf(testAccount);
        assertEq(
            finalWETH,
            initialWETH + withdrawAmount,
            "WETH not returned correctly"
        );
        console.log("PASS: WETH returned:", finalWETH);

        // Step 6: Verify position is mostly closed
        (uint256 totalCollateralBase, , , , , ) = AAVE_POOL.getUserAccountData(
            testAccount
        );
        assertGt(
            totalCollateralBase,
            0,
            "Some collateral should remain for debt coverage"
        );

        console.log("PASS: Position partially unwound successfully");
        console.log("=== Withdraw/Repay Test PASSED ===");
    }
}
