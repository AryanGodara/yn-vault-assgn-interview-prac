// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ICurvePool {
    // Crypto pool interface (cbETH/WETH uses uint256 parameters)
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/**
 * @title Curve cbETH/WETH Swap Test
 * @notice Tests cbETH to WETH swapping via Curve pools for leverage looping strategy
 */
contract CurveSwapTest is Test {
    // ============ Token Addresses ============
    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant cbETH =
        IERC20(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704);

    // ============ Curve Pool Addresses ============
    // cbETH/ETH Curve pool (the main one with good liquidity)
    ICurvePool public constant CURVE_CBETH_ETH_POOL =
        ICurvePool(0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A);

    // ============ Test Setup ============
    address public testAccount = makeAddr("testAccount");
    uint256 public forkId;

    function setUp() public {
        // Fork Ethereum mainnet at recent block
        forkId = vm.createSelectFork(
            "https://eth-mainnet.g.alchemy.com/v2/p0Mcrc-7v8nMe2WqSYhi5lx789KlX3z8"
        );
        console.log("Forked at block:", block.number);

        // Fund test account with WETH and cbETH
        deal(address(WETH), testAccount, 100 ether);
        deal(address(cbETH), testAccount, 100 ether);

        console.log("=== Curve cbETH/WETH Swap Test Setup ===");
        console.log("Block number:", block.number);
        console.log("Chain ID:", block.chainid);
        console.log(
            "Test account WETH balance:",
            WETH.balanceOf(testAccount) / 1e18,
            "ETH"
        );
        console.log(
            "Test account cbETH balance:",
            cbETH.balanceOf(testAccount) / 1e18,
            "cbETH"
        );
    }

    function test_CurvePoolInfo() public view {
        console.log("=== Curve Pool Information ===");
        console.log("Pool address:", address(CURVE_CBETH_ETH_POOL));
        console.log("cbETH address:", address(cbETH));
        console.log("WETH address:", address(WETH));

        // Get pool tokens
        address token0 = CURVE_CBETH_ETH_POOL.coins(0);
        address token1 = CURVE_CBETH_ETH_POOL.coins(1);

        console.log("Token 0 (coins):", token0);
        console.log("Token 1 (coins):", token1);

        // Based on the addresses, determine indices
        // Token 0 = WETH, Token 1 = cbETH
        console.log("WETH index: 0");
        console.log("cbETH index: 1");
    }

    function test_CbETHToWETHSwap_Simple() public {
        uint256 swapAmount = 0.01 ether; // 0.01 cbETH (similar to your example)

        vm.startPrank(testAccount);

        console.log("=== Simple cbETH -> WETH Swap Test ===");
        console.log("Swapping:", swapAmount, "wei cbETH");
        console.log("Swapping:", swapAmount / 1e18, "cbETH");

        uint256 initialWETH = WETH.balanceOf(testAccount);
        uint256 initialCbETH = cbETH.balanceOf(testAccount);

        console.log("Initial WETH balance:", initialWETH / 1e18);
        console.log("Initial cbETH balance:", initialCbETH / 1e18);

        // Based on your image showing exchange(1, 0, amount, min_dy), let's try that directly
        // Use very minimal slippage protection
        uint256 minOutput = 1; // Just require some output
        console.log("Using minimal output requirement:", minOutput, "wei");

        // Approve and swap
        cbETH.approve(address(CURVE_CBETH_ETH_POOL), type(uint256).max);
        console.log("Approved cbETH for pool");

        // Try the exact pattern from your image: exchange(1, 0, amount, min_dy)
        try CURVE_CBETH_ETH_POOL.exchange(1, 0, swapAmount, minOutput) returns (
            uint256 wethReceived
        ) {
            console.log("Swap successful! WETH received:", wethReceived, "wei");
            console.log(
                "Exchange rate:",
                (wethReceived * 1e18) / swapAmount,
                "WETH per cbETH (scaled by 1e18)"
            );

            uint256 finalWETH = WETH.balanceOf(testAccount);
            uint256 finalCbETH = cbETH.balanceOf(testAccount);

            console.log("Final WETH balance:", finalWETH / 1e18);
            console.log("Final cbETH balance:", finalCbETH / 1e18);
            console.log("WETH gained:", (finalWETH - initialWETH) / 1e18);
            console.log("cbETH spent:", (initialCbETH - finalCbETH) / 1e18);

            assertGt(wethReceived, 0, "Should receive some WETH");
            assertEq(
                finalWETH - initialWETH,
                wethReceived,
                "WETH balance should match received amount"
            );
            assertEq(
                initialCbETH - finalCbETH,
                swapAmount,
                "cbETH balance should match spent amount"
            );
        } catch Error(string memory reason) {
            console.log("Exchange failed with reason:", reason);
            revert("Swap failed");
        } catch (bytes memory lowLevelData) {
            console.log("Exchange failed with low-level error");
            console.logBytes(lowLevelData);
            revert("Swap failed with low-level error");
        }

        vm.stopPrank();
    }

    function test_CbETHToWETHSwap_Small() public {
        uint256 swapAmount = 1 ether; // 1 cbETH

        vm.startPrank(testAccount);

        console.log("=== Small cbETH -> WETH Swap Test ===");
        console.log("Swapping:", swapAmount / 1e18, "cbETH");

        uint256 wethReceived = _swapCbETHToWETH(swapAmount);

        console.log("WETH received:", wethReceived / 1e18, "ETH");
        console.log(
            "Exchange rate:",
            (wethReceived * 10000) / swapAmount,
            "/ 10000"
        );

        vm.stopPrank();

        assertGt(wethReceived, 0, "Should receive WETH");
        assertGt(
            wethReceived,
            (swapAmount * 90) / 100,
            "Should receive >90% of input"
        );
    }

    function test_CbETHToWETHSwap_Large() public {
        uint256 swapAmount = 10 ether; // 10 cbETH

        vm.startPrank(testAccount);

        console.log("=== Large cbETH -> WETH Swap Test ===");
        console.log("Swapping:", swapAmount / 1e18, "cbETH");

        uint256 wethReceived = _swapCbETHToWETH(swapAmount);

        console.log("WETH received:", wethReceived / 1e18, "ETH");
        console.log(
            "Exchange rate:",
            (wethReceived * 10000) / swapAmount,
            "/ 10000"
        );
        console.log(
            "Slippage:",
            10000 - (wethReceived * 10000) / swapAmount,
            "bps"
        );

        vm.stopPrank();

        assertGt(wethReceived, 0, "Should receive WETH");
        assertGt(
            wethReceived,
            (swapAmount * 85) / 100,
            "Should receive >85% of input"
        );
    }

    function test_WETHToCbETHSwap() public {
        uint256 swapAmount = 5 ether; // 5 WETH

        vm.startPrank(testAccount);

        console.log("=== WETH -> cbETH Swap Test ===");
        console.log("Swapping:", swapAmount / 1e18, "WETH");

        uint256 cbETHReceived = _swapWETHToCbETH(swapAmount);

        console.log("cbETH received:", cbETHReceived / 1e18, "cbETH");
        console.log(
            "Exchange rate:",
            (cbETHReceived * 10000) / swapAmount,
            "/ 10000"
        );

        vm.stopPrank();

        assertGt(cbETHReceived, 0, "Should receive cbETH");
        assertGt(
            cbETHReceived,
            (swapAmount * 90) / 100,
            "Should receive >90% of input"
        );
    }

    function test_RoundTripSwap() public {
        uint256 initialAmount = 5 ether;

        vm.startPrank(testAccount);

        console.log("=== Round Trip Swap Test ===");
        console.log("Starting with:", initialAmount / 1e18, "cbETH");

        // cbETH -> WETH
        uint256 wethReceived = _swapCbETHToWETH(initialAmount);
        console.log("After cbETH->WETH:", wethReceived / 1e18, "WETH");

        // WETH -> cbETH
        uint256 cbETHReceived = _swapWETHToCbETH(wethReceived);
        console.log("After WETH->cbETH:", cbETHReceived / 1e18, "cbETH");

        uint256 totalSlippage = initialAmount > cbETHReceived
            ? ((initialAmount - cbETHReceived) * 10000) / initialAmount
            : 0;
        console.log("Total round-trip slippage:", totalSlippage, "bps");

        vm.stopPrank();

        assertGt(
            cbETHReceived,
            (initialAmount * 95) / 100,
            "Round trip should lose <5%"
        );
    }

    // ============ Helper Functions ============

    function _swapCbETHToWETH(
        uint256 cbETHAmount
    ) internal returns (uint256 wethReceived) {
        // Get expected output from Curve
        uint256 expectedWETH = CURVE_CBETH_ETH_POOL.get_dy(
            1,
            0,
            cbETHAmount
        ); // cbETH=1, WETH=0
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

    function _swapWETHToCbETH(
        uint256 wethAmount
    ) internal returns (uint256 cbETHReceived) {
        // Get expected output from Curve
        uint256 expectedCbETH = CURVE_CBETH_ETH_POOL.get_dy(
            0,
            1,
            wethAmount
        ); // WETH=0, cbETH=1
        console.log("Expected cbETH from Curve:", expectedCbETH / 1e18);

        // Apply 10% slippage tolerance (90% target)
        uint256 minOutput = (expectedCbETH * 90) / 100;
        console.log("Min cbETH with 10% slippage:", minOutput / 1e18);

        // Approve Curve pool to spend WETH
        WETH.approve(address(CURVE_CBETH_ETH_POOL), wethAmount);

        // Execute swap: WETH (index 0) -> cbETH (index 1)
        cbETHReceived = CURVE_CBETH_ETH_POOL.exchange(
            0, // WETH index
            1, // cbETH index
            wethAmount,
            minOutput
        );

        require(cbETHReceived > 0, "WETH -> cbETH swap failed");
        console.log("Actual cbETH received:", cbETHReceived / 1e18);
        console.log(
            "Swap efficiency:",
            (cbETHReceived * 10000) / expectedCbETH,
            "/ 10000"
        );
    }
}
