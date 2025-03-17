// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {AggregatorV3Interface} from
    "../../contracts/vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract AssetModuleOracleTest is BasicDeploy {
    // Test tokens
    MockRWA internal rwaToken;
    MockRWA internal stableToken;

    // Mock oracles
    MockPriceOracle internal mockOracle1;
    MockPriceOracle internal mockOracle2;
    MockPriceOracle internal mockOracle3;
    WETHPriceConsumerV3 internal wethassetsInstance;
    RWAPriceConsumerV3 internal rwaassetsInstance;
    StablePriceConsumerV3 internal stableassetsInstance;

    // Events to verify
    event OracleAdded(address indexed asset, address indexed oracle);
    event OracleRemoved(address indexed asset, address indexed oracle);
    event PrimaryOracleSet(address indexed asset, address indexed oracle);
    event FreshnessThresholdUpdated(uint256 oldValue, uint256 newValue);
    event VolatilityThresholdUpdated(uint256 oldValue, uint256 newValue);
    event VolatilityPercentageUpdated(uint256 oldValue, uint256 newValue);
    event CircuitBreakerThresholdUpdated(uint256 oldValue, uint256 newValue);
    event CircuitBreakerTriggered(address indexed asset, uint256 currentPrice, uint256 previousPrice);
    event CircuitBreakerReset(address indexed asset);
    event PriceUpdated(address indexed asset, uint256 price, uint256 median, uint256 numOracles);
    event MinimumOraclesUpdated(uint256 oldValue, uint256 newValue);
    event AssetMinimumOraclesUpdated(address indexed asset, uint256 oldValue, uint256 newValue);
    event NotEnoughOraclesWarning(address indexed asset, uint256 required, uint256 actual);
    // Add these custom errors at the top of your test contract to match what's in LendefiOracle.sol

    error NotEnoughOracles(address asset, uint256 required, uint256 actual);
    error LargeDeviation(address asset, uint256 currentPrice, uint256 previousPrice, uint256 percentChange);
    error CircuitBreakerActive(address asset);
    error OracleInvalidPrice(address oracle, int256 price);
    error OracleStalePrice(address oracle, uint80 roundId, uint80 answeredInRound);
    error OracleTimeout(address oracle, uint256 timestamp, uint256 currentTimestamp, uint256 maxAge);
    error OracleNotFound(address asset);
    error OracleInvalidPriceVolatility(address oracle, int256 price, uint256 volatility);

    // Then modify your setUp() function to call this
    function setUp() public {
        // Initial deployment with oracle
        deployCompleteWithOracle();

        // Deploy test tokens
        wethInstance = new WETH9();
        rwaToken = new MockRWA("RWA Token", "RWA");
        stableToken = new MockRWA("USDT", "USDT");

        // Deploy price feeds
        wethassetsInstance = new WETHPriceConsumerV3();
        rwaassetsInstance = new RWAPriceConsumerV3();
        stableassetsInstance = new StablePriceConsumerV3();

        // Deploy mock oracles for more controlled testing
        mockOracle1 = new MockPriceOracle();
        mockOracle2 = new MockPriceOracle();
        mockOracle3 = new MockPriceOracle();

        // Set initial prices
        wethassetsInstance.setPrice(2000e8); // $2000 per ETH
        rwaassetsInstance.setPrice(1000e8); // $1000 per RWA token
        stableassetsInstance.setPrice(1e8); // $1 per stable token

        mockOracle1.setPrice(2010e8);
        mockOracle1.setTimestamp(block.timestamp);
        mockOracle1.setRoundId(1);
        mockOracle1.setAnsweredInRound(1);

        mockOracle2.setPrice(1990e8);
        mockOracle2.setTimestamp(block.timestamp);
        mockOracle2.setRoundId(1);
        mockOracle2.setAnsweredInRound(1);

        mockOracle3.setPrice(2020e8);
        mockOracle3.setTimestamp(block.timestamp);
        mockOracle3.setRoundId(1);
        mockOracle3.setAnsweredInRound(1);

        // Setup all required assets
        _setupAssets();
    }

    /**
     * @notice Setup assets for oracle testing
     * @dev Called from setUp to register all required assets before oracle operations
     */
    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Register WETH asset
        // Register WETH asset - UPDATED FUNCTION SIGNATURE
        assetsInstance.updateAssetConfig(
            address(wethInstance), // asset
            address(0), // oracle (will be set later)
            8, // oracleDecimals
            18, // assetDecimals
            1, // active
            900, // borrowThreshold (90%)
            950, // liquidationThreshold (95%)
            1_000_000e18, // maxSupplyLimit
            0, // isolationDebtCap (MOVED before tier)
            IASSETS.CollateralTier.CROSS_A, // tier
            IASSETS.OracleType.CHAINLINK // NEW parameter
        );

        // Register RWA asset - UPDATED FUNCTION SIGNATURE
        assetsInstance.updateAssetConfig(
            address(rwaToken), // asset
            address(0), // oracle (will be set later)
            8, // oracleDecimals
            18, // assetDecimals
            1, // active
            800, // borrowThreshold (80%)
            850, // liquidationThreshold (85%)
            500_000e18, // maxSupplyLimit
            0, // isolationDebtCap (MOVED before tier)
            IASSETS.CollateralTier.CROSS_B, // tier
            IASSETS.OracleType.CHAINLINK // NEW parameter
        );

        // Register Stable asset - UPDATED FUNCTION SIGNATURE
        assetsInstance.updateAssetConfig(
            address(stableToken), // asset
            address(0), // oracle (will be set later)
            8, // oracleDecimals
            18, // assetDecimals
            1, // active
            950, // borrowThreshold (95%)
            980, // liquidationThreshold (98%)
            10_000_000e18, // maxSupplyLimit
            0, // isolationDebtCap (MOVED before tier)
            IASSETS.CollateralTier.STABLE, // tier
            IASSETS.OracleType.CHAINLINK // NEW parameter
        );

        vm.stopPrank();
    }
    // SECTION 1: ORACLE MANAGEMENT TESTS

    function test_UpdateMinimumOracles() public {
        vm.startPrank(address(timelockInstance));

        // Extract current config values from the oracleConfig struct
        // Store entire struct in a local variable
        (
            uint80 oldFreshness,
            uint80 oldVolatility,
            uint40 oldVolatilityPct,
            uint40 oldCircuitBreakerPct,
            uint16 oldMinOracles
        ) = assetsInstance.oracleConfig();

        // Update minimum oracles through updateOracleConfig
        vm.expectEmit(true, true, true, true);
        emit MinimumOraclesUpdated(oldMinOracles, 3); // Change from current value to 3

        // Call updateOracleConfig with the same values for all except minOracles
        assetsInstance.updateOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct),
            3 // New minimum oracles value
        );

        // Verify the update worked by accessing the struct again
        (,,,, uint256 newMinOracles) = assetsInstance.oracleConfig();

        assertEq(newMinOracles, 3, "Minimum oracles should be updated to 3");

        // Try to set invalid value (should revert)
        vm.expectRevert();
        assetsInstance.updateOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct),
            0 // Invalid value
        );

        vm.stopPrank();
    }

    function test_UpdateAssetMinimumOracles() public {
        vm.startPrank(address(timelockInstance));

        // Set asset-specific minimum oracles
        vm.expectEmit(true, true, true, true);
        emit AssetMinimumOraclesUpdated(address(wethInstance), 0, 2);

        assetsInstance.updateMinimumOracles(address(wethInstance), 2);

        // Verify the update worked
        uint256 minOracles = assetsInstance.assetMinimumOracles(address(wethInstance));
        assertEq(minOracles, 2, "Asset minimum oracles should be 2");

        // Try with a different value
        vm.expectEmit(true, true, true, true);
        emit AssetMinimumOraclesUpdated(address(wethInstance), 2, 3);

        assetsInstance.updateMinimumOracles(address(wethInstance), 3);

        // Verify the second update worked
        minOracles = assetsInstance.assetMinimumOracles(address(wethInstance));
        assertEq(minOracles, 3, "Asset minimum oracles should be updated to 3");

        vm.stopPrank();
    }

    // SECTION 2: THRESHOLD MANAGEMENT TESTS
    function test_UpdateFreshnessThreshold() public {
        vm.startPrank(address(timelockInstance));

        // Get current config values to preserve
        (, uint256 oldVolatility, uint256 oldVolatilityPct, uint256 oldCircuitBreakerPct, uint256 oldMinOracles) =
            assetsInstance.oracleConfig();

        // Update freshness threshold
        vm.expectEmit(true, true, true, true);
        emit FreshnessThresholdUpdated(28800, 7200); // Default is 8 hours (28800 seconds)

        assetsInstance.updateOracleConfig(
            7200, // 2 hours
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct),
            uint16(oldMinOracles)
        );

        // Try values outside valid range (should revert)
        vm.expectRevert();
        assetsInstance.updateOracleConfig(
            uint80(14 minutes), // Too small
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct),
            uint16(oldMinOracles)
        );

        vm.expectRevert();
        assetsInstance.updateOracleConfig(
            uint80(25 hours), // Too large
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct),
            uint16(oldMinOracles)
        );

        vm.stopPrank();
    }

    function test_UpdateVolatilityThreshold() public {
        vm.startPrank(address(timelockInstance));

        // Get current config values to preserve
        (uint256 oldFreshness,, uint256 oldVolatilityPct, uint256 oldCircuitBreakerPct, uint256 oldMinOracles) =
            assetsInstance.oracleConfig();

        // Update volatility threshold
        vm.expectEmit(true, true, true, true);
        emit VolatilityThresholdUpdated(3600, 1800); // Default is 1 hour (3600 seconds)

        assetsInstance.updateOracleConfig(
            uint80(oldFreshness),
            1800, // 30 minutes
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct),
            uint16(oldMinOracles)
        );

        // Try values outside valid range (should revert)
        vm.expectRevert();
        assetsInstance.updateOracleConfig(
            uint80(oldFreshness),
            uint80(4 minutes), // Too small
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct),
            uint16(oldMinOracles)
        );

        vm.expectRevert();
        assetsInstance.updateOracleConfig(
            uint80(oldFreshness),
            uint80(5 hours), // Too large
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct),
            uint16(oldMinOracles)
        );

        vm.stopPrank();
    }

    function test_UpdateVolatilityPercentage() public {
        vm.startPrank(address(timelockInstance));

        // Get current config values to preserve
        (uint256 oldFreshness, uint256 oldVolatility,, uint256 oldCircuitBreakerPct, uint256 oldMinOracles) =
            assetsInstance.oracleConfig();

        // Update volatility percentage
        vm.expectEmit(true, true, true, true);
        emit VolatilityPercentageUpdated(20, 15); // Default is 20%

        assetsInstance.updateOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            15, // 15%
            uint40(oldCircuitBreakerPct),
            uint16(oldMinOracles)
        );

        // Try values outside valid range (should revert)
        vm.expectRevert();
        assetsInstance.updateOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            4, // Too small
            uint40(oldCircuitBreakerPct),
            uint16(oldMinOracles)
        );

        vm.expectRevert();
        assetsInstance.updateOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            31, // Too large
            uint40(oldCircuitBreakerPct),
            uint16(oldMinOracles)
        );

        vm.stopPrank();
    }

    function test_UpdateCircuitBreakerThreshold() public {
        vm.startPrank(address(timelockInstance));

        // Get current config values to preserve
        (uint256 oldFreshness, uint256 oldVolatility, uint256 oldVolatilityPct,, uint256 oldMinOracles) =
            assetsInstance.oracleConfig();

        // Update circuit breaker threshold
        vm.expectEmit(true, true, true, true);
        emit CircuitBreakerThresholdUpdated(50, 35); // Default is 50%

        assetsInstance.updateOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            35, // 35%
            uint16(oldMinOracles)
        );

        // Try values outside valid range (should revert)
        vm.expectRevert();
        assetsInstance.updateOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            24, // Too small
            uint16(oldMinOracles)
        );

        vm.expectRevert();
        assetsInstance.updateOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            71, // Too large
            uint16(oldMinOracles)
        );

        vm.stopPrank();
    }

    // SECTION 3: PRICE FEED FUNCTIONALITY TESTS

    function test_GetSingleOraclePrice() public {
        vm.startPrank(address(timelockInstance));

        // Add oracle
        assetsInstance.addOracle(address(wethInstance), address(wethassetsInstance), 8, IASSETS.OracleType.CHAINLINK);

        // Get price
        uint256 price = assetsInstance.getSingleOraclePrice(address(wethassetsInstance));
        assertEq(price, 2000e8, "Should return correct price");

        vm.stopPrank();
    }

    function test_GetSingleOraclePrice_InvalidPrice() public {
        vm.startPrank(address(timelockInstance));

        // Configure oracle with invalid price
        mockOracle1.setPrice(0);
        assetsInstance.addOracle(address(wethInstance), address(mockOracle1), 8, IASSETS.OracleType.CHAINLINK);

        // Try to get price (should revert)
        vm.expectRevert();
        assetsInstance.getSingleOraclePrice(address(mockOracle1));

        mockOracle1.setPrice(-1);
        vm.expectRevert();
        assetsInstance.getSingleOraclePrice(address(mockOracle1));

        vm.stopPrank();
    }

    function test_GetSingleOraclePrice_StaleRound() public {
        vm.startPrank(address(timelockInstance));

        // Configure oracle with stale round
        mockOracle1.setRoundId(10);
        mockOracle1.setAnsweredInRound(5);
        assetsInstance.addOracle(address(wethInstance), address(mockOracle1), 8, IASSETS.OracleType.CHAINLINK);

        // Try to get price (should revert)
        vm.expectRevert();
        assetsInstance.getSingleOraclePrice(address(mockOracle1));

        vm.stopPrank();
    }

    function test_GetSingleOraclePrice_Timeout() public {
        vm.startPrank(address(timelockInstance));

        // Configure oracle with old timestamp
        mockOracle1.setTimestamp(block.timestamp - 9 hours); // Freshness threshold is 8 hours
        assetsInstance.addOracle(address(wethInstance), address(mockOracle1), 8, IASSETS.OracleType.CHAINLINK);

        // Try to get price (should revert)
        vm.expectRevert();
        assetsInstance.getSingleOraclePrice(address(mockOracle1));

        vm.stopPrank();
    }

    function test_GetSingleOraclePrice_VolatilityCheck() public {
        vm.startPrank(address(timelockInstance));

        // Setup round history
        mockOracle1.setRoundId(2);
        mockOracle1.setAnsweredInRound(2);
        mockOracle1.setPrice(2400e8); // 20% increase from previous round
        mockOracle1.setTimestamp(block.timestamp - 2 hours); // Older than volatility threshold (1 hour)

        // Set previous round data with large price difference
        mockOracle1.setHistoricalRoundData(1, 2000e8, block.timestamp - 3 hours, 1);

        assetsInstance.addOracle(address(wethInstance), address(mockOracle1), 8, IASSETS.OracleType.CHAINLINK);

        // Try to get price - should revert due to volatility with old timestamp
        vm.expectRevert();
        assetsInstance.getSingleOraclePrice(address(mockOracle1));

        // Now set timestamp to be fresh for volatility check
        mockOracle1.setTimestamp(block.timestamp - 30 minutes); // Within volatility threshold

        // This should succeed
        uint256 price = assetsInstance.getSingleOraclePrice(address(mockOracle1));
        assertEq(price, 2400e8, "Should allow volatile price if timestamp is fresh");

        vm.stopPrank();
    }

    function test_GetMedianPrice_Single() public {
        vm.startPrank(address(timelockInstance));

        // Get current config values to preserve
        (uint256 oldFreshness, uint256 oldVolatility, uint256 oldVolatilityPct, uint256 oldCircuitBreakerPct,) =
            assetsInstance.oracleConfig();

        // Set minimum required oracles to 1
        assetsInstance.updateOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct),
            1 // Set to 1
        );

        // Add a single oracle
        assetsInstance.addOracle(address(wethInstance), address(wethassetsInstance), 8, IASSETS.OracleType.CHAINLINK);

        // Get median price (with single oracle, should return that oracle's price)
        uint256 price = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2000e8, "Single oracle should return its price");

        vm.stopPrank();
    }

    function test_CircuitBreaker_ManualTrigger() public {
        vm.startPrank(address(timelockInstance));

        // Add oracle
        assetsInstance.addOracle(address(wethInstance), address(wethassetsInstance), 8, IASSETS.OracleType.CHAINLINK);

        // Verify initially not broken
        assertEq(assetsInstance.circuitBroken(address(wethInstance)), false, "Circuit should not be broken initially");

        // Trigger circuit breaker
        vm.expectEmit(true, true, true, true);
        emit CircuitBreakerTriggered(address(wethInstance), 0, 0);

        assetsInstance.triggerCircuitBreaker(address(wethInstance));

        // Verify circuit is broken
        assertEq(assetsInstance.circuitBroken(address(wethInstance)), true, "Circuit should be broken after trigger");

        // Try to get price - should revert with CircuitBreakerActive
        vm.expectRevert(abi.encodeWithSelector(CircuitBreakerActive.selector, address(wethInstance)));
        assetsInstance.getAssetPrice(address(wethInstance));

        vm.stopPrank();
    }

    function test_CircuitBreaker_Reset() public {
        vm.startPrank(address(timelockInstance));

        // Set minimum required oracles to 1
        assetsInstance.updateOracleConfig(
            uint80(28800), // Keep default freshness
            uint80(3600), // Keep default volatility
            uint40(20), // Keep default volatility %
            uint40(50), // Keep default circuit breaker %
            1 // Minimum 1 oracle
        );

        // Add oracle
        assetsInstance.addOracle(address(wethInstance), address(wethassetsInstance), 8, IASSETS.OracleType.CHAINLINK);

        // Trigger circuit breaker
        assetsInstance.triggerCircuitBreaker(address(wethInstance));

        // Reset circuit breaker
        vm.expectEmit(true, true, false, false);
        emit CircuitBreakerReset(address(wethInstance));

        assetsInstance.resetCircuitBreaker(address(wethInstance));

        // Verify circuit is reset
        assertEq(assetsInstance.circuitBroken(address(wethInstance)), false, "Circuit should be reset");

        // Should be able to get price again
        uint256 price = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2000e8, "Should return price after reset");

        vm.stopPrank();
    }

    function test_Integration_MultipleAssets() public {
        vm.startPrank(address(timelockInstance));

        // Set minimum required oracles to 1
        assetsInstance.updateOracleConfig(
            uint80(28800), // Keep default freshness
            uint80(3600), // Keep default volatility
            uint40(20), // Keep default volatility %
            uint40(50), // Keep default circuit breaker %
            1 // Minimum 1 oracle
        );

        // Set up multiple assets with their oracles - UPDATED WITH ORACLE TYPE
        assetsInstance.addOracle(address(wethInstance), address(wethassetsInstance), 8, IASSETS.OracleType.CHAINLINK);
        assetsInstance.addOracle(address(rwaToken), address(rwaassetsInstance), 8, IASSETS.OracleType.CHAINLINK);
        assetsInstance.addOracle(address(stableToken), address(stableassetsInstance), 8, IASSETS.OracleType.CHAINLINK);

        // Check each asset price
        uint256 wethPrice = assetsInstance.getAssetPrice(address(wethInstance));
        uint256 rwaPrice = assetsInstance.getAssetPrice(address(rwaToken));
        uint256 stablePrice = assetsInstance.getAssetPrice(address(stableToken));

        assertEq(wethPrice, 2000e8, "WETH price should be correct");
        assertEq(rwaPrice, 1000e8, "RWA price should be correct");
        assertEq(stablePrice, 1e8, "Stable price should be correct");

        // Now update one price and verify only that one changes
        wethassetsInstance.setPrice(2500e8);

        uint256 newWethPrice = assetsInstance.getAssetPrice(address(wethInstance));
        uint256 sameRwaPrice = assetsInstance.getAssetPrice(address(rwaToken));

        assertEq(newWethPrice, 2500e8, "WETH price should be updated");
        assertEq(sameRwaPrice, 1000e8, "RWA price should remain the same");

        vm.stopPrank();
    }

    function test_Integration_OracleSwitch() public {
        vm.startPrank(address(timelockInstance));

        // Use MockPriceOracle instead of WETHPriceConsumerV3 for testing timestamp behavior
        MockPriceOracle testOracle = new MockPriceOracle();
        testOracle.setPrice(2000e8);
        testOracle.setTimestamp(block.timestamp);
        testOracle.setRoundId(1);
        testOracle.setAnsweredInRound(1);

        // Configure for single oracle operation
        assetsInstance.updateOracleConfig(
            uint80(28800), // Keep default freshness
            uint80(3600), // Keep default volatility
            uint40(20), // Keep default volatility %
            uint40(50), // Keep default circuit breaker %
            1 // Minimum 1 oracle
        );

        // Start with this test oracle
        assetsInstance.addOracle(address(wethInstance), address(testOracle), 8, IASSETS.OracleType.CHAINLINK);

        // Get initial price
        uint256 initialPrice = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(initialPrice, 2000e8, "Initial price should be correct");

        // Make the oracle report stale prices
        testOracle.setTimestamp(block.timestamp - 9 hours);

        // Price fetch should fail with timeout error
        vm.expectRevert();
        assetsInstance.getAssetPrice(address(wethInstance));

        // Replace with a new working oracle using replaceOracle
        mockOracle1.setPrice(2100e8);
        mockOracle1.setTimestamp(block.timestamp);
        mockOracle1.setRoundId(1);
        mockOracle1.setAnsweredInRound(1);

        // Use replaceOracle to switch the CHAINLINK oracle
        assetsInstance.replaceOracle(address(wethInstance), IASSETS.OracleType.CHAINLINK, address(mockOracle1), 8);

        // Should now get price from the new oracle
        uint256 newPrice = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(newPrice, 2100e8, "Should get price from the new oracle");

        vm.stopPrank();
    }

    function test_AddOracle() public {
        vm.startPrank(address(timelockInstance));

        // Create separate assets for testing
        MockRWA asset1 = new MockRWA("Test Asset 1", "TA1");

        // Register the assets
        assetsInstance.updateAssetConfig(
            address(asset1),
            address(0), // Oracle will be set separately
            8,
            18,
            1,
            800,
            850,
            1_000_000 ether,
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );

        // Check initial state
        assertEq(assetsInstance.getOracleCount(address(asset1)), 0, "Should start with no oracles");

        // Test adding first oracle
        vm.expectEmit(true, true, false, false);
        emit OracleAdded(address(asset1), address(wethassetsInstance));
        emit PrimaryOracleSet(address(asset1), address(wethassetsInstance));

        assetsInstance.addOracle(address(asset1), address(wethassetsInstance), 8, IASSETS.OracleType.CHAINLINK);

        // Verify state after add
        assertEq(assetsInstance.getOracleCount(address(asset1)), 1, "Should have 1 oracle after add");
        assertEq(
            assetsInstance.primaryOracle(address(asset1)),
            address(wethassetsInstance),
            "First oracle should be set as primary"
        );

        // Add oracle of different type to same asset
        assetsInstance.addOracle(address(asset1), address(mockOracle1), 8, IASSETS.OracleType.UNISWAP_V3_TWAP);
        assertEq(assetsInstance.getOracleCount(address(asset1)), 2, "Should have 2 oracles after adds");

        // Try adding duplicate oracle type (should revert)
        vm.expectRevert(
            abi.encodeWithSelector(
                IASSETS.OracleTypeAlreadyAdded.selector, address(asset1), IASSETS.OracleType.CHAINLINK
            )
        );
        assetsInstance.addOracle(address(asset1), address(mockOracle2), 8, IASSETS.OracleType.CHAINLINK);

        vm.stopPrank();
    }

    function test_RemoveOracle() public {
        vm.startPrank(address(timelockInstance));

        // Create test asset
        MockRWA testAsset = new MockRWA("Test Asset", "TEST");

        // Register the asset
        assetsInstance.updateAssetConfig(
            address(testAsset),
            address(0),
            8,
            18,
            1,
            800,
            850,
            1_000_000 ether,
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );

        // Setup - add 2 oracles with different types
        assetsInstance.addOracle(address(testAsset), address(wethassetsInstance), 8, IASSETS.OracleType.CHAINLINK);
        assetsInstance.addOracle(address(testAsset), address(mockOracle1), 8, IASSETS.OracleType.UNISWAP_V3_TWAP);

        // Remove an oracle
        vm.expectEmit(true, true, false, false);
        emit OracleRemoved(address(testAsset), address(mockOracle1));

        assetsInstance.removeOracle(address(testAsset), address(mockOracle1));

        // Verify state after removal
        assertEq(assetsInstance.getOracleCount(address(testAsset)), 1, "Should have 1 oracle after removal");

        // Check that getAssetOracles returns the correct oracles
        address[] memory oracles = assetsInstance.getAssetOracles(address(testAsset));
        assertEq(oracles.length, 1, "Should return 1 oracle");
        assertEq(oracles[0], address(wethassetsInstance), "Remaining oracle should be wethOracle");

        vm.stopPrank();
    }

    function test_SetPrimaryOracle() public {
        vm.startPrank(address(timelockInstance));

        // Create test asset
        MockRWA testAsset = new MockRWA("Test Asset", "TEST");

        // Register the asset
        assetsInstance.updateAssetConfig(
            address(testAsset),
            address(0),
            8,
            18,
            1,
            800,
            850,
            1_000_000 ether,
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );

        // Setup - add 2 oracles with different types
        assetsInstance.addOracle(address(testAsset), address(wethassetsInstance), 8, IASSETS.OracleType.CHAINLINK);
        assetsInstance.addOracle(address(testAsset), address(mockOracle1), 8, IASSETS.OracleType.UNISWAP_V3_TWAP);

        // Check initial primary oracle
        assertEq(
            assetsInstance.primaryOracle(address(testAsset)),
            address(wethassetsInstance),
            "Initial primary oracle should be first added"
        );

        // Change primary oracle
        vm.expectEmit(true, true, false, false);
        emit PrimaryOracleSet(address(testAsset), address(mockOracle1));

        assetsInstance.setPrimaryOracle(address(testAsset), address(mockOracle1));

        // Verify new primary oracle
        assertEq(
            assetsInstance.primaryOracle(address(testAsset)), address(mockOracle1), "Primary oracle should be updated"
        );

        // Try setting non-existent oracle as primary (should revert)
        vm.expectRevert();
        assetsInstance.setPrimaryOracle(address(testAsset), address(mockOracle3));

        vm.stopPrank();
    }

    function test_RemovePrimaryOracle() public {
        vm.startPrank(address(timelockInstance));

        // Create test asset
        MockRWA testAsset = new MockRWA("Test Asset", "TEST");

        // Register the asset
        assetsInstance.updateAssetConfig(
            address(testAsset),
            address(0),
            8,
            18,
            1,
            800,
            850,
            1_000_000 ether,
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );

        // Setup - add primary oracle
        assetsInstance.addOracle(address(testAsset), address(wethassetsInstance), 8, IASSETS.OracleType.CHAINLINK);

        // Remove the primary oracle
        assetsInstance.removeOracle(address(testAsset), address(wethassetsInstance));

        // Primary should be cleared
        assertEq(
            assetsInstance.primaryOracle(address(testAsset)),
            address(0),
            "Primary oracle should be cleared when removed"
        );

        // Now with two oracles of different types
        assetsInstance.addOracle(address(testAsset), address(wethassetsInstance), 8, IASSETS.OracleType.CHAINLINK);
        assetsInstance.addOracle(address(testAsset), address(mockOracle1), 8, IASSETS.OracleType.UNISWAP_V3_TWAP);

        // Set mockOracle1 as primary
        assetsInstance.setPrimaryOracle(address(testAsset), address(mockOracle1));

        // Remove primary oracle
        assetsInstance.removeOracle(address(testAsset), address(mockOracle1));

        // wethOracle should now be primary
        assertEq(
            assetsInstance.primaryOracle(address(testAsset)),
            address(wethassetsInstance),
            "The remaining oracle should be set as primary"
        );

        vm.stopPrank();
    }

    function test_Integration_DecimalHandling() public {
        vm.startPrank(address(timelockInstance));

        // Create separate test assets
        MockRWA asset1 = new MockRWA("Test Asset 1", "TA1");
        MockRWA asset2 = new MockRWA("Test Asset 2", "TA2");
        MockRWA asset3 = new MockRWA("Test Asset 3", "TA3");

        // Register the assets
        assetsInstance.updateAssetConfig(
            address(asset1),
            address(0),
            8,
            18,
            1,
            800,
            850,
            1_000_000 ether,
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );

        assetsInstance.updateAssetConfig(
            address(asset2),
            address(0),
            8,
            18,
            1,
            800,
            850,
            1_000_000 ether,
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );

        assetsInstance.updateAssetConfig(
            address(asset3),
            address(0),
            8,
            18,
            1,
            800,
            850,
            1_000_000 ether,
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );

        // Setup oracles with different decimals
        mockOracle1.setPrice(200e8);
        mockOracle1.setTimestamp(block.timestamp);
        mockOracle1.setRoundId(1);
        mockOracle1.setAnsweredInRound(1);

        mockOracle2.setPrice(20e8);
        mockOracle2.setTimestamp(block.timestamp);
        mockOracle2.setRoundId(1);
        mockOracle2.setAnsweredInRound(1);

        mockOracle3.setPrice(2e8);
        mockOracle3.setTimestamp(block.timestamp);
        mockOracle3.setRoundId(1);
        mockOracle3.setAnsweredInRound(1);

        // Add oracles to different assets
        assetsInstance.addOracle(address(asset1), address(mockOracle1), 12, IASSETS.OracleType.CHAINLINK);
        assetsInstance.addOracle(address(asset2), address(mockOracle2), 4, IASSETS.OracleType.CHAINLINK);
        assetsInstance.addOracle(address(asset3), address(mockOracle3), 8, IASSETS.OracleType.CHAINLINK);

        // Test the single oracle price retrieval for each oracle
        uint256 price1 = assetsInstance.getSingleOraclePrice(address(mockOracle1));
        assertEq(price1, 200e8, "Should normalize price to 8 decimals");

        uint256 price2 = assetsInstance.getSingleOraclePrice(address(mockOracle2));
        assertEq(price2, 20e8, "Should normalize price to 8 decimals");

        uint256 price3 = assetsInstance.getSingleOraclePrice(address(mockOracle3));
        assertEq(price3, 2e8, "Already at 8 decimals");

        vm.stopPrank();
    }
}
