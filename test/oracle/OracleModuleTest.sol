// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {LendefiOracle} from "../../contracts/oracle/LendefiOracle.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {AggregatorV3Interface} from
    "../../contracts/vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract OracleModuleTest is BasicDeploy {
    // Test tokens
    MockRWA internal rwaToken;
    MockRWA internal stableToken;

    // Mock oracles
    MockPriceOracle internal mockOracle1;
    MockPriceOracle internal mockOracle2;
    MockPriceOracle internal mockOracle3;
    WETHPriceConsumerV3 internal wethOracleInstance;
    RWAPriceConsumerV3 internal rwaOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

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

    function setUp() public {
        // Initial deployment with oracle
        deployCompleteWithOracle();

        // Deploy test tokens
        wethInstance = new WETH9();
        rwaToken = new MockRWA("RWA Token", "RWA");
        stableToken = new MockRWA("USDT", "USDT");

        // Deploy price feeds
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Deploy mock oracles for more controlled testing
        mockOracle1 = new MockPriceOracle();
        mockOracle2 = new MockPriceOracle();
        mockOracle3 = new MockPriceOracle();

        // Set initial prices
        wethOracleInstance.setPrice(2000e8); // $2000 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token
        stableOracleInstance.setPrice(1e8); // $1 per stable token

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
    }

    // SECTION 1: ORACLE MANAGEMENT TESTS

    function test_AddOracle() public {
        vm.startPrank(address(timelockInstance));

        // Check initial state
        assertEq(oracleInstance.getOracleCount(address(wethInstance)), 0, "Should start with no oracles");

        // Test adding first oracle
        vm.expectEmit(true, true, false, false);
        emit OracleAdded(address(wethInstance), address(wethOracleInstance));
        emit PrimaryOracleSet(address(wethInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);

        // Verify state after add
        assertEq(oracleInstance.getOracleCount(address(wethInstance)), 1, "Should have 1 oracle after add");
        assertEq(
            oracleInstance.primaryOracle(address(wethInstance)),
            address(wethOracleInstance),
            "First oracle should be set as primary"
        );

        // Add more oracles
        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle2), 8);

        // Verify final state
        assertEq(oracleInstance.getOracleCount(address(wethInstance)), 3, "Should have 3 oracles after adds");

        // Try adding duplicate oracle (should revert)
        vm.expectRevert();
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);

        vm.stopPrank();
    }

    function test_RemoveOracle() public {
        vm.startPrank(address(timelockInstance));

        // Setup - add 3 oracles
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle2), 8);

        // Remove an oracle
        vm.expectEmit(true, true, false, false);
        emit OracleRemoved(address(wethInstance), address(mockOracle1));

        oracleInstance.removeOracle(address(wethInstance), address(mockOracle1));

        // Verify state after removal
        assertEq(oracleInstance.getOracleCount(address(wethInstance)), 2, "Should have 2 oracles after removal");

        // Check that getAssetOracles returns the correct oracles
        address[] memory oracles = oracleInstance.getAssetOracles(address(wethInstance));
        assertEq(oracles.length, 2, "Should return 2 oracles");

        // The removed oracle should not be in the returned array
        for (uint256 i = 0; i < oracles.length; i++) {
            if (oracles[i] == address(mockOracle1)) {
                fail("Removed oracle should not be in the list");
            }
        }

        vm.stopPrank();
    }

    function test_SetPrimaryOracle() public {
        vm.startPrank(address(timelockInstance));

        // Setup - add 3 oracles
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle2), 8);

        // Check initial primary oracle
        assertEq(
            oracleInstance.primaryOracle(address(wethInstance)),
            address(wethOracleInstance),
            "Initial primary oracle should be first added"
        );

        // Change primary oracle
        vm.expectEmit(true, true, false, false);
        emit PrimaryOracleSet(address(wethInstance), address(mockOracle2));

        oracleInstance.setPrimaryOracle(address(wethInstance), address(mockOracle2));

        // Verify new primary oracle
        assertEq(
            oracleInstance.primaryOracle(address(wethInstance)),
            address(mockOracle2),
            "Primary oracle should be updated"
        );

        // Try setting non-existent oracle as primary (should revert)
        vm.expectRevert();
        oracleInstance.setPrimaryOracle(address(wethInstance), address(mockOracle3));

        vm.stopPrank();
    }

    function test_RemovePrimaryOracle() public {
        vm.startPrank(address(timelockInstance));

        // Setup - add primary oracle
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);

        // Remove the primary oracle
        oracleInstance.removeOracle(address(wethInstance), address(wethOracleInstance));

        // Primary should be cleared
        assertEq(
            oracleInstance.primaryOracle(address(wethInstance)),
            address(0),
            "Primary oracle should be cleared when removed"
        );

        // Now with multiple oracles
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle2), 8);

        // Set mockOracle1 as primary
        oracleInstance.setPrimaryOracle(address(wethInstance), address(mockOracle1));

        // Remove primary oracle
        oracleInstance.removeOracle(address(wethInstance), address(mockOracle1));

        // A different oracle should now be primary
        assertEq(
            oracleInstance.primaryOracle(address(wethInstance)) != address(mockOracle1)
                && oracleInstance.primaryOracle(address(wethInstance)) != address(0),
            true,
            "A new primary oracle should be selected"
        );

        vm.stopPrank();
    }

    function test_UpdateMinimumOracles() public {
        vm.startPrank(address(timelockInstance));

        // Update minimum oracles
        vm.expectEmit(true, true, true, true);
        emit MinimumOraclesUpdated(2, 3); // Default is 2

        oracleInstance.updateMinimumOracles(3);

        // Try to set invalid value (should revert)
        vm.expectRevert();
        oracleInstance.updateMinimumOracles(0);

        vm.stopPrank();
    }

    function test_UpdateAssetMinimumOracles() public {
        vm.startPrank(address(timelockInstance));

        // Set asset-specific minimum oracles
        vm.expectEmit(true, true, true, true);
        emit AssetMinimumOraclesUpdated(address(wethInstance), 0, 2);

        oracleInstance.updateAssetMinimumOracles(address(wethInstance), 2);

        // Try with a different value
        vm.expectEmit(true, true, true, true);
        emit AssetMinimumOraclesUpdated(address(wethInstance), 2, 3);

        oracleInstance.updateAssetMinimumOracles(address(wethInstance), 3);

        vm.stopPrank();
    }

    // SECTION 2: THRESHOLD MANAGEMENT TESTS

    function test_UpdateFreshnessThreshold() public {
        vm.startPrank(address(timelockInstance));

        // Update freshness threshold
        vm.expectEmit(true, true, true, true);
        emit FreshnessThresholdUpdated(28800, 7200); // Default is 8 hours (28800 seconds)

        oracleInstance.updateFreshnessThreshold(7200); // 2 hours

        // Try values outside valid range (should revert)
        vm.expectRevert();
        oracleInstance.updateFreshnessThreshold(14 minutes); // Too small

        vm.expectRevert();
        oracleInstance.updateFreshnessThreshold(25 hours); // Too large

        vm.stopPrank();
    }

    function test_UpdateVolatilityThreshold() public {
        vm.startPrank(address(timelockInstance));

        // Update volatility threshold
        vm.expectEmit(true, true, true, true);
        emit VolatilityThresholdUpdated(3600, 1800); // Default is 1 hour (3600 seconds)

        oracleInstance.updateVolatilityThreshold(1800); // 30 minutes

        // Try values outside valid range (should revert)
        vm.expectRevert();
        oracleInstance.updateVolatilityThreshold(4 minutes); // Too small

        vm.expectRevert();
        oracleInstance.updateVolatilityThreshold(5 hours); // Too large

        vm.stopPrank();
    }

    function test_UpdateVolatilityPercentage() public {
        vm.startPrank(address(timelockInstance));

        // Update volatility percentage
        vm.expectEmit(true, true, true, true);
        emit VolatilityPercentageUpdated(20, 15); // Default is 20%

        oracleInstance.updateVolatilityPercentage(15); // 15%

        // Try values outside valid range (should revert)
        vm.expectRevert();
        oracleInstance.updateVolatilityPercentage(4); // Too small

        vm.expectRevert();
        oracleInstance.updateVolatilityPercentage(31); // Too large

        vm.stopPrank();
    }

    function test_UpdateCircuitBreakerThreshold() public {
        vm.startPrank(address(timelockInstance));

        // Update circuit breaker threshold
        vm.expectEmit(true, true, true, true);
        emit CircuitBreakerThresholdUpdated(50, 35); // Default is 50%

        oracleInstance.updateCircuitBreakerThreshold(35); // 35%

        // Try values outside valid range (should revert)
        vm.expectRevert();
        oracleInstance.updateCircuitBreakerThreshold(24); // Too small

        vm.expectRevert();
        oracleInstance.updateCircuitBreakerThreshold(71); // Too large

        vm.stopPrank();
    }

    // SECTION 3: PRICE FEED FUNCTIONALITY TESTS

    function test_GetSingleOraclePrice() public {
        vm.startPrank(address(timelockInstance));

        // Add oracle
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);

        // Get price
        uint256 price = oracleInstance.getSingleOraclePrice(address(wethOracleInstance));
        assertEq(price, 2000e8, "Should return correct price");

        vm.stopPrank();
    }

    function test_GetSingleOraclePrice_InvalidPrice() public {
        vm.startPrank(address(timelockInstance));

        // Configure oracle with invalid price
        mockOracle1.setPrice(0);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8);

        // Try to get price (should revert)
        vm.expectRevert();
        oracleInstance.getSingleOraclePrice(address(mockOracle1));

        mockOracle1.setPrice(-1);
        vm.expectRevert();
        oracleInstance.getSingleOraclePrice(address(mockOracle1));

        vm.stopPrank();
    }

    function test_GetSingleOraclePrice_StaleRound() public {
        vm.startPrank(address(timelockInstance));

        // Configure oracle with stale round
        mockOracle1.setRoundId(10);
        mockOracle1.setAnsweredInRound(5);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8);

        // Try to get price (should revert)
        vm.expectRevert();
        oracleInstance.getSingleOraclePrice(address(mockOracle1));

        vm.stopPrank();
    }

    function test_GetSingleOraclePrice_Timeout() public {
        vm.startPrank(address(timelockInstance));

        // Configure oracle with old timestamp
        mockOracle1.setTimestamp(block.timestamp - 9 hours); // Freshness threshold is 8 hours
        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8);

        // Try to get price (should revert)
        vm.expectRevert();
        oracleInstance.getSingleOraclePrice(address(mockOracle1));

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

        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8);

        // Try to get price - should revert due to volatility with old timestamp
        vm.expectRevert();
        oracleInstance.getSingleOraclePrice(address(mockOracle1));

        // Now set timestamp to be fresh for volatility check
        mockOracle1.setTimestamp(block.timestamp - 30 minutes); // Within volatility threshold

        // This should succeed
        uint256 price = oracleInstance.getSingleOraclePrice(address(mockOracle1));
        assertEq(price, 2400e8, "Should allow volatile price if timestamp is fresh");

        vm.stopPrank();
    }

    function test_GetMedianPrice_Single() public {
        vm.startPrank(address(timelockInstance));

        // Set minimum required oracles to 1
        oracleInstance.updateMinimumOracles(1);

        // Add a single oracle
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);

        // Get median price (with single oracle, should return that oracle's price)
        uint256 price = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2000e8, "Single oracle should return its price");

        vm.stopPrank();
    }

    function test_GetMedianPrice_Multiple() public {
        vm.startPrank(address(timelockInstance));

        // Add multiple oracles with different prices
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8); // 2000
        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8); // 2010
        oracleInstance.addOracle(address(wethInstance), address(mockOracle2), 8); // 1990

        // Get median price (should be the middle value)
        uint256 price = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2000e8, "Median of 3 oracles should be middle value");

        vm.stopPrank();
    }

    function test_GetMedianPrice_MultipleWithOddDecimals() public {
        vm.startPrank(address(timelockInstance));

        // Add multiple oracles with different decimals
        mockOracle1.setPrice(201000000000); // 2010 with 11 decimals
        mockOracle2.setPrice(19900000); // 1990 with 6 decimals

        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8); // 2000 with 8 decimals
        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 11); // 2010 with 11 decimals
        oracleInstance.addOracle(address(wethInstance), address(mockOracle2), 6); // 1990 with 6 decimals

        // Get median price (should be the middle value, normalized to 8 decimals)
        uint256 price = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2000e8, "Median should handle different oracle decimals");

        vm.stopPrank();
    }

    function test_GetMedianPrice_EvenNumber() public {
        vm.startPrank(address(timelockInstance));

        // Add 4 oracles
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8); // 2000
        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8); // 2010
        oracleInstance.addOracle(address(wethInstance), address(mockOracle2), 8); // 1990

        // Setup additional oracle with a different price
        mockOracle3.setPrice(1980e8);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle3), 8); // 1980

        // Get median price (should be average of middle two values)
        uint256 price = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 1995e8, "Median of 4 oracles should be average of middle two");

        vm.stopPrank();
    }

    function test_GetMedianPrice_InvalidOracles() public {
        vm.startPrank(address(timelockInstance));

        // First set minimum required oracles to 1
        oracleInstance.updateMinimumOracles(1);

        // Add three oracles, but make two invalid
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8); // Valid

        // Setup invalid oracles
        mockOracle1.setPrice(-1); // Negative price
        mockOracle2.setTimestamp(block.timestamp - 9 hours); // Timestamp too old

        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8); // Invalid
        oracleInstance.addOracle(address(wethInstance), address(mockOracle2), 8); // Invalid

        // Get median price - should only use the valid oracle
        uint256 price = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2000e8, "Should use only valid oracle");

        vm.stopPrank();
    }

    // SECTION 4: CIRCUIT BREAKER TESTS

    function test_CircuitBreaker_ManualTrigger() public {
        vm.startPrank(address(timelockInstance));

        // Add oracle
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);

        // Verify initially not broken
        assertEq(oracleInstance.circuitBroken(address(wethInstance)), false, "Circuit should not be broken initially");

        // Trigger circuit breaker
        vm.expectEmit(true, true, true, true);
        emit CircuitBreakerTriggered(address(wethInstance), 0, 0);

        oracleInstance.triggerCircuitBreaker(address(wethInstance));

        // Verify circuit is broken
        assertEq(oracleInstance.circuitBroken(address(wethInstance)), true, "Circuit should be broken after trigger");

        // Try to get price (should revert)
        vm.expectRevert();
        oracleInstance.getAssetPrice(address(wethInstance));

        vm.stopPrank();
    }

    function test_CircuitBreaker_Reset() public {
        vm.startPrank(address(timelockInstance));
        // Set minimum required oracles to 1
        oracleInstance.updateMinimumOracles(1);
        // Add oracle
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);

        // Trigger circuit breaker
        oracleInstance.triggerCircuitBreaker(address(wethInstance));

        // Reset circuit breaker
        vm.expectEmit(true, true, false, false);
        emit CircuitBreakerReset(address(wethInstance));

        oracleInstance.resetCircuitBreaker(address(wethInstance));

        // Verify circuit is reset
        assertEq(oracleInstance.circuitBroken(address(wethInstance)), false, "Circuit should be reset");

        // Should be able to get price again
        uint256 price = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2000e8, "Should return price after reset");

        vm.stopPrank();
    }

    // SECTION 5: INTEGRATION TESTS

    function test_Integration_MultipleAssets() public {
        vm.startPrank(address(timelockInstance));

        // Set minimum required oracles to 1
        oracleInstance.updateMinimumOracles(1);

        // Set up multiple assets with their oracles
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.addOracle(address(rwaToken), address(rwaOracleInstance), 8);
        oracleInstance.addOracle(address(stableToken), address(stableOracleInstance), 8);

        // Check each asset price
        uint256 wethPrice = oracleInstance.getAssetPrice(address(wethInstance));
        uint256 rwaPrice = oracleInstance.getAssetPrice(address(rwaToken));
        uint256 stablePrice = oracleInstance.getAssetPrice(address(stableToken));

        assertEq(wethPrice, 2000e8, "WETH price should be correct");
        assertEq(rwaPrice, 1000e8, "RWA price should be correct");
        assertEq(stablePrice, 1e8, "Stable price should be correct");

        // Now update one price and verify only that one changes
        wethOracleInstance.setPrice(2500e8);

        uint256 newWethPrice = oracleInstance.getAssetPrice(address(wethInstance));
        uint256 sameRwaPrice = oracleInstance.getAssetPrice(address(rwaToken));

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

        // Start with this test oracle
        oracleInstance.addOracle(address(wethInstance), address(testOracle), 8);
        oracleInstance.updateMinimumOracles(1);

        // Get initial price
        uint256 initialPrice = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(initialPrice, 2000e8, "Initial price should be correct");

        // Make the oracle report stale prices
        testOracle.setTimestamp(block.timestamp - 9 hours);

        // Price fetch should fail
        vm.expectRevert();
        oracleInstance.getAssetPrice(address(wethInstance));

        // Add a new working oracle
        mockOracle1.setPrice(2100e8);
        mockOracle1.setTimestamp(block.timestamp);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8);

        // Should now get price from the new oracle
        uint256 newPrice = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(newPrice, 2100e8, "Should get price from the new oracle");

        vm.stopPrank();
    }

    function test_Integration_DecimalHandling() public {
        vm.startPrank(address(timelockInstance));

        // Setup oracles with different decimals
        mockOracle1.setPrice(2000000000000); // 2000 with 12 decimals
        mockOracle2.setPrice(20000); // 2000 with 4 decimals
        mockOracle3.setPrice(2000e8); // 2000 with 8 decimals

        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 12);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle2), 4);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle3), 8);

        // Get median price - all should be normalized to 8 decimals
        uint256 price = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2000e8, "Should normalize all prices to 8 decimals");

        vm.stopPrank();
    }

    function test_SingleOracle_VolatilityProtection() public {
        vm.startPrank(address(timelockInstance));

        // Create a fresh mock oracle with controlled behavior
        MockPriceOracle testOracle = new MockPriceOracle();

        // Set initial data for round 1
        testOracle.setPrice(2000e8);
        testOracle.setTimestamp(block.timestamp);
        testOracle.setRoundId(1);
        testOracle.setAnsweredInRound(1);

        // Add our test oracle and allow single oracle operation
        oracleInstance.updateMinimumOracles(1);
        oracleInstance.addOracle(address(wethInstance), address(testOracle), 8);

        // First get the initial price to establish baseline
        uint256 initialPrice = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(initialPrice, 2000e8, "Initial price should be correct");

        // Now move to round 2 with a large price increase (25%)
        // First store round 1 data so we can retrieve it later
        testOracle.setHistoricalRoundData(1, 2000e8, block.timestamp, 1);

        // Setup round 2
        testOracle.setRoundId(2);
        testOracle.setPrice(2500e8); // 25% increase

        // Set timestamp that's still fresh enough for general queries but older than volatilityThreshold
        testOracle.setTimestamp(block.timestamp - 2 hours); // Older than volatilityThreshold (1 hour)
        testOracle.setAnsweredInRound(2);

        // This should trigger OracleInvalidPriceVolatility
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleInvalidPriceVolatility.selector,
                address(testOracle),
                2500e8, // new price
                25 // percent change
            )
        );
        oracleInstance.getAssetPrice(address(wethInstance));

        // However, if we make the timestamp fresh (within volatilityThreshold)
        // it should succeed even with the large price change
        testOracle.setTimestamp(block.timestamp - 30 minutes); // Fresher than volatilityThreshold

        uint256 updatedPrice = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(updatedPrice, 2500e8, "Should allow volatile price if timestamp is fresh");

        vm.stopPrank();
    }

    // 1. Fix test_CircuitBreaker_AutoTrigger()
    function test_CircuitBreaker_AutoTrigger() public {
        vm.startPrank(address(timelockInstance));

        // Set minimum required oracles to 2 since we're using two oracles
        oracleInstance.updateMinimumOracles(2);

        // Use two oracles with identical initial data
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.addOracle(address(wethInstance), address(mockOracle1), 8);

        wethOracleInstance.setPrice(2000e8);
        mockOracle1.setPrice(2000e8);
        mockOracle1.setTimestamp(block.timestamp);

        // CRITICAL: First get the price to establish lastValidPrice
        uint256 initialPrice = oracleInstance.getAssetPrice(address(wethInstance));
        console2.log("Initial price set:", initialPrice);

        // Verify lastValidPrice was updated
        uint256 storedPrice = oracleInstance.lastValidPrice(address(wethInstance));
        console2.log("Stored price:", storedPrice);
        assertEq(storedPrice, initialPrice, "Last valid price should be set");

        // Now change prices dramatically (>50% change to trigger circuit breaker)
        uint256 newPrice = initialPrice * 155 / 100; // 55% increase
        wethOracleInstance.setPrice(int256(newPrice));
        mockOracle1.setPrice(int256(newPrice));

        // Calculate expected percentage change
        uint256 percentChange = ((newPrice - initialPrice) * 100) / initialPrice;
        console2.log("Percent change:", percentChange);

        // THIS SHOULD NOW WORK: Circuit breaker should trigger
        vm.expectRevert(
            abi.encodeWithSelector(
                LargeDeviation.selector, address(wethInstance), newPrice, initialPrice, percentChange
            )
        );
        oracleInstance.getAssetPrice(address(wethInstance));

        vm.stopPrank();
    }

    // 3. Fix test_Integration_PriceMonitoring()
    function test_Integration_PriceMonitoring() public {
        vm.startPrank(address(timelockInstance));

        // Create test oracles
        MockPriceOracle testOracle1 = new MockPriceOracle();
        MockPriceOracle testOracle2 = new MockPriceOracle();

        // Initial setup
        testOracle1.setPrice(2000e8);
        testOracle1.setTimestamp(block.timestamp);
        testOracle1.setRoundId(1);
        testOracle1.setAnsweredInRound(1);

        testOracle2.setPrice(2000e8);
        testOracle2.setTimestamp(block.timestamp);
        testOracle2.setRoundId(1);
        testOracle2.setAnsweredInRound(1);

        // Add oracles
        oracleInstance.updateMinimumOracles(2);
        oracleInstance.addOracle(address(wethInstance), address(testOracle1), 8);
        oracleInstance.addOracle(address(wethInstance), address(testOracle2), 8);

        // CRITICAL: Get initial price to establish lastValidPrice
        uint256 initialPrice = oracleInstance.getAssetPrice(address(wethInstance));
        console2.log("Initial monitoring price:", initialPrice);

        // Verify lastValidPrice was set
        uint256 storedPrice = oracleInstance.lastValidPrice(address(wethInstance));
        console2.log("Stored initial price:", storedPrice);
        assertEq(storedPrice, initialPrice, "Initial price should be stored");

        // First small price change
        vm.warp(block.timestamp + 1 hours);
        testOracle1.setHistoricalRoundData(1, 2000e8, block.timestamp - 1 hours, 1);
        testOracle1.setRoundId(2);
        testOracle1.setPrice(2100e8);
        testOracle1.setTimestamp(block.timestamp);
        testOracle1.setAnsweredInRound(2);

        testOracle2.setHistoricalRoundData(1, 2000e8, block.timestamp - 1 hours, 1);
        testOracle2.setRoundId(2);
        testOracle2.setPrice(2100e8);
        testOracle2.setTimestamp(block.timestamp);
        testOracle2.setAnsweredInRound(2);

        // Update stored price
        uint256 price1 = oracleInstance.getAssetPrice(address(wethInstance));
        console2.log("Updated price 1:", price1);

        // Second price update
        vm.warp(block.timestamp + 1 hours);
        testOracle1.setHistoricalRoundData(2, 2100e8, block.timestamp - 1 hours, 2);
        testOracle1.setRoundId(3);
        testOracle1.setPrice(2200e8);
        testOracle1.setTimestamp(block.timestamp);
        testOracle1.setAnsweredInRound(3);

        testOracle2.setHistoricalRoundData(2, 2100e8, block.timestamp - 1 hours, 2);
        testOracle2.setRoundId(3);
        testOracle2.setPrice(2200e8);
        testOracle2.setTimestamp(block.timestamp);
        testOracle2.setAnsweredInRound(3);

        // Update stored price
        uint256 price2 = oracleInstance.getAssetPrice(address(wethInstance));
        console2.log("Updated price 2:", price2);

        // Verify the last price was stored
        uint256 lastStored = oracleInstance.lastValidPrice(address(wethInstance));
        console2.log("Last stored price:", lastStored);
        assertEq(lastStored, 2200e8, "Last price should be 2200e8");

        // Make a dramatic price change (100% increase)
        vm.warp(block.timestamp + 1 hours);
        testOracle1.setHistoricalRoundData(3, 2200e8, block.timestamp - 1 hours, 3);
        testOracle1.setRoundId(4);
        testOracle1.setPrice(4400e8);
        testOracle1.setTimestamp(block.timestamp);
        testOracle1.setAnsweredInRound(4);

        testOracle2.setHistoricalRoundData(3, 2200e8, block.timestamp - 1 hours, 3);
        testOracle2.setRoundId(4);
        testOracle2.setPrice(4400e8);
        testOracle2.setTimestamp(block.timestamp);
        testOracle2.setAnsweredInRound(4);

        // Calculate percentage change
        uint256 percentChange = ((4400e8 - 2200e8) * 100) / 2200e8;
        console2.log("Calculated percent change:", percentChange);

        // Now this should trigger circuit breaker
        vm.expectRevert(
            abi.encodeWithSelector(LargeDeviation.selector, address(wethInstance), 4400e8, 2200e8, percentChange)
        );
        oracleInstance.getAssetPrice(address(wethInstance));

        vm.stopPrank();
    }

    function test_Integration_CircuitBreakerRecovery() public {
        vm.startPrank(address(timelockInstance));

        // CRITICAL: Use two oracles for circuit breaker test
        // With a single oracle, the circuit breaker code is never reached

        // Create two fresh oracles that we fully control
        MockPriceOracle testOracle1 = new MockPriceOracle();
        MockPriceOracle testOracle2 = new MockPriceOracle();

        // Set initial data
        testOracle1.setPrice(2000e8);
        testOracle1.setTimestamp(block.timestamp);
        testOracle1.setRoundId(1);
        testOracle1.setAnsweredInRound(1);

        testOracle2.setPrice(2000e8);
        testOracle2.setTimestamp(block.timestamp);
        testOracle2.setRoundId(1);
        testOracle2.setAnsweredInRound(1);

        // Make sure circuit breaker threshold is at default 50%
        oracleInstance.updateCircuitBreakerThreshold(50);

        // We need at least 2 oracles for the median calculation path
        oracleInstance.updateMinimumOracles(2);
        oracleInstance.addOracle(address(wethInstance), address(testOracle1), 8);
        oracleInstance.addOracle(address(wethInstance), address(testOracle2), 8);

        // Get initial price and save it - this establishes lastValidPrice
        uint256 initialPrice = oracleInstance.getAssetPrice(address(wethInstance));
        console2.log("Initial price:", initialPrice);

        // Verify that lastValidPrice was set
        uint256 storedPrice = oracleInstance.lastValidPrice(address(wethInstance));
        assertEq(storedPrice, initialPrice, "lastValidPrice should be set");

        // Ensure we're using a MUCH larger price to guarantee circuit breaker (100% change)
        uint256 newPrice = initialPrice * 2; // 100% increase
        testOracle1.setPrice(int256(newPrice));
        testOracle2.setPrice(int256(newPrice));

        console2.log("New price:", newPrice);

        // Calculate exact percentage
        uint256 percentChange = ((newPrice - initialPrice) * 100) / initialPrice;
        console2.log("Percent change:", percentChange);

        // Try to get the new price - this should revert with LargeDeviation
        vm.expectRevert(
            abi.encodeWithSelector(
                LargeDeviation.selector, address(wethInstance), newPrice, initialPrice, percentChange
            )
        );
        oracleInstance.getAssetPrice(address(wethInstance));

        vm.stopPrank();
    }

    function test_GetMedianPrice_NotEnoughValidOracles() public {
        vm.startPrank(address(timelockInstance));

        // Set minimum required oracles to 2
        oracleInstance.updateMinimumOracles(2);

        // First clear any existing oracles
        address[] memory existingOracles = oracleInstance.getAssetOracles(address(wethInstance));
        for (uint256 i = 0; i < existingOracles.length; i++) {
            oracleInstance.removeOracle(address(wethInstance), existingOracles[i]);
        }

        // Create a valid oracle
        MockPriceOracle validOracle = new MockPriceOracle();
        validOracle.setPrice(2000e8);
        validOracle.setTimestamp(block.timestamp);
        validOracle.setRoundId(1);
        validOracle.setAnsweredInRound(1);

        // Create an explicitly invalid oracle
        MockPriceOracle invalidOracle = new MockPriceOracle();
        invalidOracle.setPrice(2000e8);
        invalidOracle.setTimestamp(0); // This will trigger OracleTimeout
        invalidOracle.setRoundId(1);
        invalidOracle.setAnsweredInRound(1);

        // CRITICAL: Add invalid oracle first, then valid oracle
        // This makes the invalid one the primary
        oracleInstance.addOracle(address(wethInstance), address(invalidOracle), 8);
        oracleInstance.addOracle(address(wethInstance), address(validOracle), 8);

        // Verify our primary oracle is now the invalid one
        assertEq(
            oracleInstance.primaryOracle(address(wethInstance)),
            address(invalidOracle),
            "Invalid oracle should be primary"
        );

        // Verify our setup is correct - primary oracle should revert when queried
        vm.expectRevert();
        oracleInstance.getSingleOraclePrice(address(invalidOracle));

        // No valid price history yet
        assertEq(oracleInstance.lastValidPrice(address(wethInstance)), 0, "Last valid price should be 0");

        // Now verify getAssetPrice reverts with NotEnoughOracles
        vm.expectRevert(
            abi.encodeWithSelector(
                NotEnoughOracles.selector,
                address(wethInstance),
                2, // required
                1 // actual valid oracles
            )
        );
        oracleInstance.getAssetPrice(address(wethInstance));

        vm.stopPrank();
    }

    function test_GetMedianPrice_PrimaryOracleFallback() public {
        vm.startPrank(address(timelockInstance));

        // Set minimum required oracles to 2
        oracleInstance.updateMinimumOracles(2);

        // First clear all existing oracles
        address[] memory existingOracles = oracleInstance.getAssetOracles(address(wethInstance));
        for (uint256 i = 0; i < existingOracles.length; i++) {
            oracleInstance.removeOracle(address(wethInstance), existingOracles[i]);
        }

        // IMPORTANT: Create a VALID fallback oracle
        MockPriceOracle fallbackOracle = new MockPriceOracle();
        fallbackOracle.setPrice(2000e8);
        fallbackOracle.setTimestamp(block.timestamp);
        fallbackOracle.setRoundId(1);
        fallbackOracle.setAnsweredInRound(1);

        // Add the fallback oracle
        oracleInstance.addOracle(address(wethInstance), address(fallbackOracle), 8);

        // Create two invalid oracles
        MockPriceOracle badOracle1 = new MockPriceOracle();
        badOracle1.setPrice(2000e8);
        badOracle1.setTimestamp(0); // Will fail with timeout

        MockPriceOracle badOracle2 = new MockPriceOracle();
        badOracle2.setPrice(2000e8);
        badOracle2.setTimestamp(0); // Will fail with timeout

        // Add these after setting the primary
        oracleInstance.addOracle(address(wethInstance), address(badOracle1), 8);
        oracleInstance.addOracle(address(wethInstance), address(badOracle2), 8);

        // Explicitly set the first oracle as primary
        oracleInstance.setPrimaryOracle(address(wethInstance), address(fallbackOracle));

        // Verify setup - we should have one valid primary oracle and two invalid regular oracles
        assertEq(
            oracleInstance.primaryOracle(address(wethInstance)),
            address(fallbackOracle),
            "Primary oracle should be set correctly"
        );

        // No valid price history
        assertEq(oracleInstance.lastValidPrice(address(wethInstance)), 0, "Last valid price should be 0");

        // This should succeed by using the primary oracle as fallback
        uint256 price = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2000e8, "Should return price from primary oracle fallback");

        vm.stopPrank();
    }
}
