// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultCore} from "../../VaultCore.sol";
import {AaveV3Strategy} from "../../AaveV3Strategy.sol";

/**
 * @title Simple VaultCore Test
 * @notice Basic test to verify vault deployment and functionality
 */
contract VaultCoreSimpleTest is Test {
    VaultCore public vault;
    AaveV3Strategy public strategy;
    IERC20 public usdc;
    
    address public owner;
    address public user1;
    
    // Base Sepolia USDC address
    address constant USDC_ADDRESS = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    
    function setUp() public {
        // Set up basic addresses
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        
        // Try to fork Base Sepolia
        try vm.createSelectFork("https://sepolia.base.org") {
            console.log("Fork created successfully");
        } catch {
            console.log("Fork failed, using local network");
            // Skip fork-dependent tests
            return;
        }
        
        usdc = IERC20(USDC_ADDRESS);
        
        // Deploy vault
        vm.startPrank(owner);
        vault = new VaultCore(
            usdc,
            "Yield Nest USDC Vault",
            "ynUSDC",
            owner
        );
        
        console.log("Vault deployed at:", address(vault));
        console.log("Vault name:", vault.name());
        console.log("Vault symbol:", vault.symbol());
        
        vm.stopPrank();
    }

    function testVaultDeployment() public view {
        // Basic deployment checks
        assertEq(vault.name(), "Yield Nest USDC Vault");
        assertEq(vault.symbol(), "ynUSDC");
        assertEq(address(vault.asset()), USDC_ADDRESS);
        assertEq(vault.owner(), owner);
        
        // Check decimal offset
        assertEq(vault.decimals(), 9); // 6 (USDC) + 3 (offset) = 9
        
        console.log("Basic vault deployment test passed");
    }

    function testStrategyDeployment() public {
        if (address(usdc) == address(0)) {
            console.log("Skipping strategy test - no fork");
            return;
        }
        
        vm.startPrank(owner);
        
        // Deploy strategy
        strategy = new AaveV3Strategy(address(vault), USDC_ADDRESS);
        
        console.log("Strategy deployed at:", address(strategy));
        console.log("Strategy vault:", strategy.vault());
        console.log("Strategy asset:", strategy.asset());
        
        // Initialize strategy in vault
        vault.initStrategy(address(strategy));
        
        vm.stopPrank();
        
        // Verify strategy is set
        assertEq(address(vault.strategy()), address(strategy));
        
        console.log("Strategy deployment and initialization test passed");
    }

    function testBasicVaultFunctions() public {
        // Test basic view functions
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();
        
        console.log("Total assets:", totalAssets);
        console.log("Total supply:", totalSupply);
        
        // Test preview functions with zero amounts
        uint256 previewDeposit = vault.previewDeposit(0);
        uint256 previewMint = vault.previewMint(0);
        uint256 previewWithdraw = vault.previewWithdraw(0);
        uint256 previewRedeem = vault.previewRedeem(0);
        
        assertEq(previewDeposit, 0);
        assertEq(previewMint, 0);
        assertEq(previewWithdraw, 0);
        assertEq(previewRedeem, 0);
        
        console.log("Basic vault functions test passed");
    }

    function testInflationAttackCostEstimation() public view {
        // Test the inflation attack cost estimation function
        uint256 targetRatio = 2e18; // 2x ratio
        uint256 attackCost = vault.estimateInflationAttackCost(targetRatio);
        
        console.log("Estimated attack cost for 2x ratio:", attackCost);
        
        // With decimal offset of 3, attack should be very expensive
        assertGt(attackCost, 1000e6); // Should cost more than 1000 USDC
        
        console.log("Inflation attack cost estimation test passed");
    }
}
