// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {ILendefiAssets} from "../../../contracts/interfaces/ILendefiAssets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract InitializeTest is BasicDeploy {
    Lendefi internal lendefiInstance;
    bytes internal data;

    function setUp() public {
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        data = abi.encodeCall(
            Lendefi.initialize,
            (
                address(usdcInstance),
                address(tokenInstance),
                address(ecoInstance),
                address(treasuryInstance),
                address(timelockInstance),
                address(yieldTokenInstance),
                address(assetsInstance),
                guardian
            )
        );
    }

    function test_InitializeSuccess() public {
        // Deploy Lendefi
        address payable proxy = payable(Upgrades.deployUUPSProxy("Lendefi.sol", data));
        LendefiInstance = Lendefi(proxy);

        // Check roles assignment - UPDATED to match contract implementation
        assertTrue(LendefiInstance.hasRole(0x00, address(timelockInstance)), "Timelock not assigned DEFAULT_ADMIN_ROLE");
        assertTrue(LendefiInstance.hasRole(keccak256("PAUSER_ROLE"), guardian), "Guardian not assigned PAUSER_ROLE");
        assertTrue(
            LendefiInstance.hasRole(keccak256("MANAGER_ROLE"), address(timelockInstance)),
            "Timelock not assigned MANAGER_ROLE"
        );
        assertTrue(LendefiInstance.hasRole(keccak256("UPGRADER_ROLE"), guardian), "Guardian not assigned UPGRADER_ROLE");

        // Check default parameters using the mainConfig struct
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // Verify config values
        assertEq(config.rewardAmount, 2_000 ether, "Incorrect rewardAmount");
        assertEq(config.rewardInterval, 180 days, "Incorrect rewardInterval");
        assertEq(config.rewardableSupply, 100_000 * 1e6, "Incorrect rewardableSupply");
        assertEq(config.borrowRate, 0.06e6, "Incorrect borrowRate");
        assertEq(config.profitTargetRate, 0.01e6, "Incorrect profitTargetRate");
        assertEq(config.liquidatorThreshold, 20_000 ether, "Incorrect liquidatorThreshold");
        assertEq(config.flashLoanFee, 9, "Incorrect flashLoanFee");

        // Check tier parameters
        (uint256[4] memory jumpRates, uint256[4] memory LiquidationFees) = assetsInstance.getTierRates();

        // Check borrow rates
        assertEq(jumpRates[3], 0.15e6, "Incorrect ISOLATED borrow rate");
        assertEq(jumpRates[2], 0.12e6, "Incorrect CROSS_B borrow rate");
        assertEq(jumpRates[1], 0.08e6, "Incorrect CROSS_A borrow rate");
        assertEq(jumpRates[0], 0.05e6, "Incorrect STABLE borrow rate");

        // Check liquidation bonuses
        assertEq(LiquidationFees[3], 0.04e6, "Incorrect ISOLATED liquidation bonus");
        assertEq(LiquidationFees[2], 0.03e6, "Incorrect CROSS_A liquidation bonus");
        assertEq(LiquidationFees[1], 0.02e6, "Incorrect CROSS_B liquidation bonus");
        assertEq(LiquidationFees[0], 0.01e6, "Incorrect STABLE liquidation bonus");

        // Check version increment
        assertEq(LendefiInstance.version(), 1, "Version not incremented");

        // Check treasury and timelock addresses
        assertEq(LendefiInstance.treasury(), address(treasuryInstance), "Treasury address not set correctly");
    }

    function test_InitialStateIsEmpty() public {
        // Deploy new logic contract
        LendefiInstance = new Lendefi();

        // Check initial state before initialization
        assertEq(LendefiInstance.version(), 0, "Version should be 0 before initialization");
        assertEq(LendefiInstance.totalBorrow(), 0, "totalBorrow should be 0 before initialization");
        assertEq(
            LendefiInstance.totalSuppliedLiquidity(), 0, "totalSuppliedLiquidity should be 0 before initialization"
        );
        assertEq(
            LendefiInstance.totalAccruedBorrowerInterest(), 0, "totalAccruedInterest should be 0 before initialization"
        );
    }

    function test_RoleAssignments() public {
        // Calculate the expected role hashes directly
        bytes32 pauserRole = keccak256("PAUSER_ROLE");
        bytes32 managerRole = keccak256("MANAGER_ROLE");
        bytes32 upgraderRole = keccak256("UPGRADER_ROLE");
        bytes32 defaultAdminRole = 0x00;

        address payable proxy = payable(Upgrades.deployUUPSProxy("Lendefi.sol", data));
        LendefiInstance = Lendefi(proxy);

        // UPDATED: Check that roles are properly assigned to the right addresses
        assertTrue(
            LendefiInstance.hasRole(defaultAdminRole, address(timelockInstance)), "Timelock should have admin role"
        );
        assertTrue(LendefiInstance.hasRole(pauserRole, guardian), "Guardian should have pauser role");
        assertTrue(LendefiInstance.hasRole(managerRole, address(timelockInstance)), "Timelock should have manager role");
        assertTrue(LendefiInstance.hasRole(upgraderRole, guardian), "Guardian should have upgrader role");

        // UPDATED: Verify negative cases - addresses that shouldn't have roles
        assertFalse(LendefiInstance.hasRole(managerRole, guardian), "Guardian should not have manager role");
        assertFalse(LendefiInstance.hasRole(defaultAdminRole, guardian), "Guardian should not have admin role");
        assertFalse(
            LendefiInstance.hasRole(upgraderRole, address(timelockInstance)), "Timelock should not have upgrader role"
        );
        assertFalse(
            LendefiInstance.hasRole(pauserRole, address(timelockInstance)), "Timelock should not have pauser role"
        );
    }

    function test_InitializationDecimalPrecision() public {
        // Deploy Lendefi with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("Lendefi.sol", data));
        LendefiInstance = Lendefi(proxy);

        // Verify exact decimal precision of initialized values
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();
        assertEq(config.borrowRate, 60_000, "borrowRate should be 0.06e6 = 60000");
        assertEq(config.profitTargetRate, 10_000, "profitTargetRate should be 0.01e6 = 10000");

        (uint256[4] memory jumpRates, uint256[4] memory liquidationFees) = assetsInstance.getTierRates();

        // CORRECTED: The array indices are reversed in getTierRates()
        // ISOLATED is at index 3, STABLE is at index 0
        assertEq(jumpRates[3], 0.15e6, "ISOLATED rate should be 0.15e6");
        assertEq(liquidationFees[3], 0.04e6, "ISOLATED liquidation fee should be 0.04e6");

        // Check stable rates directly
        assertEq(jumpRates[0], 0.05e6, "STABLE rate should be 0.05e6 = 50000");
        assertEq(liquidationFees[0], 0.01e6, "STABLE liquidation fee should be 0.01e6 = 10000");
    }

    // Test that uninitialized contracts have expected default values
    function test_UninitializedHasCorrectDefaults() public {
        Lendefi uninitializedContract = new Lendefi();

        assertEq(uninitializedContract.treasury(), address(0), "Treasury should be zero address before init");
    }

    // Test that initialization properly sets up protocol parameters for each tier
    function test_InitializationSetsAllTierParameters() public {
        // Define the CollateralTier enums (only for documentation)
        ILendefiAssets.CollateralTier[] memory tiers = new ILendefiAssets.CollateralTier[](4);
        tiers[3] = ILendefiAssets.CollateralTier.ISOLATED;
        tiers[2] = ILendefiAssets.CollateralTier.CROSS_A;
        tiers[1] = ILendefiAssets.CollateralTier.CROSS_B;
        tiers[0] = ILendefiAssets.CollateralTier.STABLE;

        // Get tier parameters from the contract
        (uint256[4] memory jumpRates, uint256[4] memory liquidationFees) = assetsInstance.getTierRates();

        // Directly verify each value matches the expected values from _initializeDefaultTierParameters
        // The getTierRates function defines:
        // Index 3 = ISOLATED, Index 2 = CROSS_B, Index 1 = CROSS_A, Index 0 = STABLE

        // Check borrow rates
        assertEq(jumpRates[3], 0.15e6, "Incorrect borrow rate for ISOLATED");
        assertEq(jumpRates[2], 0.12e6, "Incorrect borrow rate for CROSS_B");
        assertEq(jumpRates[1], 0.08e6, "Incorrect borrow rate for CROSS_A");
        assertEq(jumpRates[0], 0.05e6, "Incorrect borrow rate for STABLE");

        // Check liquidation fees
        assertEq(liquidationFees[3], 0.04e6, "Incorrect liquidation bonus for ISOLATED");
        assertEq(liquidationFees[2], 0.03e6, "Incorrect liquidation bonus for CROSS_B");
        assertEq(liquidationFees[1], 0.02e6, "Incorrect liquidation bonus for CROSS_A");
        assertEq(liquidationFees[0], 0.01e6, "Incorrect liquidation bonus for STABLE");
    }
}
