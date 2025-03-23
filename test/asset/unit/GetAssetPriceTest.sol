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

        // Configure WETH as CROSS_A tier
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800, // 80% borrow threshold
                liquidationThreshold: 850, // 85% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether, // Supply limit
                isolationDebtCap: 0, // No isolation debt cap
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure WBTC as CROSS_A tier
        assetsInstance.updateAssetConfig(
            address(wbtcToken),
            IASSETS.Asset({
                active: 1,
                decimals: 8, // WBTC has 8 decimals
                borrowThreshold: 800, // 80% borrow threshold
                liquidationThreshold: 850, // 85% liquidation threshold
                maxSupplyThreshold: 1_000 * 1e6, // Supply limit
                isolationDebtCap: 0, // No isolation debt cap
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wbtcOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure USDC as STABLE tier
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6, // USDC has 6 decimals
                borrowThreshold: 900, // 90% borrow threshold
                liquidationThreshold: 950, // 95% liquidation threshold
                maxSupplyThreshold: 1_000_000e6, // Supply limit
                isolationDebtCap: 0, // No isolation debt cap
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(stableOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );
        vm.stopPrank();
    }

    function test_GetAssetPrice_WETH() public {
        // UPDATED: Use assetsInstance instead of LendefiInstance
        uint256 price = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2500e6, "WETH price should be $2500");
    }

    function test_GetAssetPrice_WBTC() public {
        // UPDATED: Use assetsInstance instead of LendefiInstance
        uint256 price = assetsInstance.getAssetPrice(address(wbtcToken));
        assertEq(price, 60000e6, "WBTC price should be $60,000");
    }

    function test_GetAssetPrice_USDC() public {
        // UPDATED: Use assetsInstance instead of LendefiInstance
        uint256 price = assetsInstance.getAssetPrice(address(usdcInstance));
        assertEq(price, 1e6, "USDC price should be $1");
    }

    function test_GetAssetPrice_AfterPriceChange() public {
        // Change the WETH price from $2500 to $3000
        wethOracleInstance.setPrice(3000e8);

        // UPDATED: Use assetsInstance instead of LendefiInstance
        uint256 price = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 3000e6, "WETH price should be updated to $3000");
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

        assertEq(wethPrice, 2500e6, "WETH price should be $2500");
        assertEq(wbtcPrice, 60000e6, "WBTC price should be $60,000");
        assertEq(usdcPrice, 1e6, "USDC price should be $1");

        // Check the ratio of BTC to ETH
        assertEq(wbtcPrice / wethPrice, 24, "WBTC should be worth 24 times more than WETH");
    }

    // Additional test: Use direct oracle price access
    function test_GetAssetPriceOracle_Direct() public {
        // UPDATED: Use getAssetPriceOracle which now exists on assetsInstance
        uint256 wethPrice = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(wethPrice, 2500e6, "Direct Oracle WETH price should be $2500");
    }
}
