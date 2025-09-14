// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

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
 * @notice Tests complete 5-loop leverage strategy: WETH supply → wstETH borrow → wstETH→WETH swap
 *         Implements corrected strategy with proper oracle price conversions
 */
contract LeverageLoopingTest is Test {
    // ============ Token Addresses ============
    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant wstETH =
        IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IERC20 public constant cbETH =
        IERC20(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704);
    IPool public constant AAVE_POOL =
        IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAaveOracle public constant AAVE_ORACLE =
        IAaveOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);
    ISwapRouter public constant UNISWAP_ROUTER =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    ICurvePool public constant CURVE_CBETH_ETH_POOL =
        ICurvePool(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A);

    // ============ Test Constants ============
    uint24 public constant POOL_FEE = 3000; // 0.3% for better liquidity
    uint256 public constant TARGET_BORROW_RATIO = 7000; // 70% for ~3x leverage
    uint256 constant SLIPPAGE_TOLERANCE = 100; // 1% for testing
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

        // Fund test account with WETH and some wstETH for interest coverage
        deal(address(WETH), testAccount, 100 ether);
        deal(address(wstETH), testAccount, 5 ether);

        // Pump massive liquidity into wstETH/WETH pools for testing
        _pumpPoolLiquidity();

        console.log("=== Leverage Looping Strategy Test Setup ===");
        console.log("Block number:", block.number);
        console.log("Chain ID:", block.chainid);
        console.log("Test account WETH balance:", WETH.balanceOf(testAccount));
        console.log("Loop count:", LOOP_COUNT);
        console.log("Target borrow ratio:", TARGET_BORROW_RATIO, "(70%)");
        console.log("Expected leverage: ~3x");
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
        console.log("Step 1: Supplied WETH as collateral:", initialWETH);

        // Step 2: Calculate borrow amount using oracle (FIXED)
        (, , uint256 availableBorrowsUSD, , , ) = AAVE_POOL.getUserAccountData(
            testAccount
        );
        uint256 borrowAmountUSD = (availableBorrowsUSD * TARGET_BORROW_RATIO) /
            10000;
        uint256 borrowAmount = _convertUSDToTokenAmount(
            borrowAmountUSD,
            address(wstETH)
        );

        console.log("Available to borrow (USD):", availableBorrowsUSD / 1e8);
        console.log("Target borrow (USD):", borrowAmountUSD / 1e8);
        console.log("wstETH to borrow:", borrowAmount);

        // Step 3: Borrow wstETH against WETH collateral (CORRECTED)
        AAVE_POOL.borrow(address(wstETH), borrowAmount, 2, 0, testAccount);
        console.log("Step 2: Borrowed wstETH:", borrowAmount);

        // Step 4: Swap wstETH -> WETH (CORRECTED DIRECTION)
        uint256 wethReceived = _swapwstETHToWETH(borrowAmount);
        console.log("Step 3: Swapped wstETH -> WETH:", wethReceived);

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

        console.log("=== COMPLETE 5-LOOP LEVERAGE STRATEGY ===");
        console.log("Initial WETH:", initialWETH);
        console.log("Target: ~3x leverage with 5 loops at 70% ratio");

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
        assertGt(healthFactor, 1.1e18, "Health factor should be safe");
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

        console.log("SUCCESS: Achieved target ~3x leverage!");
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
                address(wstETH)
            );

            console.log(
                "Available to borrow (USD):",
                availableBorrowsUSD / 1e8
            );
            console.log("wstETH to borrow:", borrowAmount);

            // 3. Borrow wstETH against WETH collateral (CORRECTED)
            AAVE_POOL.borrow(
                address(wstETH),
                borrowAmount,
                2, // variable interest rate mode
                0, // referral
                testAccount
            );

            // 4. Swap wstETH -> WETH for next loop (CORRECTED DIRECTION)
            if (i < LOOP_COUNT - 1) {
                collateralAmount = _swapwstETHToWETH(borrowAmount);
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
        assertGt(healthFactor, 1.1e18, "Health factor too low after looping");

        console.log("=== Looping Complete ===");
        console.log(
            "Final health factor:",
            (healthFactor * 100) / 1e18,
            "/ 100"
        );
    }

    function test_ExecuteLeverageLoops_5Loops() public {
        uint256 initialSupply = 10 ether;

        console.log("=== 5-Loop Leverage Strategy Test ===");
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

            // Convert USD to wstETH amount using oracle
            uint256 wstETHPrice = AAVE_ORACLE.getAssetPrice(address(wstETH));
            uint256 borrowAmount = (borrowAmountUSD * 1e18) / wstETHPrice;

            console.log("Borrowing:", borrowAmount / 1e18, "wstETH");

            // Borrow wstETH
            AAVE_POOL.borrow(address(wstETH), borrowAmount, 2, 0, testAccount);
            totalBorrowed += borrowAmount;

            // Swap wstETH to WETH
            uint256 wethReceived = _swapwstETHToWETH(borrowAmount);
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
        console.log("Total wstETH borrowed:", totalBorrowed / 1e18);
        console.log("Total WETH from swaps:", totalSwapped / 1e18);
        console.log("Final collateral (USD):", finalCollateralBase / 1e8);
        console.log("Final debt (USD):", finalDebtBase / 1e8);
        console.log("Final health factor:", finalHealthFactor / 1e18);
        console.log(
            "Effective leverage:",
            (finalCollateralBase * 1e18) / (initialSupply * 1e8)
        );

        vm.stopPrank();

        // Assertions
        assertGt(finalHealthFactor, 1.2e18, "Health factor should be safe");
        assertGt(
            finalCollateralBase,
            initialSupply * 1e8 * 2,
            "Should achieve >2x leverage"
        );
        assertLt(
            finalCollateralBase,
            initialSupply * 1e8 * 4,
            "Should not exceed 4x leverage"
        );
    }

    function test_ExecuteLeverageLoops_cbETH_SingleLoop() public {
        uint256 initialSupply = 10 ether;

        console.log("=== cbETH Single Loop Leverage Strategy Test ===");
        console.log("Initial WETH supply:", initialSupply / 1e18, "ETH");

        vm.startPrank(testAccount);

        // Initial supply
        WETH.approve(address(AAVE_POOL), initialSupply);
        AAVE_POOL.supply(address(WETH), initialSupply, testAccount, 0);

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
        uint256 borrowAmountUSD = (availableBorrowsBase * TARGET_BORROW_RATIO) /
            10000;

        // Convert USD to cbETH amount using oracle
        uint256 cbETHPrice = AAVE_ORACLE.getAssetPrice(address(cbETH));
        uint256 borrowAmount = (borrowAmountUSD * 1e18) / cbETHPrice;

        console.log("Borrowing:", borrowAmount / 1e18, "cbETH");
        console.log("cbETH price (USD):", cbETHPrice / 1e8);

        // Borrow cbETH
        AAVE_POOL.borrow(address(cbETH), borrowAmount, 2, 0, testAccount);

        // Swap cbETH to WETH using Curve
        uint256 wethReceived = _swapcbETHToWETH(borrowAmount);

        console.log("WETH received from Curve swap:", wethReceived / 1e18);

        // Supply the received WETH back to Aave
        WETH.approve(address(AAVE_POOL), wethReceived);
        AAVE_POOL.supply(address(WETH), wethReceived, testAccount, 0);

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
        console.log("cbETH borrowed:", borrowAmount / 1e18);
        console.log("WETH from swap:", wethReceived / 1e18);
        console.log("Final collateral (USD):", finalCollateralBase / 1e8);
        console.log("Final debt (USD):", finalDebtBase / 1e8);
        console.log("Final health factor:", finalHealthFactor / 1e18);
        console.log(
            "Leverage ratio:",
            (finalCollateralBase * 1e18) / (initialSupply * 1e8)
        );

        vm.stopPrank();

        // Assertions
        assertGt(finalHealthFactor, 1.2e18, "Health factor should be safe");
        assertGt(
            wethReceived,
            (borrowAmount * 90) / 100,
            "Should receive reasonable WETH amount"
        );
    }

    function _swapwstETHToWETH(
        uint256 wstETHAmount
    ) internal returns (uint256 wethReceived) {
        // wstETH is worth MORE than WETH (~1.21x based on staking rewards)
        // Use Aave oracle prices for accurate calculation
        uint256 wstETHPrice = AAVE_ORACLE.getAssetPrice(address(wstETH)); // $5,663
        uint256 wethPrice = AAVE_ORACLE.getAssetPrice(address(WETH)); // $4,666

        // Calculate expected output based on oracle prices
        uint256 expectedWETH = (wstETHAmount * wstETHPrice) / wethPrice;

        // Apply 2% slippage tolerance - should work well with pumped liquidity
        uint256 minOutput = (expectedWETH * 98) / 100;
        console.log("wstETH to swap:", wstETHAmount);
        console.log("wstETH price (USD):", wstETHPrice / 1e8);
        console.log("WETH price (USD):", wethPrice / 1e8);
        console.log("Expected WETH (oracle based):", expectedWETH);
        console.log("Min WETH with 2% slippage:", minOutput);

        // Approve Uniswap router to spend wstETH
        wstETH.approve(address(UNISWAP_ROUTER), wstETHAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: address(wstETH),
                tokenOut: address(WETH),
                fee: POOL_FEE, // Now using 0.3% pool for better liquidity
                recipient: testAccount,
                deadline: block.timestamp + 300,
                amountIn: wstETHAmount,
                amountOutMinimum: minOutput,
                sqrtPriceLimitX96: 0
            });

        wethReceived = UNISWAP_ROUTER.exactInputSingle(params);
        require(wethReceived > 0, "wstETH -> WETH swap failed");
        console.log("Actual WETH received:", wethReceived / 1e18);
        console.log(
            "Swap efficiency:",
            (wethReceived * 10000) / expectedWETH,
            "/ 10000"
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
    function _pumpPoolLiquidity() internal {
        console.log("=== Pumping Pool Liquidity ===");

        // Get the pool address for 0.3% fee tier
        address poolAddress = IUniswapV3Factory(
            0x1F98431c8aD98523631AE4a59f267346ea31F984
        ).getPool(address(wstETH), address(WETH), POOL_FEE);

        if (poolAddress == address(0)) {
            console.log("Pool doesn't exist for 0.3% fee tier");
            // Try 0.05% fee tier instead
            poolAddress = IUniswapV3Factory(
                0x1F98431c8aD98523631AE4a59f267346ea31F984
            ).getPool(address(wstETH), address(WETH), 500);

            if (poolAddress == address(0)) {
                console.log(
                    "No wstETH/WETH pool found, skipping liquidity pump"
                );
                return;
            } else {
                console.log("Using 0.05% fee tier pool");
            }
        }

        console.log("Pool address:", poolAddress);

        // Deal massive amounts directly to the pool (simple but effective for testing)
        uint256 massiveAmount = 50000 ether; // 50k tokens each

        console.log(
            "Current pool WETH balance:",
            WETH.balanceOf(poolAddress) / 1e18
        );
        console.log(
            "Current pool wstETH balance:",
            wstETH.balanceOf(poolAddress) / 1e18
        );

        // Add massive liquidity directly to pool
        deal(
            address(WETH),
            poolAddress,
            WETH.balanceOf(poolAddress) + massiveAmount
        );
        deal(
            address(wstETH),
            poolAddress,
            wstETH.balanceOf(poolAddress) + massiveAmount
        );

        console.log(
            "After pump WETH balance:",
            WETH.balanceOf(poolAddress) / 1e18
        );
        console.log(
            "After pump wstETH balance:",
            wstETH.balanceOf(poolAddress) / 1e18
        );
        console.log("=== Pool Liquidity Pumped ===");
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

    function _resetAccountState() internal {
        // Repay all debt and withdraw all collateral to reset for next test
        (uint256 collateral, uint256 debt, , , , ) = AAVE_POOL
            .getUserAccountData(testAccount);

        if (debt > 0) {
            vm.startPrank(testAccount);
            // Get fresh wstETH to repay debt (CORRECTED)
            deal(address(wstETH), testAccount, 10 ether);
            wstETH.approve(address(AAVE_POOL), type(uint256).max);
            AAVE_POOL.repay(address(wstETH), type(uint256).max, 2, testAccount);
            vm.stopPrank();
        }

        if (collateral > 0) {
            vm.startPrank(testAccount);
            AAVE_POOL.withdraw(address(WETH), type(uint256).max, testAccount);
            vm.stopPrank();
        }

        // Ensure fresh balances for next test
        deal(address(WETH), testAccount, 100 ether);
        deal(address(wstETH), testAccount, 5 ether);
    }
}
