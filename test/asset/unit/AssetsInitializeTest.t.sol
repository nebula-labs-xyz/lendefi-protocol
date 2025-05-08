// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {LendefiAssets} from "../../../contracts/lender/LendefiAssets.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract AssetsInitializeTest is BasicDeploy {
    // Events to verify
    event UpdateAssetConfig(address indexed asset);

    // Test variables
    address private timelockAddr;
    address private oracleAddr;
    bytes private initData;

    function setUp() public {
        // Deploy the oracle first
        wethInstance = new WETH9();
        deployCompleteWithOracle();

        // Store addresses for initialization
        timelockAddr = address(timelockInstance);

        // Create initialization data
        initData = abi.encodeCall(LendefiAssets.initialize, (timelockAddr, gnosisSafe, address(usdcInstance)));
    }

    function test_InitializeSuccess() public {
        // Deploy LendefiAssets with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Check role assignments
        assertTrue(assetsContract.hasRole(DEFAULT_ADMIN_ROLE, timelockAddr), "Timelock should have DEFAULT_ADMIN_ROLE");
        assertTrue(assetsContract.hasRole(MANAGER_ROLE, timelockAddr), "Timelock should have MANAGER_ROLE");
        assertTrue(assetsContract.hasRole(UPGRADER_ROLE, gnosisSafe), "gnosisSafe should have UPGRADER_ROLE");
        assertTrue(assetsContract.hasRole(UPGRADER_ROLE, timelockAddr), "Timelock should have UPGRADER_ROLE");
        assertTrue(assetsContract.hasRole(PAUSER_ROLE, gnosisSafe), "gnosisSafe should have PAUSER_ROLE");
        assertTrue(assetsContract.hasRole(PAUSER_ROLE, timelockAddr), "Timelock should have PAUSER_ROLE");

        // Check version
        assertEq(assetsContract.version(), 1, "Initial version should be 1");

        // Check tier parameters were initialized
        (uint256[4] memory jumpRates, uint256[4] memory liquidationFees) = assetsContract.getTierRates();

        // Verify ISOLATED tier rates (index 3)
        assertEq(jumpRates[3], 0.15e6, "Incorrect ISOLATED tier jump rate");
        assertEq(liquidationFees[3], 0.04e6, "Incorrect ISOLATED tier liquidation fee");

        // Verify CROSS_B tier rates (index 2)
        assertEq(jumpRates[2], 0.12e6, "Incorrect CROSS_B tier jump rate");
        assertEq(liquidationFees[2], 0.03e6, "Incorrect CROSS_B tier liquidation fee");

        // Verify CROSS_A tier rates (index 1)
        assertEq(jumpRates[1], 0.08e6, "Incorrect CROSS_A tier jump rate");
        assertEq(liquidationFees[1], 0.02e6, "Incorrect CROSS_A tier liquidation fee");

        // Verify STABLE tier rates (index 0)
        assertEq(jumpRates[0], 0.05e6, "Incorrect STABLE tier jump rate");
        assertEq(liquidationFees[0], 0.01e6, "Incorrect STABLE tier liquidation fee");
    }

    function test_ZeroAddressReverts() public {
        LendefiAssets implementation = new LendefiAssets();

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        LendefiAssets assetsModule = LendefiAssets(payable(address(proxy)));

        // Test with zero address for timelock
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressNotAllowed()"));
        assetsModule.initialize(address(0), gnosisSafe, address(usdcInstance));

        // Test with zero address for gnosisSafe
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressNotAllowed()"));
        assetsModule.initialize(timelockAddr, address(0), address(usdcInstance));
    }

    function test_PreventReinitialization() public {
        // First initialize normally
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Try to initialize again
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        assetsContract.initialize(timelockAddr, gnosisSafe, address(usdcInstance));
    }

    function test_RoleExclusivity() public {
        // Deploy with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Verify timelock has admin role but gnosisSafe doesn't
        assertTrue(assetsContract.hasRole(DEFAULT_ADMIN_ROLE, timelockAddr), "Timelock should have DEFAULT_ADMIN_ROLE");
        assertFalse(
            assetsContract.hasRole(DEFAULT_ADMIN_ROLE, gnosisSafe), "gnosisSafe should not have DEFAULT_ADMIN_ROLE"
        );

        // Neither should have CORE_ROLE initially
        assertFalse(assetsContract.hasRole(CORE_ROLE, gnosisSafe), "gnosisSafe should not have CORE_ROLE");
        assertFalse(assetsContract.hasRole(CORE_ROLE, timelockAddr), "timelock should not have CORE_ROLE");

        // Timelock should have MANAGER_ROLE
        assertTrue(assetsContract.hasRole(MANAGER_ROLE, timelockAddr), "Timelock should have MANAGER_ROLE");
        assertFalse(assetsContract.hasRole(MANAGER_ROLE, gnosisSafe), "gnosisSafe should not have MANAGER_ROLE");
    }

    function test_BothHaveUpgraderAndPauserRoles() public {
        // Deploy with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Both timelock and gnosisSafe should have UPGRADER_ROLE and PAUSER_ROLE
        assertTrue(assetsContract.hasRole(UPGRADER_ROLE, timelockAddr), "Timelock should have UPGRADER_ROLE");
        assertTrue(assetsContract.hasRole(UPGRADER_ROLE, gnosisSafe), "gnosisSafe should have UPGRADER_ROLE");

        assertTrue(assetsContract.hasRole(PAUSER_ROLE, timelockAddr), "Timelock should have PAUSER_ROLE");
        assertTrue(assetsContract.hasRole(PAUSER_ROLE, gnosisSafe), "gnosisSafe should have PAUSER_ROLE");
    }

    function test_RoleHierarchy() public {
        // Deploy with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // timelockAddr with DEFAULT_ADMIN_ROLE should be able to grant roles
        vm.startPrank(timelockAddr);
        assetsContract.grantRole(CORE_ROLE, address(0x123));
        vm.stopPrank();

        assertTrue(assetsContract.hasRole(CORE_ROLE, address(0x123)), "timelockAddr should be able to grant CORE_ROLE");

        // gnosisSafe without DEFAULT_ADMIN_ROLE should not be able to grant roles
        vm.startPrank(gnosisSafe);
        // Updated for newer OZ error format
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, gnosisSafe, DEFAULT_ADMIN_ROLE
            )
        );
        assetsContract.grantRole(CORE_ROLE, address(0x456));
        vm.stopPrank();
    }

    function test_TierParameterPrecision() public {
        // Deploy with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Check individual tier parameters with direct getter functions
        assertEq(
            assetsContract.getLiquidationFee(IASSETS.CollateralTier.ISOLATED),
            0.04e6,
            "ISOLATED liquidation fee should be precisely 0.04e6"
        );

        assertEq(
            assetsContract.getTierJumpRate(IASSETS.CollateralTier.STABLE),
            0.05e6,
            "STABLE jump rate should be precisely 0.05e6"
        );
    }

    function test_OracleConfigInitialization() public {
        // Deploy with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Get the oracle config
        (
            uint80 freshnessThreshold,
            uint80 volatilityThreshold,
            uint40 volatilityPercentage,
            uint40 circuitBreakerThreshold
        ) = assetsContract.mainOracleConfig();

        // Verify default values
        assertEq(freshnessThreshold, 28800, "Freshness threshold should be 28800 (8 hours)");
        assertEq(volatilityThreshold, 3600, "Volatility threshold should be 3600 (1 hour)");
        assertEq(volatilityPercentage, 20, "Volatility percentage should be 20%");
        assertEq(circuitBreakerThreshold, 50, "Circuit breaker threshold should be 50%");
    }

    function test_ListedAssetsEmptyAfterInit() public {
        // Deploy with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Check that no assets are listed initially
        address[] memory assets = assetsContract.getListedAssets();
        assertEq(assets.length, 0, "No assets should be listed after initialization");
    }

    function test_PauseStateAfterInit() public {
        // Create a mock oracle address for the asset
        address mockPriceFeed = address(0x123456);

        // Add the mock price feed to the oracle first
        vm.startPrank(timelockAddr);

        // Configure asset with new Asset struct format
        IASSETS.Asset memory item = IASSETS.Asset({
            active: 1,
            decimals: 18,
            borrowThreshold: 900,
            liquidationThreshold: 950,
            maxSupplyThreshold: 1_000_000e18,
            isolationDebtCap: 0,
            assetMinimumOracles: 1,
            porFeed: address(0),
            primaryOracleType: IASSETS.OracleType.CHAINLINK,
            tier: IASSETS.CollateralTier.CROSS_A,
            chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockPriceFeed), active: 1}),
            poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
        });

        // Update asset config on the newly deployed contract (not the global instance)
        assetsInstance.updateAssetConfig(address(wethInstance), item);

        // Verify the asset is properly registered
        assertTrue(assetsInstance.isAssetValid(address(wethInstance)), "Asset should be valid");
        vm.stopPrank();

        // Both timelock and gnosisSafe can pause
        vm.prank(gnosisSafe);
        assetsInstance.pause();

        // Try a function that's protected by whenNotPaused
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(timelockAddr);
        assetsInstance.updateAssetConfig(address(wethInstance), item);

        // Test unpause with timelock
        vm.prank(timelockAddr);
        assetsInstance.unpause();

        // Now update should work again
        item = IASSETS.Asset({
            active: 1,
            decimals: 18,
            borrowThreshold: 900,
            liquidationThreshold: 950,
            maxSupplyThreshold: 1_000_000e18,
            isolationDebtCap: 0,
            assetMinimumOracles: 1,
            porFeed: assetsInstance.getAssetInfo(address(wethInstance)).porFeed,
            primaryOracleType: IASSETS.OracleType.CHAINLINK,
            tier: IASSETS.CollateralTier.CROSS_A,
            chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockPriceFeed), active: 1}),
            poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
        });
        vm.prank(timelockAddr);
        assetsInstance.updateAssetConfig(address(wethInstance), item);
    }
}
