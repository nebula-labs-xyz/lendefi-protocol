// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";

contract GetTierRatesTest is BasicDeploy {
    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);
    }

    function test_GetTierRates_InitialRates() public {
        // Call the getTierRates function
        (uint256[4] memory jumpRates, uint256[4] memory liquidationFees) = assetsInstance.getTierRates();

        // Verify the initial borrow rates match what's set in the initialize function
        assertEq(jumpRates[3], 0.15e6, "ISOLATED borrow rate should be 15%");
        assertEq(jumpRates[2], 0.12e6, "CROSS_B borrow rate should be 8%");
        assertEq(jumpRates[1], 0.08e6, "CROSS_A borrow rate should be 12%");
        assertEq(jumpRates[0], 0.05e6, "STABLE borrow rate should be 5%");

        // Verify the initial liquidation bonuses match what's set in the initialize function
        assertEq(liquidationFees[3], 0.04e6, "ISOLATED liquidation bonus should be 6%");
        assertEq(liquidationFees[2], 0.03e6, "CROSS_B liquidation bonus should be 8%");
        assertEq(liquidationFees[1], 0.02e6, "CROSS_A liquidation bonus should be 10%");
        assertEq(liquidationFees[0], 0.01e6, "STABLE liquidation bonus should be 5%");
    }

    function test_GetTierRates_AfterUpdate() public {
        // Get initial rates for comparison
        (uint256[4] memory initialjumpRates, uint256[4] memory initialliquidationFees) = assetsInstance.getTierRates();

        // Update some tier parameters
        vm.startPrank(address(timelockInstance));

        // Update ISOLATED tier
        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.ISOLATED,
            0.2e6, // Change from 15% to 20%
            0.07e6 // Change from 4% to 7%
        );

        // Update STABLE tier
        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.STABLE,
            0.06e6, // Change from 5% to 6%
            0.03e6 // Change from 1% to 3%
        );

        vm.stopPrank();

        // Call getTierRates again to get the updated rates
        (uint256[4] memory newjumpRates, uint256[4] memory newliquidationFees) = assetsInstance.getTierRates();

        // Verify updated rates for ISOLATED tier - ISOLATED is at index 3
        assertEq(newjumpRates[3], 0.2e6, "ISOLATED borrow rate should be updated to 20%");
        assertEq(newliquidationFees[3], 0.07e6, "ISOLATED liquidation bonus should be updated to 7%");

        // Verify updated rates for STABLE tier - STABLE is at index 0
        assertEq(newjumpRates[0], 0.06e6, "STABLE borrow rate should be updated to 6%");
        assertEq(newliquidationFees[0], 0.03e6, "STABLE liquidation bonus should be updated to 3%");

        // Verify rates for tiers we didn't update remain the same
        assertEq(newjumpRates[1], initialjumpRates[1], "CROSS_A borrow rate should remain unchanged");
        assertEq(newjumpRates[2], initialjumpRates[2], "CROSS_B borrow rate should remain unchanged");
        assertEq(newliquidationFees[1], initialliquidationFees[1], "CROSS_A liquidation bonus should remain unchanged");
        assertEq(newliquidationFees[2], initialliquidationFees[2], "CROSS_B liquidation bonus should remain unchanged");
    }

    function test_GetTierRates_CorrectMapping() public {
        // We'll update each tier with unique values and then check the array positions
        vm.startPrank(address(timelockInstance));

        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.ISOLATED,
            0.1e6, // Unique value for ISOLATED
            0.09e6
        );

        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.CROSS_A,
            0.12e6, // Unique value for CROSS_A
            0.07e6
        );

        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.CROSS_B,
            0.14e6, // Unique value for CROSS_B
            0.05e6
        );

        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.STABLE,
            0.16e6, // Unique value for STABLE
            0.03e6
        );

        vm.stopPrank();

        // Get updated rates
        (uint256[4] memory updatedjumpRates, uint256[4] memory updatedliquidationFees) = assetsInstance.getTierRates();

        // Verify the mapping of tiers to array indices is correct
        // The correct mapping according to getTierRates implementation:
        assertEq(updatedjumpRates[3], 0.1e6, "ISOLATED should be at index 3");
        assertEq(updatedjumpRates[2], 0.14e6, "CROSS_B should be at index 2");
        assertEq(updatedjumpRates[1], 0.12e6, "CROSS_A should be at index 1");
        assertEq(updatedjumpRates[0], 0.16e6, "STABLE should be at index 0");

        assertEq(updatedliquidationFees[3], 0.09e6, "ISOLATED liquidation fee should be at index 3");
        assertEq(updatedliquidationFees[2], 0.05e6, "CROSS_B liquidation fee should be at index 2");
        assertEq(updatedliquidationFees[1], 0.07e6, "CROSS_A liquidation fee should be at index 1");
        assertEq(updatedliquidationFees[0], 0.03e6, "STABLE liquidation fee should be at index 0");
    }
}
