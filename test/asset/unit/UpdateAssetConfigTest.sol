// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {MockRWA} from "../../../contracts/mock/MockRWA.sol";
import {RWAPriceConsumerV3} from "../../../contracts/mock/RWAOracle.sol";

contract UpdateAssetConfigTest is BasicDeploy {
    // Event comes from the assets contract now
    event UpdateAssetConfig(IASSETS.Asset config);

    MockRWA internal testToken;
    RWAPriceConsumerV3 internal testOracle;

    // Test parameters
    uint8 internal constant ORACLE_DECIMALS = 8;
    uint8 internal constant ASSET_DECIMALS = 18;
    uint8 internal constant ASSET_ACTIVE = 1;
    uint16 internal constant BORROW_THRESHOLD = 800; // 80%
    uint16 internal constant LIQUIDATION_THRESHOLD = 850; // 85%
    uint256 internal constant MAX_SUPPLY = 1_000_000 ether;
    uint256 internal constant ISOLATION_DEBT_CAP = 100_000e6;

    function setUp() public {
        // Use the updated deployment function that includes Oracle setup
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy test token and oracle for this specific test
        testToken = new MockRWA("Test Token", "TEST");
        testOracle = new RWAPriceConsumerV3();
        testOracle.setPrice(1000e8); // $1000 per token
    }

    // Test 1: Only manager can update asset config
    function testRevert_OnlyManagerCanUpdateAssetConfig() public {
        // Regular user should not be able to call updateAssetConfig

        // Using OpenZeppelin v5.0 AccessControl error format
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", alice, keccak256("MANAGER_ROLE")
            )
        );
        vm.startPrank(alice);
        // Call should be to assetsInstance with new struct-based format
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );
        vm.stopPrank();

        // Manager (timelock) should be able to update asset config
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );
    }

    // Test 2: Adding a new asset
    function test_AddingNewAsset() public {
        // Initial state - asset should not be listed
        address[] memory initialAssets = assetsInstance.getListedAssets();
        bool initiallyPresent = false;
        for (uint256 i = 0; i < initialAssets.length; i++) {
            if (initialAssets[i] == address(testToken)) {
                initiallyPresent = true;
                break;
            }
        }
        assertFalse(initiallyPresent, "Asset should not be listed initially");

        // Update asset config
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Asset should now be listed
        address[] memory updatedAssets = assetsInstance.getListedAssets();
        bool nowPresent = false;
        for (uint256 i = 0; i < updatedAssets.length; i++) {
            if (updatedAssets[i] == address(testToken)) {
                nowPresent = true;
                break;
            }
        }
        assertTrue(nowPresent, "Asset should be listed after update");
    }

    // Test 3: All parameters correctly stored
    function test_AllParametersCorrectlyStored() public {
        // Update asset config
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Get stored asset info
        IASSETS.Asset memory assetInfo = assetsInstance.getAssetInfo(address(testToken));

        // Verify all parameters
        assertEq(assetInfo.active, ASSET_ACTIVE, "Active status not stored correctly");
        assertEq(assetInfo.chainlinkConfig.oracleUSD, address(testOracle), "Oracle address not stored correctly");

        assertEq(assetInfo.decimals, ASSET_DECIMALS, "Asset decimals not stored correctly");
        assertEq(assetInfo.borrowThreshold, BORROW_THRESHOLD, "Borrow threshold not stored correctly");
        assertEq(assetInfo.liquidationThreshold, LIQUIDATION_THRESHOLD, "Liquidation threshold not stored correctly");
        assertEq(assetInfo.maxSupplyThreshold, MAX_SUPPLY, "Max supply not stored correctly");
        assertEq(uint8(assetInfo.tier), uint8(IASSETS.CollateralTier.CROSS_A), "Tier not stored correctly");
        assertEq(assetInfo.isolationDebtCap, ISOLATION_DEBT_CAP, "Isolation debt cap not stored correctly");
    }

    // Test 4: Update existing asset
    function test_UpdateExistingAsset() public {
        // First add the asset
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Now update some parameters
        uint8 newActive = 0; // Deactivate
        uint16 newBorrowThreshold = 700; // 70%
        IASSETS.CollateralTier newTier = IASSETS.CollateralTier.ISOLATED;
        uint256 newDebtCap = 50_000e6;

        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: newActive,
                decimals: ASSET_DECIMALS,
                borrowThreshold: newBorrowThreshold,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: newDebtCap,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: newTier,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Verify updated parameters
        IASSETS.Asset memory assetInfo = assetsInstance.getAssetInfo(address(testToken));

        assertEq(assetInfo.active, newActive, "Active status not updated correctly");
        assertEq(assetInfo.borrowThreshold, newBorrowThreshold, "Borrow threshold not updated correctly");
        assertEq(uint8(assetInfo.tier), uint8(newTier), "Tier not updated correctly");
        assertEq(assetInfo.isolationDebtCap, newDebtCap, "Isolation debt cap not updated correctly");
    }

    // Test 5: Correct event emission
    function test_EventEmission() public {
        IASSETS.Asset memory item = IASSETS.Asset({
            active: ASSET_ACTIVE,
            decimals: ASSET_DECIMALS,
            borrowThreshold: BORROW_THRESHOLD,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            maxSupplyThreshold: MAX_SUPPLY,
            isolationDebtCap: ISOLATION_DEBT_CAP,
            assetMinimumOracles: 1,
            primaryOracleType: IASSETS.OracleType.CHAINLINK,
            tier: IASSETS.CollateralTier.CROSS_A,
            chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
            poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
        });

        vm.expectEmit(true, false, false, false);
        emit UpdateAssetConfig(item);
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(address(testToken), item);
    }

    // Test 6: Effect on collateral management
    function test_EffectOnCollateral() public {
        // First add the asset as active
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Setup user position - these still use LendefiInstance
        testToken.mint(alice, 10 ether);
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(testToken), false);
        testToken.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(testToken), 5 ether, 0);
        vm.stopPrank();

        // Deactivate the asset - now using assetsInstance
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: 0, // Deactivate
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Try supplying more collateral - should revert with NotListed error
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.NotListed.selector));
        LendefiInstance.supplyCollateral(address(testToken), 5 ether, 0);
        vm.stopPrank();
    }
}
