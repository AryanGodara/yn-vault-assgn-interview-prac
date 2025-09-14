// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

/**
 * @title Uniswap V3 Swap Component Test
 * @notice Tests WETH to wstETH swapping functionality in isolation
 */
contract UniswapV3SwapTest is Test {
    // ============ Base Mainnet Addresses ============
    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant wstETH =
        IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    ISwapRouter public constant UNISWAP_ROUTER =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    uint256 public constant SLIPPAGE_TOLERANCE = 100; // 1%

    // ============ Test Constants ============
    uint24 public constant POOL_FEE = 100; // 0.01% - confirmed from Etherscan

    // ============ Test Setup ============
    address public testAccount = makeAddr("testAccount");
    uint256 public forkId;

    function setUp() public {
        // Fork Base mainnet
        forkId = vm.createSelectFork(
            "https://eth-mainnet.g.alchemy.com/v2/p0Mcrc-7v8nMe2WqSYhi5lx789KlX3z8",
            23360000
        );
        assertEq(block.number, 23360000);

        // Fund test account with WETH
        deal(address(WETH), testAccount, 100 ether);

        console.log("=== Uniswap V3 Swap Test Setup ===");
        console.log("Test account WETH balance:", WETH.balanceOf(testAccount));
        console.log(
            "Test account wstETH balance:",
            wstETH.balanceOf(testAccount)
        );
    }

    function test_BasicSwap() public {
        uint256 swapAmount = 0.1 ether;
        uint256 amountOutMinimum = (swapAmount * (10000 - SLIPPAGE_TOLERANCE)) /
            10000;

        console.log("=== Basic WETH to wstETH Swap Test ===");
        console.log("Swap amount:", swapAmount);
        console.log("Pool fee:", POOL_FEE);

        // Step 1: Transfer WETH from testAccount to this contract (following Uniswap pattern)
        vm.prank(testAccount);
        WETH.transfer(address(this), swapAmount);

        uint256 initialWETH = WETH.balanceOf(testAccount);
        uint256 initialWstETH = wstETH.balanceOf(testAccount);

        console.log("Initial testAccount WETH balance:", initialWETH);
        console.log("Initial testAccount wstETH balance:", initialWstETH);
        console.log("Contract WETH balance:", WETH.balanceOf(address(this)));

        // Step 2: Approve the router to spend WETH from this contract
        WETH.approve(address(UNISWAP_ROUTER), type(uint256).max);

        // Step 3: Set up swap parameters
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: address(WETH),
                tokenOut: address(wstETH),
                fee: POOL_FEE,
                recipient: testAccount, // Send wstETH back to testAccount
                deadline: block.timestamp + 300,
                amountIn: swapAmount,
                amountOutMinimum: 0, // No slippage protection for testing
                sqrtPriceLimitX96: 0
            });

        // Step 4: Execute swap using SwapRouter02
        try UNISWAP_ROUTER.exactInputSingle(params) returns (
            uint256 wstETHReceived
        ) {
            console.log("SUCCESS! SwapRouter02 swap completed");
            console.log("WETH swapped:", swapAmount);
            console.log("wstETH received:", wstETHReceived);
            console.log(
                "Final testAccount WETH balance:",
                WETH.balanceOf(testAccount)
            );
            console.log(
                "Final testAccount wstETH balance:",
                wstETH.balanceOf(testAccount)
            );

            // Verify the swap worked
            assertGt(wstETHReceived, 0, "Should receive some wstETH");
            assertEq(
                wstETH.balanceOf(testAccount),
                initialWstETH + wstETHReceived,
                "wstETH should be received by testAccount"
            );
        } catch Error(string memory reason) {
            console.log("SwapRouter02 swap failed with reason:", reason);
            fail("Swap should not fail");
        } catch (bytes memory lowLevelData) {
            console.log("SwapRouter02 swap failed with low-level error");
            if (lowLevelData.length > 0) {
                console.logBytes(lowLevelData);
            }
            fail("Swap should not fail with low-level error");
        }
    }
}
