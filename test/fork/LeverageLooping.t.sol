// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";

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
 * @title Leverage Looping Strategy Test
 * @notice Tests complete 5-loop leverage strategy: WETH supply → cbETH borrow → cbETH→WETH swap
 *         Uses Curve for cbETH/WETH swaps with proper price handling
 */
contract LeverageLoopingTest is Test {
    // ============ Token Addresses ============
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

    // ============ Test Constants ============
    uint256 public constant TARGET_BORROW_RATIO = 7000; // 70% for ~3x leverage
    uint256 public constant LOOP_COUNT = 5; // 5 loops for ~3x leverage

    // ============ Test Setup ============
    address public testAccount = makeAddr("testAccount");
    uint256 public forkId;

    // ============ Events ============
    event LeverageExecuted(
        uint256 initialAmount,
        uint256 finalCollateral,
        uint256 finalDebt,
        uint256 healthFactor
    );

    function setUp() public {
        // Fork Ethereum mainnet at recent block for better liquidity
        forkId = vm.createSelectFork(
            "https://eth-mainnet.g.alchemy.com/v2/p0Mcrc-7v8nMe2WqSYhi5lx789KlX3z8"
        );
        console.log("Forked at block:", block.number);

        // Fund test account with WETH and some cbETH for interest coverage
        deal(address(WETH), testAccount, 100 ether);
        deal(address(cbETH), testAccount, 5 ether);
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
        return
            (usdAmount * 10 ** IERC20Metadata(token).decimals()) / tokenPrice;
    }

    function test_ExecuteLeverageLoops_SingleLoop() public {
        uint256 initialWETH = 5 ether;

        vm.startPrank(testAccount);

        console.log("=== Single Loop Test: CORRECTED STRATEGY ===");
        console.log("Initial WETH:", initialWETH);

        // Step 1: Supply WETH as collateral (CORRECTED)
        WETH.approve(address(AAVE_POOL), initialWETH);
        AAVE_POOL.supply(address(WETH), initialWETH, testAccount, 0);

        // Step 2: Calculate borrow amount using oracle (FIXED)
        (, , uint256 availableBorrowsUSD, , , ) = AAVE_POOL.getUserAccountData(
            testAccount
        );
        uint256 borrowAmountUSD = (availableBorrowsUSD * TARGET_BORROW_RATIO) /
            10000;
        uint256 borrowAmount = _convertUSDToTokenAmount(
            borrowAmountUSD,
            address(cbETH)
        );

        console.log("Available to borrow (USD):", availableBorrowsUSD / 1e8);
        console.log("Target borrow (USD):", borrowAmountUSD / 1e8);
        console.log("cbETH to borrow:", borrowAmount);

        // Step 3: Borrow cbETH against WETH collateral (USING CURVE)
        AAVE_POOL.borrow(address(cbETH), borrowAmount, 2, 0, testAccount);
        console.log("Step 2: Borrowed cbETH:", borrowAmount);

        // Step 4: Swap cbETH -> WETH using Curve (CORRECTED DIRECTION)
        uint256 wethReceived = _swapcbETHToWETH(borrowAmount);
        console.log("Step 3: Swapped cbETH -> WETH:", wethReceived);

        _logAccountData();

        // Verify final state
        (, uint256 totalDebt, , , , uint256 healthFactor) = AAVE_POOL
            .getUserAccountData(testAccount);
        assertGt(totalDebt, 0, "Should have debt");
        assertGt(healthFactor, 1.2e18, "Health factor should be safe");
        assertLt(healthFactor, 2e18, "Health factor should be realistic");

        console.log("Health Factor:", (healthFactor * 100) / 1e18, "/ 100");
        vm.stopPrank();
    }

    function test_ExecuteLeverageLoops_Complete() public {
        uint256 initialWETH = 10 ether;

        vm.startPrank(testAccount);

        // Execute complete leverage loops with corrected strategy
        _executeLeverageLoops(initialWETH);

        vm.stopPrank();

        // Verify final position
        (
            uint256 totalCollateral,
            uint256 totalDebt,
            ,
            ,
            ,
            uint256 healthFactor
        ) = AAVE_POOL.getUserAccountData(testAccount);

        assertGt(totalCollateral, 0, "Should have collateral");
        assertGt(totalDebt, 0, "Should have debt");
        assertGt(healthFactor, 1.05e18, "Health factor should be safe");
        assertLt(healthFactor, 2e18, "Health factor should be realistic");

        // Calculate actual leverage achieved
        // totalCollateral is in USD (8 decimals), initialWETH is in wei (18 decimals)
        uint256 wethPriceUSD = AAVE_ORACLE.getAssetPrice(address(WETH));
        uint256 initialValueUSD = (initialWETH * wethPriceUSD) / 1e18;
        uint256 leverageRatio = (totalCollateral * 1e18) / initialValueUSD;

        console.log("=== FINAL LEVERAGE RESULTS ===");
        console.log("Initial WETH:", initialWETH / 1e18, "ETH");
        console.log("Final Collateral (USD):", totalCollateral / 1e8);
        console.log("Final Debt (USD):", totalDebt / 1e8);
        console.log("Health Factor:", (healthFactor * 100) / 1e18, "/ 100");
        console.log("Achieved Leverage:", leverageRatio / 1e16, "/ 100");

        // Should achieve close to 3x leverage (290-310)
        assertGt(leverageRatio, 250e16, "Should achieve >2.5x leverage");
        assertLt(leverageRatio, 350e16, "Should not exceed 3.5x leverage");
    }

    // ============ Helper Functions (CORRECTED STRATEGY) ============

    function _executeLeverageLoops(uint256 initialWETH) internal {
        if (initialWETH == 0) return;

        // CORRECTED STRATEGY: Start with WETH supply, not swap
        uint256 collateralAmount = initialWETH;

        for (uint256 i = 0; i < LOOP_COUNT; i++) {
            console.log("=== Loop", i + 1, "===");
            console.log("WETH to supply:", collateralAmount);

            // 1. Supply WETH as collateral (CORRECTED)
            WETH.approve(address(AAVE_POOL), collateralAmount);
            AAVE_POOL.supply(
                address(WETH),
                collateralAmount,
                testAccount,
                0 // referral code
            );

            // 2. Calculate borrow amount using oracle (FIXED)
            (, , uint256 availableBorrowsUSD, , , ) = AAVE_POOL
                .getUserAccountData(testAccount);
            uint256 borrowAmountUSD = (availableBorrowsUSD *
                TARGET_BORROW_RATIO) / 10000;
            uint256 borrowAmount = _convertUSDToTokenAmount(
                borrowAmountUSD,
                address(cbETH)
            );

            console.log(
                "Available to borrow (USD):",
                availableBorrowsUSD / 1e8
            );
            console.log("cbETH to borrow:", borrowAmount);

            // 3. Borrow cbETH against WETH collateral (USING CURVE)
            AAVE_POOL.borrow(
                address(cbETH),
                borrowAmount,
                2, // variable interest rate mode
                0, // referral
                testAccount
            );

            // 4. Swap cbETH -> WETH for next loop using Curve
            if (i < LOOP_COUNT - 1) {
                collateralAmount = _swapcbETHToWETH(borrowAmount);
                console.log("WETH received for next loop:", collateralAmount);
            } else {
                console.log("Final loop - no swap needed");
            }

            _logAccountData();
        }

        // Final validation
        (, , , , , uint256 healthFactor) = AAVE_POOL.getUserAccountData(
            testAccount
        );
        assertGt(healthFactor, 1.00e18, "Health factor too low after looping");

        console.log("=== Looping Complete ===");
        console.log(
            "Final health factor:",
            (healthFactor * 100) / 1e18,
            "/ 100"
        );
    }

    function test_ExecuteLeverageLoops_MultipleLoops() public {
        uint256 initialSupply = 10 ether;

        console.log("=== Multiple Loop Leverage Strategy Test ===");
        console.log("Initial WETH supply:", initialSupply / 1e18, "ETH");

        vm.startPrank(testAccount);

        // Initial supply
        WETH.approve(address(AAVE_POOL), initialSupply);
        AAVE_POOL.supply(address(WETH), initialSupply, testAccount, 0);

        uint256 totalBorrowed = 0;
        uint256 totalSwapped = 0;

        for (uint256 i = 0; i < LOOP_COUNT; i++) {
            console.log("\n--- Loop", i + 1, "---");

            // Get current account data
            (
                uint256 totalCollateralBase,
                uint256 totalDebtBase,
                uint256 availableBorrowsBase,
                ,
                ,
                uint256 healthFactor
            ) = AAVE_POOL.getUserAccountData(testAccount);

            console.log("Available borrows (USD):", availableBorrowsBase / 1e8);
            console.log("Health factor:", healthFactor / 1e18);

            // Calculate borrow amount (70% of available)
            uint256 borrowAmountUSD = (availableBorrowsBase *
                TARGET_BORROW_RATIO) / 10000;

            // Convert USD to cbETH amount using oracle
            uint256 cbETHPrice = AAVE_ORACLE.getAssetPrice(address(cbETH));
            uint256 borrowAmount = (borrowAmountUSD * 1e18) / cbETHPrice;

            console.log("Borrowing:", borrowAmount / 1e18, "cbETH");

            // Borrow cbETH
            AAVE_POOL.borrow(address(cbETH), borrowAmount, 2, 0, testAccount);
            totalBorrowed += borrowAmount;

            // Swap cbETH to WETH using Curve
            uint256 wethReceived = _swapcbETHToWETH(borrowAmount);
            totalSwapped += wethReceived;

            console.log("WETH received from swap:", wethReceived / 1e18);

            // Supply the received WETH back to Aave
            WETH.approve(address(AAVE_POOL), wethReceived);
            AAVE_POOL.supply(address(WETH), wethReceived, testAccount, 0);

            console.log("Supplied WETH back to Aave");
        }

        // Final account status
        (
            uint256 finalCollateralBase,
            uint256 finalDebtBase,
            ,
            ,
            ,
            uint256 finalHealthFactor
        ) = AAVE_POOL.getUserAccountData(testAccount);

        console.log("\n=== Final Results ===");
        console.log("Total cbETH borrowed:", totalBorrowed / 1e18);
        console.log("Total WETH from swaps:", totalSwapped / 1e18);
        console.log("Final collateral (USD):", finalCollateralBase / 1e8);
        console.log("Final debt (USD):", finalDebtBase / 1e8);
        console.log("Final health factor:", finalHealthFactor / 1e18);
        // Convert finalCollateralBase from USD (8 decimals) to ETH equivalent using WETH price
        uint256 wethPrice = AAVE_ORACLE.getAssetPrice(address(WETH)); // Price in USD with 8 decimals
        uint256 finalCollateralETH = (finalCollateralBase * 1e18) / wethPrice; // Convert to ETH with 18 decimals
        uint256 leverage = (finalCollateralETH * 1e18) / initialSupply; // Both in 18 decimals now
        
        console.log("Debug - finalCollateralBase (USD):", finalCollateralBase / 1e8);
        console.log("Debug - WETH price (USD):", wethPrice / 1e8);
        console.log("Debug - finalCollateralETH:", finalCollateralETH / 1e18);
        console.log("Debug - initialSupply (ETH):", initialSupply / 1e18);
        console.log("Debug - leverage raw:", leverage);
        console.log(
            "Effective leverage:",
            leverage / 1e15  // Show with 3 decimal places
        );

        vm.stopPrank();

        // Assertions
        assertGt(finalHealthFactor, 1.00e18, "Health factor should be safe");
        // Calculate leverage: finalCollateral (USD with 8 decimals) / initialSupply (ETH with 18 decimals)
        // Convert to same base: finalCollateralBase / 1e8 / (initialSupply / 1e18) = finalCollateralBase * 1e10 / initialSupply
        assertGt(
            leverage,
            2e18,
            "Should achieve >2x leverage"
        );
        assertLt(
            leverage,
            4e18,
            "Should not exceed 4x leverage"
        );
    }


    function _swapcbETHToWETH(
        uint256 cbETHAmount
    ) internal returns (uint256 wethReceived) {
        // Get expected output from Curve
        uint256 expectedWETH = CURVE_CBETH_ETH_POOL.get_dy(
            1, // cbETH index
            0, // WETH index
            cbETHAmount
        );
        console.log("Expected WETH from Curve:", expectedWETH / 1e18);

        // Apply 10% slippage tolerance (90% target)
        uint256 minOutput = (expectedWETH * 90) / 100;
        console.log("Min WETH with 10% slippage:", minOutput / 1e18);

        // Approve Curve pool to spend cbETH
        cbETH.approve(address(CURVE_CBETH_ETH_POOL), cbETHAmount);

        // Execute swap: cbETH (index 1) -> WETH (index 0)
        wethReceived = CURVE_CBETH_ETH_POOL.exchange(
            1, // cbETH index
            0, // WETH index
            cbETHAmount,
            minOutput
        );

        require(wethReceived > 0, "cbETH -> WETH swap failed");
        console.log("Actual WETH received:", wethReceived / 1e18);
        console.log(
            "Swap efficiency:",
            (wethReceived * 10000) / expectedWETH,
            "/ 10000"
        );
    }

    function _logAccountData() internal view {
        (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        ) = AAVE_POOL.getUserAccountData(testAccount);

        console.log("Collateral (USD):", totalCollateralBase / 1e8);
        console.log("Debt (USD):", totalDebtBase / 1e8);
        console.log("Available Borrows (USD):", availableBorrowsBase / 1e8);
        console.log("Health Factor:", (healthFactor * 100) / 1e18, "/ 100");
        console.log("---");
    }

}
