// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";
import {MockWBTC} from "../../../contracts/mock/MockWBTC.sol";

contract GetAssetPriceTest is BasicDeploy {
    // Token instances
    MockWBTC internal wbtcToken;

    // Oracle instances
    WETHPriceConsumerV3 internal wethOracleInstance;
    WETHPriceConsumerV3 internal wbtcOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();
        wbtcToken = new MockWBTC();

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        wbtcOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        wbtcOracleInstance.setPrice(60000e8); // $60,000 per BTC
        stableOracleInstance.setPrice(1e8); // $1 per stable

        // Setup roles
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // UPDATED: Use assetsInstance for asset configuration
        // Configure WETH as CROSS_A tier
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // Supply limit
            0,
            IASSETS.CollateralTier.CROSS_A, // UPDATED: Use IASSETS.CollateralTier
            IASSETS.OracleType.CHAINLINK
        );

        // Configure WBTC as CROSS_A tier
        assetsInstance.updateAssetConfig(
            address(wbtcToken),
            address(wbtcOracleInstance),
            8, // Oracle decimals
            8, // Asset decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000 * 1e8, // Supply limit
            0,
            IASSETS.CollateralTier.CROSS_A, // UPDATED: Use IASSETS.CollateralTier
            IASSETS.OracleType.CHAINLINK
        );

        // Configure USDC as STABLE tier
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            address(stableOracleInstance),
            8, // Oracle decimals
            6, // USDC decimals
            1, // Active
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000e6, // Supply limit
            0,
            IASSETS.CollateralTier.STABLE, // UPDATED: Use IASSETS.CollateralTier
            IASSETS.OracleType.CHAINLINK
        );

        // Register oracles with Oracle module

        assetsInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        assetsInstance.setPrimaryOracle(address(wbtcToken), address(wbtcOracleInstance));

        assetsInstance.setPrimaryOracle(address(usdcInstance), address(stableOracleInstance));
        vm.stopPrank();
    }

    function test_GetAssetPrice_WETH() public {
        // UPDATED: Use assetsInstance instead of LendefiInstance
        uint256 price = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2500e8, "WETH price should be $2500");
    }

    function test_GetAssetPrice_WBTC() public {
        // UPDATED: Use assetsInstance instead of LendefiInstance
        uint256 price = assetsInstance.getAssetPrice(address(wbtcToken));
        assertEq(price, 60000e8, "WBTC price should be $60,000");
    }

    function test_GetAssetPrice_USDC() public {
        // UPDATED: Use assetsInstance instead of LendefiInstance
        uint256 price = assetsInstance.getAssetPrice(address(usdcInstance));
        assertEq(price, 1e8, "USDC price should be $1");
    }

    function test_GetAssetPrice_AfterPriceChange() public {
        // Change the WETH price from $2500 to $3000
        wethOracleInstance.setPrice(3000e8);

        // UPDATED: Use assetsInstance instead of LendefiInstance
        uint256 price = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 3000e8, "WETH price should be updated to $3000");
    }

    function test_GetAssetPrice_UnlistedAsset() public {
        // Using an address that's not configured as an asset should revert
        address randomAddress = address(0x123);

        // UPDATED: Use assetsInstance and expect specific AssetNotListed error
        vm.expectRevert(abi.encodeWithSelector(IASSETS.AssetNotListed.selector, randomAddress));
        assetsInstance.getAssetPrice(randomAddress);
    }

    function test_GetAssetPrice_MultipleAssets() public {
        // UPDATED: Use assetsInstance instead of LendefiInstance for all calls
        uint256 wethPrice = assetsInstance.getAssetPrice(address(wethInstance));
        uint256 wbtcPrice = assetsInstance.getAssetPrice(address(wbtcToken));
        uint256 usdcPrice = assetsInstance.getAssetPrice(address(usdcInstance));

        assertEq(wethPrice, 2500e8, "WETH price should be $2500");
        assertEq(wbtcPrice, 60000e8, "WBTC price should be $60,000");
        assertEq(usdcPrice, 1e8, "USDC price should be $1");

        // Check the ratio of BTC to ETH
        assertEq(wbtcPrice / wethPrice, 24, "WBTC should be worth 24 times more than WETH");
    }

    // Additional test: Use direct oracle price access
    function test_GetAssetPriceOracle_Direct() public {
        // UPDATED: Use getAssetPriceOracle which now exists on assetsInstance
        uint256 wethPrice = assetsInstance.getAssetPriceOracle(address(wethOracleInstance));
        assertEq(wethPrice, 2500e8, "Direct Oracle WETH price should be $2500");
    }
}
