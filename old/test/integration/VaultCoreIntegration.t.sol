// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultCore} from "../../VaultCore.sol";
import {AaveV3Strategy} from "../../AaveV3Strategy.sol";

/**
 * @title VaultCore Integration Test
 * @notice Tests the complete flow of VaultCore with AaveV3Strategy
 * @dev This test verifies basic deposit/withdraw functionality works end-to-end
 */
contract VaultCoreIntegrationTest is Test {
    VaultCore public vault;
    AaveV3Strategy public strategy;
    IERC20 public usdc;
    
    address public owner;
    address public user1;
    address public user2;
    
    // Base Sepolia USDC address
    address constant USDC_ADDRESS = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    
    // Rich USDC holder on Base Sepolia for testing
    address constant USDC_WHALE = 0x4c80E24119CFB836cdF0a6b53dc23F04F7e652CA;
    
    uint256 constant INITIAL_DEPOSIT = 1000e6; // 1000 USDC
    uint256 constant SMALL_DEPOSIT = 10e6;     // 10 USDC
    uint256 constant LARGE_DEPOSIT = 10000e6;  // 10000 USDC

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    function setUp() public {
        // Fork Base Sepolia for testing
        vm.createSelectFork("https://sepolia.base.org", 18_000_000);
        
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        usdc = IERC20(USDC_ADDRESS);
        
        // Deploy vault
        vm.startPrank(owner);
        vault = new VaultCore(
            usdc,
            "Yield Nest USDC Vault",
            "ynUSDC",
            owner
        );
        
        // Deploy strategy
        strategy = new AaveV3Strategy(address(vault), USDC_ADDRESS);
        
        // Initialize strategy in vault
        vault.initStrategy(address(strategy));
        vm.stopPrank();
        
        // Fund test users with USDC
        _fundUser(user1, INITIAL_DEPOSIT * 2);
        _fundUser(user2, INITIAL_DEPOSIT * 2);
    }

    function _fundUser(address user, uint256 amount) internal {
        vm.startPrank(USDC_WHALE);
        usdc.transfer(user, amount);
        vm.stopPrank();
        
        // Verify funding
        assertGe(usdc.balanceOf(user), amount, "User funding failed");
    }

    function testBasicDepositFlow() public {
        uint256 depositAmount = INITIAL_DEPOSIT;
        
        vm.startPrank(user1);
        
        // Approve vault to spend USDC
        usdc.approve(address(vault), depositAmount);
        
        // Record balances before
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 userSharesBefore = vault.balanceOf(user1);
        uint256 vaultTotalAssetsBefore = vault.totalAssets();
        
        // Perform deposit
        vm.expectEmit(true, true, false, true);
        emit Deposit(user1, user1, depositAmount, depositAmount * 1000); // 1000x due to decimal offset
        
        uint256 shares = vault.deposit(depositAmount, user1);
        
        // Verify balances after deposit
        assertEq(usdc.balanceOf(user1), userUsdcBefore - depositAmount, "User USDC balance incorrect");
        assertEq(vault.balanceOf(user1), userSharesBefore + shares, "User shares balance incorrect");
        assertEq(vault.totalAssets(), vaultTotalAssetsBefore + depositAmount, "Vault total assets incorrect");
        
        // Verify shares calculation (should be depositAmount * 1000 due to decimal offset)
        assertEq(shares, depositAmount * 1000, "Shares calculation incorrect");
        
        // Verify funds were allocated to strategy
        assertGt(strategy.totalAssets(), 0, "Strategy should have assets after deposit");
        
        console.log("Basic deposit test passed");
        console.log("   Deposited:", depositAmount);
        console.log("   Shares received:", shares);
        console.log("   Strategy assets:", strategy.totalAssets());
        
        vm.stopPrank();
    }

    function testBasicWithdrawFlow() public {
        // First deposit some funds
        uint256 depositAmount = INITIAL_DEPOSIT;
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Wait a bit to potentially accrue some yield
        vm.warp(block.timestamp + 1 hours);
        
        // Now test withdrawal
        uint256 withdrawAmount = depositAmount / 2; // Withdraw half
        
        vm.startPrank(user1);
        
        // Record balances before withdrawal
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 userSharesBefore = vault.balanceOf(user1);
        uint256 vaultTotalAssetsBefore = vault.totalAssets();
        
        // Perform withdrawal
        vm.expectEmit(true, true, true, false);
        emit Withdraw(user1, user1, user1, withdrawAmount, 0); // shares will be calculated
        
        uint256 sharesRedeemed = vault.withdraw(withdrawAmount, user1, user1);
        
        // Verify balances after withdrawal
        assertEq(usdc.balanceOf(user1), userUsdcBefore + withdrawAmount, "User USDC balance incorrect after withdraw");
        assertEq(vault.balanceOf(user1), userSharesBefore - sharesRedeemed, "User shares balance incorrect after withdraw");
        assertApproxEqAbs(vault.totalAssets(), vaultTotalAssetsBefore - withdrawAmount, 1, "Vault total assets incorrect after withdraw");
        
        console.log("Basic withdraw test passed");
        console.log("   Withdrew:", withdrawAmount);
        console.log("   Shares redeemed:", sharesRedeemed);
        console.log("   Remaining vault assets:", vault.totalAssets());
        
        vm.stopPrank();
    }

    function testMultipleUsersDepositWithdraw() public {
        uint256 user1Deposit = INITIAL_DEPOSIT;
        uint256 user2Deposit = SMALL_DEPOSIT;
        
        // User 1 deposits
        vm.startPrank(user1);
        usdc.approve(address(vault), user1Deposit);
        uint256 user1Shares = vault.deposit(user1Deposit, user1);
        vm.stopPrank();
        
        // User 2 deposits (different amount)
        vm.startPrank(user2);
        usdc.approve(address(vault), user2Deposit);
        uint256 user2Shares = vault.deposit(user2Deposit, user2);
        vm.stopPrank();
        
        // Verify total assets
        assertApproxEqAbs(vault.totalAssets(), user1Deposit + user2Deposit, 1, "Total assets should equal sum of deposits");
        
        // Verify share calculations are proportional
        uint256 expectedUser2Shares = (user2Deposit * user1Shares) / user1Deposit;
        assertApproxEqRel(user2Shares, expectedUser2Shares, 1e15, "User2 shares should be proportional"); // 0.1% tolerance
        
        // Both users withdraw their full amounts
        vm.startPrank(user1);
        uint256 user1Assets = vault.redeem(user1Shares, user1, user1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        uint256 user2Assets = vault.redeem(user2Shares, user2, user2);
        vm.stopPrank();
        
        // Verify they got back approximately what they put in (allowing for small rounding)
        assertApproxEqAbs(user1Assets, user1Deposit, 1, "User1 should get back their deposit");
        assertApproxEqAbs(user2Assets, user2Deposit, 1, "User2 should get back their deposit");
        
        console.log("Multiple users test passed");
        console.log("   User1 deposit/withdraw:", user1Deposit, "->", user1Assets);
        console.log("   User2 deposit/withdraw:", user2Deposit, "->", user2Assets);
    }

    function testInflationAttackProtection() public {
        // Simulate an inflation attack scenario
        address attacker = makeAddr("attacker");
        _fundUser(attacker, 1000000e6); // Fund attacker with 1M USDC
        
        vm.startPrank(attacker);
        
        // Attacker makes minimal deposit (1 wei)
        usdc.approve(address(vault), 1);
        uint256 attackerShares = vault.deposit(1, attacker);
        
        // Attacker tries to donate directly to strategy to manipulate exchange rate
        // This simulates the "donation" part of the attack
        uint256 donationAmount = 100000e6; // 100k USDC donation
        usdc.approve(address(strategy), donationAmount);
        usdc.transfer(address(strategy), donationAmount);
        
        vm.stopPrank();
        
        // Now a victim tries to deposit
        address victim = makeAddr("victim");
        _fundUser(victim, INITIAL_DEPOSIT);
        
        vm.startPrank(victim);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        uint256 victimShares = vault.deposit(INITIAL_DEPOSIT, victim);
        vm.stopPrank();
        
        // Due to decimal offset protection, victim should still get reasonable shares
        // The virtual offset should protect against the manipulation
        assertGt(victimShares, INITIAL_DEPOSIT * 900, "Victim should get reasonable shares despite attack"); // At least 90% of expected
        
        // Attacker shouldn't be able to steal significant value
        vm.startPrank(attacker);
        uint256 attackerAssets = vault.redeem(attackerShares, attacker, attacker);
        vm.stopPrank();
        
        // Attacker should not profit significantly from the attack
        assertLt(attackerAssets, donationAmount / 10, "Attacker should not profit significantly");
        
        console.log("Inflation attack protection test passed");
        console.log("   Attacker shares:", attackerShares);
        console.log("   Victim shares:", victimShares);
        console.log("   Attacker recovered:", attackerAssets);
    }

    function testSharePriceCalculation() public {
        // Test that share price calculation is accurate
        uint256 initialPrice = vault.getSharePrice();
        console.log("Initial share price:", initialPrice);
        
        // Make a deposit
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        // Share price should remain stable after deposit
        uint256 priceAfterDeposit = vault.getSharePrice();
        assertApproxEqRel(priceAfterDeposit, initialPrice, 1e15, "Share price should be stable after deposit"); // 0.1% tolerance
        
        // Simulate some yield by advancing time
        vm.warp(block.timestamp + 30 days);
        
        // Harvest to update yield
        vault.harvest();
        
        uint256 priceAfterYield = vault.getSharePrice();
        
        console.log("Share price test passed");
        console.log("   Initial price:", initialPrice);
        console.log("   After deposit:", priceAfterDeposit);
        console.log("   After yield:", priceAfterYield);
    }

    function testEmergencyFunctions() public {
        // Deposit some funds first
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        // Test emergency pause
        vm.startPrank(owner);
        vault.emergencyPause();
        
        // Deposits should be blocked
        vm.startPrank(user2);
        usdc.approve(address(vault), SMALL_DEPOSIT);
        vm.expectRevert();
        vault.deposit(SMALL_DEPOSIT, user2);
        vm.stopPrank();
        
        // But withdrawals should still work
        vm.startPrank(user1);
        uint256 withdrawAmount = INITIAL_DEPOSIT / 2;
        vault.withdraw(withdrawAmount, user1, user1);
        vm.stopPrank();
        
        // Unpause
        vm.startPrank(owner);
        vault.unpause();
        vm.stopPrank();
        
        // Deposits should work again
        vm.startPrank(user2);
        vault.deposit(SMALL_DEPOSIT, user2);
        vm.stopPrank();
        
        console.log("Emergency functions test passed");
    }

    function testPreviewFunctions() public {
        // Test preview functions accuracy
        uint256 depositAmount = INITIAL_DEPOSIT;
        
        // Preview deposit
        uint256 previewedShares = vault.previewDeposit(depositAmount);
        
        // Actual deposit
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        uint256 actualShares = vault.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Should match (within rounding tolerance)
        assertApproxEqAbs(actualShares, previewedShares, 1, "Preview deposit should match actual");
        
        // Preview withdrawal
        uint256 withdrawAmount = depositAmount / 2;
        uint256 previewedSharesForWithdraw = vault.previewWithdraw(withdrawAmount);
        
        // Actual withdrawal
        vm.startPrank(user1);
        uint256 actualSharesForWithdraw = vault.withdraw(withdrawAmount, user1, user1);
        vm.stopPrank();
        
        // Should match (within rounding tolerance)
        assertApproxEqAbs(actualSharesForWithdraw, previewedSharesForWithdraw, 1, "Preview withdraw should match actual");
        
        console.log("Preview functions test passed");
        console.log("   Preview vs actual deposit shares:", previewedShares, "vs", actualShares);
        console.log("   Preview vs actual withdraw shares:", previewedSharesForWithdraw, "vs", actualSharesForWithdraw);
    }

    function testFuzzDepositsAndWithdrawals(uint256 depositAmount) public {
        // Bound the fuzz input to reasonable values
        depositAmount = bound(depositAmount, 1e6, 100000e6); // 1 USDC to 100k USDC
        
        // Fund user with enough USDC
        _fundUser(user1, depositAmount);
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        
        // Deposit
        uint256 shares = vault.deposit(depositAmount, user1);
        assertGt(shares, 0, "Should receive shares for deposit");
        
        // Withdraw everything
        uint256 assetsReceived = vault.redeem(shares, user1, user1);
        
        // Should get back approximately what was deposited (allowing for minimal rounding)
        assertApproxEqAbs(assetsReceived, depositAmount, 2, "Should get back deposited amount");
        
        vm.stopPrank();
    }
}
