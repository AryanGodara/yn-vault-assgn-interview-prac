// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VaultCore} from "../../VaultCore.sol";

/**
 * @title Mock ERC20 Token for Testing
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1000000e6); // Mint 1M USDC to deployer
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title VaultCore Basic Test
 * @notice Tests basic vault functionality without external dependencies
 */
contract VaultCoreBasicTest is Test {
    VaultCore public vault;
    MockUSDC public usdc;
    
    address public owner;
    address public user1;
    address public user2;
    
    uint256 constant INITIAL_DEPOSIT = 1000e6; // 1000 USDC
    uint256 constant SMALL_DEPOSIT = 10e6;     // 10 USDC

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        // Deploy mock USDC
        usdc = new MockUSDC();
        
        // Deploy vault
        vm.startPrank(owner);
        vault = new VaultCore(
            usdc,
            "Yield Nest USDC Vault",
            "ynUSDC",
            owner
        );
        vm.stopPrank();
        
        // Fund test users
        usdc.mint(user1, INITIAL_DEPOSIT * 10);
        usdc.mint(user2, INITIAL_DEPOSIT * 10);
        
        console.log("Setup complete:");
        console.log("  Vault:", address(vault));
        console.log("  USDC:", address(usdc));
        console.log("  User1 balance:", usdc.balanceOf(user1));
    }

    function testBasicDepositWithoutStrategy() public {
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
        
        console.log("Basic deposit test passed");
        console.log("  Deposited:", depositAmount);
        console.log("  Shares received:", shares);
        console.log("  Share price:", vault.getSharePrice());
        
        vm.stopPrank();
    }

    function testBasicWithdrawWithoutStrategy() public {
        // First deposit some funds
        uint256 depositAmount = INITIAL_DEPOSIT;
        
        vm.startPrank(user1);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user1);
        vm.stopPrank();
        
        // Now test withdrawal
        uint256 withdrawAmount = depositAmount / 2; // Withdraw half
        
        vm.startPrank(user1);
        
        // Record balances before withdrawal
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 userSharesBefore = vault.balanceOf(user1);
        uint256 vaultTotalAssetsBefore = vault.totalAssets();
        
        // Perform withdrawal
        uint256 sharesRedeemed = vault.withdraw(withdrawAmount, user1, user1);
        
        // Verify balances after withdrawal
        assertEq(usdc.balanceOf(user1), userUsdcBefore + withdrawAmount, "User USDC balance incorrect after withdraw");
        assertEq(vault.balanceOf(user1), userSharesBefore - sharesRedeemed, "User shares balance incorrect after withdraw");
        assertEq(vault.totalAssets(), vaultTotalAssetsBefore - withdrawAmount, "Vault total assets incorrect after withdraw");
        
        console.log("Basic withdraw test passed");
        console.log("  Withdrew:", withdrawAmount);
        console.log("  Shares redeemed:", sharesRedeemed);
        console.log("  Remaining shares:", vault.balanceOf(user1));
        
        vm.stopPrank();
    }

    function testMultipleUsersDepositWithdraw() public {
        uint256 user1Deposit = INITIAL_DEPOSIT;
        uint256 user2Deposit = SMALL_DEPOSIT;
        
        // User 1 deposits first (gets initial rate)
        vm.startPrank(user1);
        usdc.approve(address(vault), user1Deposit);
        uint256 user1Shares = vault.deposit(user1Deposit, user1);
        vm.stopPrank();
        
        // User 2 deposits (should get same rate)
        vm.startPrank(user2);
        usdc.approve(address(vault), user2Deposit);
        uint256 user2Shares = vault.deposit(user2Deposit, user2);
        vm.stopPrank();
        
        // Verify total assets
        assertEq(vault.totalAssets(), user1Deposit + user2Deposit, "Total assets should equal sum of deposits");
        
        // Verify share calculations are proportional
        uint256 expectedUser2Shares = (user2Deposit * user1Shares) / user1Deposit;
        assertEq(user2Shares, expectedUser2Shares, "User2 shares should be proportional");
        
        // Both users withdraw their full amounts
        vm.startPrank(user1);
        uint256 user1Assets = vault.redeem(user1Shares, user1, user1);
        vm.stopPrank();
        
        vm.startPrank(user2);
        uint256 user2Assets = vault.redeem(user2Shares, user2, user2);
        vm.stopPrank();
        
        // Verify they got back exactly what they put in
        assertEq(user1Assets, user1Deposit, "User1 should get back their deposit");
        assertEq(user2Assets, user2Deposit, "User2 should get back their deposit");
        
        console.log("Multiple users test passed");
        console.log("  User1 deposit/withdraw:", user1Deposit, "->", user1Assets);
        console.log("  User2 deposit/withdraw:", user2Deposit, "->", user2Assets);
    }

    function testInflationAttackProtection() public {
        // Simulate an inflation attack scenario
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 1000000e6); // Fund attacker with 1M USDC
        
        vm.startPrank(attacker);
        
        // Attacker makes minimal deposit (1 wei)
        usdc.approve(address(vault), 1);
        uint256 attackerShares = vault.deposit(1, attacker);
        
        // Attacker tries to donate directly to vault to manipulate exchange rate
        uint256 donationAmount = 100000e6; // 100k USDC donation
        usdc.transfer(address(vault), donationAmount);
        
        vm.stopPrank();
        
        // Now a victim tries to deposit
        address victim = makeAddr("victim");
        usdc.mint(victim, INITIAL_DEPOSIT);
        
        vm.startPrank(victim);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        uint256 victimShares = vault.deposit(INITIAL_DEPOSIT, victim);
        vm.stopPrank();
        
        // Due to decimal offset protection, victim should still get reasonable shares
        // The virtual offset should protect against the manipulation
        assertGt(victimShares, INITIAL_DEPOSIT * 900, "Victim should get reasonable shares despite attack");
        
        // Attacker shouldn't be able to steal significant value
        vm.startPrank(attacker);
        uint256 attackerAssets = vault.redeem(attackerShares, attacker, attacker);
        vm.stopPrank();
        
        // Attacker should not profit significantly from the attack
        assertLt(attackerAssets, donationAmount / 100, "Attacker should not profit significantly");
        
        console.log("Inflation attack protection test passed");
        console.log("  Attacker donation:", donationAmount);
        console.log("  Attacker shares:", attackerShares);
        console.log("  Victim shares:", victimShares);
        console.log("  Attacker recovered:", attackerAssets);
        console.log("  Attack profit:", attackerAssets > 1 ? attackerAssets - 1 : 0);
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
        
        // Should match exactly
        assertEq(actualShares, previewedShares, "Preview deposit should match actual");
        
        // Preview withdrawal
        uint256 withdrawAmount = depositAmount / 2;
        uint256 previewedSharesForWithdraw = vault.previewWithdraw(withdrawAmount);
        
        // Actual withdrawal
        vm.startPrank(user1);
        uint256 actualSharesForWithdraw = vault.withdraw(withdrawAmount, user1, user1);
        vm.stopPrank();
        
        // Should match exactly
        assertEq(actualSharesForWithdraw, previewedSharesForWithdraw, "Preview withdraw should match actual");
        
        console.log("Preview functions test passed");
        console.log("  Preview vs actual deposit shares:", previewedShares, "vs", actualShares);
        console.log("  Preview vs actual withdraw shares:", previewedSharesForWithdraw, "vs", actualSharesForWithdraw);
    }

    function testDecimalOffsetProtection() public {
        // Test that the decimal offset provides the expected protection
        assertEq(vault.decimals(), 9, "Vault should have 9 decimals (6 + 3 offset)");
        
        // Small deposit should still get reasonable shares due to offset
        uint256 smallDeposit = 1e6; // 1 USDC
        
        vm.startPrank(user1);
        usdc.approve(address(vault), smallDeposit);
        uint256 shares = vault.deposit(smallDeposit, user1);
        vm.stopPrank();
        
        // Should get 1000 shares (1e6 * 1000 due to offset)
        assertEq(shares, smallDeposit * 1000, "Small deposit should get proportional shares");
        
        console.log("Decimal offset protection test passed");
        console.log("  Small deposit:", smallDeposit);
        console.log("  Shares received:", shares);
        console.log("  Effective multiplier:", shares / smallDeposit);
    }

    function testEmergencyPause() public {
        // Deposit some funds first
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        // Test emergency pause
        vm.startPrank(owner);
        vault.emergencyPause();
        vm.stopPrank();
        
        // Deposits should be blocked
        vm.startPrank(user2);
        usdc.approve(address(vault), SMALL_DEPOSIT);
        vm.expectRevert();
        vault.deposit(SMALL_DEPOSIT, user2);
        vm.stopPrank();
        
        // But withdrawals should still work
        vm.startPrank(user1);
        vault.withdraw(INITIAL_DEPOSIT / 2, user1, user1);
        vm.stopPrank();
        
        // Unpause
        vm.startPrank(owner);
        vault.unpause();
        vm.stopPrank();
        
        // Deposits should work again
        vm.startPrank(user2);
        vault.deposit(SMALL_DEPOSIT, user2);
        vm.stopPrank();
        
        console.log("Emergency pause test passed");
    }
}
