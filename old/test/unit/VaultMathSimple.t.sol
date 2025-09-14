// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {VaultMath} from "../../libraries/VaultMath.sol";

contract VaultMathSimpleTest is Test {
    function testBasicConversions() public pure {
        uint256 shares = 1000e18;
        uint256 totalShares = 10000e18;
        uint256 totalAssets = 12000e18;

        uint256 assets = VaultMath.convertToAssets(shares, totalShares, totalAssets, false);

        // Should get approximately 1200e18 assets (1000/10000 * 12000)
        // With virtual offsets: (1000 * (12000 + 1)) / (10000 + 1e8) ≈ 1200
        assertApproxEqRel(assets, 1200e18, 1e15); // 0.1% tolerance
    }

    function testInflationAttackProtection() public pure {
        // Simulate classic inflation attack scenario
        uint256 attackerShares = 1; // Attacker deposits 1 wei
        uint256 totalShares = attackerShares; // Start with attacker's shares
        uint256 totalAssets = 1; // Attacker's initial deposit

        // Attacker tries to manipulate by donating assets directly (simulated by increasing totalAssets)
        uint256 attackerDonation = 1000e18;
        uint256 manipulatedAssets = totalAssets + attackerDonation;

        // Now a victim tries to deposit
        uint256 victimDeposit = 1000e18;
        uint256 victimShares = VaultMath.convertToShares(victimDeposit, totalShares, manipulatedAssets, false);

        // Without virtual offsets, victim would get very few shares
        // With virtual offsets (1e8 shares, 1 asset), the impact is minimized

        // The 1e8 virtual shares should dominate the calculation
        uint256 expectedShares = (victimDeposit * (totalShares + 1e8)) / (manipulatedAssets + 1);
        assertEq(victimShares, expectedShares);

        // Verify the virtual offset provides significant protection
        // The virtual offset should ensure victim gets close to 1e8 shares (the virtual offset amount)
        // This demonstrates the attack is neutralized
        assertApproxEqRel(victimShares, 1e8, 1e15); // Should be close to virtual offset amount

        // Test that attacker's advantage is minimal
        uint256 attackerAssetsAfter = VaultMath.convertToAssets(
            attackerShares, totalShares + victimShares, manipulatedAssets + victimDeposit, false
        );
        // Attacker shouldn't gain significantly more than their original deposit + donation
        assertTrue(attackerAssetsAfter <= attackerDonation + 10); // Allow small rounding
    }

    function testRoundingBehavior() public pure {
        uint256 shares = 333; // Amount that will cause rounding
        uint256 totalShares = 1000e18;
        uint256 totalAssets = 1000e18;

        uint256 assetsFloor = VaultMath.convertToAssets(shares, totalShares, totalAssets, false);
        uint256 assetsCeil = VaultMath.convertToAssets(shares, totalShares, totalAssets, true);

        // Ceiling should be >= floor
        assertTrue(assetsCeil >= assetsFloor);

        // If there's remainder, ceiling should be floor + 1
        uint256 virtualAssets = totalAssets + 1;
        uint256 virtualShares = totalShares + 1e8;
        if ((shares * virtualAssets) % virtualShares != 0) {
            assertEq(assetsCeil, assetsFloor + 1);
        }
    }

    function testZeroValues() public pure {
        // Zero shares should return zero assets
        uint256 assets = VaultMath.convertToAssets(0, 1000e18, 1000e18, false);
        assertEq(assets, 0);

        // Zero assets should return zero shares
        uint256 shares = VaultMath.convertToShares(0, 1000e18, 1000e18, false);
        assertEq(shares, 0);

        // Empty vault should still work due to virtual offsets
        shares = VaultMath.convertToShares(1000e18, 0, 0, false);
        assertTrue(shares > 0);
    }

    function testDepositSharesCalculation() public pure {
        uint256 assets = 1000e18;
        uint256 totalShares = 5000e18;
        uint256 totalAssets = 5000e18;

        uint256 shares = VaultMath.calculateDepositShares(assets, totalShares, totalAssets);

        // Should round down to favor protocol
        uint256 expected = VaultMath.convertToShares(assets, totalShares, totalAssets, false);
        assertEq(shares, expected);
    }

    function testWithdrawAssetsCalculation() public pure {
        uint256 shares = 1000e18;
        uint256 totalShares = 5000e18;
        uint256 totalAssets = 5000e18;

        uint256 assets = VaultMath.calculateWithdrawAssets(shares, totalShares, totalAssets);

        // Should round down to favor protocol
        uint256 expected = VaultMath.convertToAssets(shares, totalShares, totalAssets, false);

        // Allow for minimal rounding differences due to virtual offsets
        if (assets != expected) {
            uint256 diff = assets > expected ? assets - expected : expected - assets;
            assertTrue(diff <= 1); // At most 1 wei difference
        } else {
            assertEq(assets, expected);
        }
    }

    function testConsistency() public pure {
        uint256 amount = 1000e18;
        uint256 totalShares = 5000e18;
        uint256 totalAssets = 6000e18;

        // Convert amount to shares and back to assets
        uint256 shares = VaultMath.convertToShares(amount, totalShares, totalAssets, false);
        uint256 backToAssets = VaultMath.convertToAssets(shares, totalShares, totalAssets, false);

        // Due to rounding, backToAssets should be <= original amount
        assertTrue(backToAssets <= amount);

        // The difference should be minimal due to virtual offsets providing precision
        // Allow for larger tolerance due to virtual offset calculations
        if (amount > backToAssets) {
            uint256 diff = amount - backToAssets;
            // With virtual offsets, precision loss should be minimal relative to amount
            assertTrue(diff * 1e6 <= amount); // 0.0001% tolerance
        }
    }

    function testLargeNumbers() public pure {
        uint256 largeAmount = type(uint128).max;
        uint256 totalShares = largeAmount / 2;
        uint256 totalAssets = largeAmount / 2;

        // Should not revert with overflow
        uint256 shares = VaultMath.convertToShares(largeAmount / 4, totalShares, totalAssets, false);
        assertTrue(shares > 0);

        uint256 assets = VaultMath.convertToAssets(largeAmount / 4, totalShares, totalAssets, false);
        assertTrue(assets > 0);
    }
}
