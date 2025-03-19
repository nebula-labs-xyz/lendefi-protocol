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
        initData = abi.encodeCall(LendefiAssets.initialize, (timelockAddr, guardian));
    }

    function test_InitializeSuccess() public {
        // Deploy LendefiAssets with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Check role assignments
        assertTrue(assetsContract.hasRole(DEFAULT_ADMIN_ROLE, guardian), "Guardian should have DEFAULT_ADMIN_ROLE");
        assertTrue(assetsContract.hasRole(MANAGER_ROLE, timelockAddr), "Timelock should have MANAGER_ROLE");
        assertTrue(assetsContract.hasRole(UPGRADER_ROLE, guardian), "Guardian should have UPGRADER_ROLE");
        assertTrue(assetsContract.hasRole(PAUSER_ROLE, guardian), "Guardian should have PAUSER_ROLE");

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
        assetsModule.initialize(address(0), guardian);

        // Test with zero address for guardian
        vm.expectRevert(abi.encodeWithSignature("ZeroAddressNotAllowed()"));
        assetsModule.initialize(timelockAddr, address(0));
    }

    function test_PreventReinitialization() public {
        // First initialize normally
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Try to initialize again
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        assetsContract.initialize(timelockAddr, guardian);
    }

    function test_RoleExclusivity() public {
        // Deploy with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Guardian should have specific roles, but not CORE_ROLE
        assertTrue(assetsContract.hasRole(DEFAULT_ADMIN_ROLE, guardian), "Guardian should have DEFAULT_ADMIN_ROLE");
        assertFalse(assetsContract.hasRole(CORE_ROLE, guardian), "Guardian should not have CORE_ROLE");

        // Timelock should have MANAGER_ROLE but not other roles
        assertTrue(assetsContract.hasRole(MANAGER_ROLE, timelockAddr), "Timelock should have MANAGER_ROLE");
        assertFalse(assetsContract.hasRole(UPGRADER_ROLE, timelockAddr), "Timelock should not have UPGRADER_ROLE");
        assertFalse(assetsContract.hasRole(PAUSER_ROLE, timelockAddr), "Timelock should not have PAUSER_ROLE");
    }

    function test_RoleHierarchy() public {
        // Deploy with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Guardian with DEFAULT_ADMIN_ROLE should be able to grant roles
        vm.startPrank(guardian);
        assetsContract.grantRole(CORE_ROLE, address(0x123));
        vm.stopPrank();

        assertTrue(assetsContract.hasRole(CORE_ROLE, address(0x123)), "Guardian should be able to grant CORE_ROLE");

        // Timelock with just MANAGER_ROLE should not be able to grant roles
        vm.startPrank(timelockAddr);
        // Updated for newer OZ error format
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, timelockAddr, DEFAULT_ADMIN_ROLE
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

    function test_ListedAssetsEmptyAfterInit() public {
        // Deploy with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Check that no assets are listed initially
        address[] memory assets = assetsContract.getListedAssets();
        assertEq(assets.length, 0, "No assets should be listed after initialization");
    }

    function test_PauseStateAfterInit() public {
        // Deploy with initialization using explicit guardian address
        bytes memory localInitData = abi.encodeCall(LendefiAssets.initialize, (timelockAddr, guardian));
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", localInitData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

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
            primaryOracleType: IASSETS.OracleType.CHAINLINK,
            tier: IASSETS.CollateralTier.CROSS_A,
            chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockPriceFeed), oracleDecimals: 8, active: 1}),
            poolConfig: IASSETS.UniswapPoolConfig({
                pool: address(0),
                quoteToken: address(0),
                isToken0: false,
                decimalsUniswap: 0,
                twapPeriod: 0,
                active: 0
            })
        });

        // Update asset config on the newly deployed contract (not the global instance)
        assetsContract.updateAssetConfig(address(wethInstance), item);

        // Verify the asset is properly registered
        assertTrue(assetsContract.isAssetValid(address(wethInstance)), "Asset should be valid");
        vm.stopPrank();

        // Now pause the contract - use the guardian address
        vm.prank(guardian);
        assetsContract.pause();

        // Try a function that's protected by whenNotPaused
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(timelockAddr);
        assetsContract.updateAssetConfig(address(wethInstance), item);
    }

    function test_InitializeWithDifferentGuardian() public {
        // Use different address for guardian
        address newGuardian = address(0xbeff);

        bytes memory customData = abi.encodeCall(LendefiAssets.initialize, (timelockAddr, newGuardian));

        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", customData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Check that the new guardian has the correct roles
        assertTrue(
            assetsContract.hasRole(DEFAULT_ADMIN_ROLE, newGuardian), "New guardian should have DEFAULT_ADMIN_ROLE"
        );
        assertTrue(assetsContract.hasRole(UPGRADER_ROLE, newGuardian), "New guardian should have UPGRADER_ROLE");
        assertTrue(assetsContract.hasRole(PAUSER_ROLE, newGuardian), "New guardian should have PAUSER_ROLE");

        // Original guardian should not have any roles
        assertFalse(
            assetsContract.hasRole(DEFAULT_ADMIN_ROLE, guardian), "Original guardian should not have DEFAULT_ADMIN_ROLE"
        );
    }
}
