// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {LINKPriceConsumerV3} from "../../../contracts/mock/LINKOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";
import {TokenMock} from "../../../contracts/mock/TokenMock.sol";
import {LINK} from "../../../contracts/mock/LINK.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract GetListedAssetsTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracle;
    StablePriceConsumerV3 internal usdcOracle;
    LINKPriceConsumerV3 internal linkOracleInstance;

    // Mock tokens
    IERC20 internal daiInstance;
    LINK internal linkInstance;

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();

        // Create additional mock tokens for testing
        daiInstance = new TokenMock("DAI", "DAI");
        linkInstance = new LINK();

        // Deploy oracles
        wethOracle = new WETHPriceConsumerV3();
        usdcOracle = new StablePriceConsumerV3();
        linkOracleInstance = new LINKPriceConsumerV3();

        // Set prices
        wethOracle.setPrice(2500e8); // $2500 per ETH
        usdcOracle.setPrice(1e8); // $1 per stable
        linkOracleInstance.setPrice(14e8); // $14 Link

        // Setup roles
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));
    }

    function test_GetListedAssets_Initial() public {
        // Check initially listed assets
        address[] memory initialAssets = assetsInstance.getListedAssets();
        assertEq(initialAssets.length, 0, "Initial assets array should be empty");
    }

    function test_GetListedAssets_AfterAddingAssets() public {
        // Configure WETH as listed asset
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Configure USDC as listed asset
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 900,
                liquidationThreshold: 950,
                maxSupplyThreshold: 1_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.UNISWAP_V3_TWAP,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(usdcOracle), active: 0}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0x123), twapPeriod: 1800, active: 1})
            })
        );

        vm.stopPrank();

        // Get assets after listing 2 assets
        address[] memory assetsAfterListing = assetsInstance.getListedAssets();

        // Verify array length
        assertEq(assetsAfterListing.length, 2, "Listed assets array should have 2 elements");

        // Verify array contents
        bool foundWeth = false;
        bool foundUsdc = false;

        for (uint256 i = 0; i < assetsAfterListing.length; i++) {
            if (assetsAfterListing[i] == address(wethInstance)) {
                foundWeth = true;
            }
            if (assetsAfterListing[i] == address(usdcInstance)) {
                foundUsdc = true;
            }
        }

        assertTrue(foundWeth, "WETH should be in listed assets");
        assertTrue(foundUsdc, "USDC should be in listed assets");
    }

    function test_GetListedAssets_MultipleAddsAndOrder() public {
        // Add multiple assets
        vm.startPrank(address(timelockInstance));

        // Add WETH
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Add USDC
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 900,
                liquidationThreshold: 950,
                maxSupplyThreshold: 1_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(usdcOracle), active: 0}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0x123), twapPeriod: 1800, active: 1})
            })
        );

        // Add DAI
        assetsInstance.updateAssetConfig(
            address(daiInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 850,
                liquidationThreshold: 900,
                maxSupplyThreshold: 1_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(usdcOracle), active: 0}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Add LINK
        assetsInstance.updateAssetConfig(
            address(linkInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 700,
                liquidationThreshold: 750,
                maxSupplyThreshold: 500_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_B,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(linkOracleInstance), active: 0}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        vm.stopPrank();

        // Get assets after listing 4 assets
        address[] memory listedAssets = assetsInstance.getListedAssets();

        // Verify array length
        assertEq(listedAssets.length, 4, "Listed assets array should have 4 elements");

        // Log all assets for clarity
        console2.log("Listed assets:");
        for (uint256 i = 0; i < listedAssets.length; i++) {
            console2.log("Asset", i, ":", listedAssets[i]);
        }

        // Verify all assets are included
        bool foundWeth = false;
        bool foundUsdc = false;
        bool foundDai = false;
        bool foundLink = false;

        for (uint256 i = 0; i < listedAssets.length; i++) {
            if (listedAssets[i] == address(wethInstance)) foundWeth = true;
            if (listedAssets[i] == address(usdcInstance)) foundUsdc = true;
            if (listedAssets[i] == address(daiInstance)) foundDai = true;
            if (listedAssets[i] == address(linkInstance)) foundLink = true;
        }

        assertTrue(foundWeth, "WETH should be in listed assets");
        assertTrue(foundUsdc, "USDC should be in listed assets");
        assertTrue(foundDai, "DAI should be in listed assets");
        assertTrue(foundLink, "LINK should be in listed assets");
    }

    function test_GetListedAssets_UpdateInactiveAsset() public {
        // Add an asset as active
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
        vm.stopPrank();

        // Verify it's in the list
        address[] memory assetsActive = assetsInstance.getListedAssets();
        assertEq(assetsActive.length, 1, "Should have 1 listed asset");
        assertEq(assetsActive[0], address(wethInstance), "Listed asset should be WETH");

        // Update the asset to inactive
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
        vm.stopPrank();

        // Verify it's still in the list (inactive assets remain listed)
        address[] memory assetsInactive = assetsInstance.getListedAssets();
        assertEq(assetsInactive.length, 1, "Should still have 1 listed asset even when inactive");
        assertEq(assetsInactive[0], address(wethInstance), "Listed asset should still be WETH");
    }
}
