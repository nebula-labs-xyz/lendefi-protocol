// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title LendefiAssetsBranchTest
 * @notice Tests focusing on uncovered branches in the LendefiAssets contract
 */
import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {LendefiAssets} from "../../contracts/lender/LendefiAssets.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {AggregatorV3Interface} from
    "../../contracts/vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "../../contracts/interfaces/IUniswapV3Pool.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockUniswapV3Pool} from "../../contracts/mock/MockUniswapV3Pool.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";

contract LendefiAssetsBranchTest is BasicDeploy {
    // Mock contracts
    MockUniswapV3Pool mockUniswapPool;
    MockUniswapV3Pool invalidPool;
    MockPriceOracle mockChainlinkOracle;

    // Error definitions from LendefiAssets
    error ZeroAddressNotAllowed();
    error AssetNotListed(address asset);
    error OracleNotFound(address asset);
    error AssetNotInUniswapPool(address asset, address pool);
    error TokenNotInUniswapPool(address token, address pool);
    error InvalidOracle(address oracle);
    error OracleAlreadyAdded(address asset, address oracle);
    error OracleTypeAlreadyAdded(address asset, IASSETS.OracleType oracleType);
    error InvalidThreshold(string name, uint256 value, uint256 min, uint256 max);
    error RateTooHigh(uint256 rate, uint256 max);
    error FeeTooHigh(uint256 fee, uint256 max);
    error InvalidLiquidationThreshold(uint32 threshold);
    error InvalidBorrowThreshold(uint32 threshold);
    error CircuitBreakerActive(address asset);
    error NotEnoughValidOracles(address asset, uint256 required, uint256 valid);
    error OracleInvalidPrice(address oracle, int256 price);
    error OracleStalePrice(address oracle, uint80 roundId, uint80 answeredInRound);
    error OracleTimeout(address oracle, uint256 timestamp, uint256 blockTimestamp, uint256 threshold);
    error OracleInvalidPriceVolatility(address oracle, int256 price, uint256 percentage);
    error InvalidUniswapConfig(address virtualOracle);
    error UpgradeNotScheduled();
    error ImplementationMismatch(address scheduledImpl, address attemptedImpl);
    error UpgradeTimelockActive(uint256 timeRemaining);

    address unauthorizedUser = address(0xBEEF);

    function setUp() public {
        // Deploy base contracts
        deployCompleteWithOracle();

        // Deploy mock contracts
        mockUniswapPool = new MockUniswapV3Pool(address(wethInstance), address(usdcInstance), 3000);
        invalidPool = new MockUniswapV3Pool(address(0xBBB), address(0xCCC), 3000);
        mockChainlinkOracle = new MockPriceOracle();

        // Set up initial asset
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(mockChainlinkOracle),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            800, // Borrow threshold
            850, // Liquidation threshold
            1_000_000e18, // Max supply
            0, // Isolation debt cap
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );
        vm.stopPrank();

        // Set oracle to return valid data by default
        mockChainlinkOracle.setPrice(2500e8); // $2500 price
        mockChainlinkOracle.setRoundId(10);
        mockChainlinkOracle.setAnsweredInRound(10);
        mockChainlinkOracle.setTimestamp(block.timestamp);
    }

    // ======== 1. Upgrade Function Tests ========

    function test_ScheduleUpgradeWithoutRole() public {
        LendefiAssets newImplementation = new LendefiAssets();

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedUser, UPGRADER_ROLE
            )
        );
        assetsInstance.scheduleUpgrade(address(newImplementation));
    }

    function test_CancelUpgradeWithoutRole() public {
        // First schedule an upgrade
        LendefiAssets newImplementation = new LendefiAssets();

        vm.prank(guardian);
        assetsInstance.scheduleUpgrade(address(newImplementation));

        // Attempt to cancel without proper role
        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedUser, UPGRADER_ROLE
            )
        );
        assetsInstance.cancelUpgrade();
    }

    function test_UpgradeWithImplementationMismatch() public {
        // Schedule an upgrade with one implementation
        LendefiAssets scheduledImpl = new LendefiAssets();

        vm.prank(guardian);
        assetsInstance.scheduleUpgrade(address(scheduledImpl));

        // Try to upgrade with a different implementation
        LendefiAssets differentImpl = new LendefiAssets();

        vm.warp(block.timestamp + 3 days + 1);

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(ImplementationMismatch.selector, address(scheduledImpl), address(differentImpl))
        );
        assetsInstance.upgradeToAndCall(address(differentImpl), "");
    }

    // ======== 2. Oracle Management Tests ========

    function test_AddUniswapOracleWithInvalidAsset() public {
        address invalidAsset = address(0xDEAD);

        vm.prank(address(timelockInstance)); // Changed from guardian to timelockInstance
        vm.expectRevert(abi.encodeWithSelector(AssetNotListed.selector, invalidAsset));
        assetsInstance.addUniswapOracle(invalidAsset, address(mockUniswapPool), address(usdcInstance), 1800, 8);
    }

    function test_AddUniswapOracleAssetNotInPool() public {
        address tokenNotInPool = address(0xFFFF);

        // First add the token as a valid asset
        vm.startPrank(address(timelockInstance)); // Changed from guardian to timelockInstance
        assetsInstance.updateAssetConfig(
            tokenNotInPool,
            address(0),
            8,
            18,
            1,
            800,
            850,
            1_000_000e18,
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );

        // Now try to add a Uniswap oracle where token is not in the pool
        vm.expectRevert(
            abi.encodeWithSelector(AssetNotInUniswapPool.selector, tokenNotInPool, address(mockUniswapPool))
        );
        assetsInstance.addUniswapOracle(tokenNotInPool, address(mockUniswapPool), address(usdcInstance), 1800, 8);
        vm.stopPrank();
    }

    function test_AddUniswapOracleQuoteTokenNotInPool() public {
        address invalidQuote = address(0xEEEE);

        vm.prank(address(timelockInstance)); // Changed from guardian to timelockInstance
        vm.expectRevert(abi.encodeWithSelector(TokenNotInUniswapPool.selector, invalidQuote, address(mockUniswapPool)));
        assetsInstance.addUniswapOracle(address(wethInstance), address(mockUniswapPool), invalidQuote, 1800, 8);
    }

    function test_AddOracleAlreadyExists() public {
        // Try to add the same oracle again
        vm.prank(address(timelockInstance)); // Changed from guardian to timelockInstance
        vm.expectRevert(
            abi.encodeWithSelector(OracleAlreadyAdded.selector, address(wethInstance), address(mockChainlinkOracle))
        );
        assetsInstance.addOracle(address(wethInstance), address(mockChainlinkOracle), 8, IASSETS.OracleType.CHAINLINK);
    }

    function test_AddOracleTypeAlreadyExists() public {
        // Try to add another oracle with the same type
        address anotherOracle = address(0xAAAA);

        vm.prank(address(timelockInstance)); // Changed from guardian to timelockInstance
        vm.expectRevert(
            abi.encodeWithSelector(OracleTypeAlreadyAdded.selector, address(wethInstance), IASSETS.OracleType.CHAINLINK)
        );
        assetsInstance.addOracle(address(wethInstance), anotherOracle, 8, IASSETS.OracleType.CHAINLINK);
    }

    function test_RemoveOracleNotFound() public {
        address nonExistentOracle = address(0xBBBB);

        vm.prank(address(timelockInstance)); // Changed from guardian to timelockInstance
        vm.expectRevert(abi.encodeWithSelector(OracleNotFound.selector, address(wethInstance)));
        assetsInstance.removeOracle(address(wethInstance), nonExistentOracle);
    }

    function test_SetPrimaryOracleNotFound() public {
        address nonExistentOracle = address(0xBBBB);

        vm.prank(address(timelockInstance)); // Changed from guardian to timelockInstance
        vm.expectRevert(abi.encodeWithSelector(OracleNotFound.selector, address(wethInstance)));
        assetsInstance.setPrimaryOracle(address(wethInstance), nonExistentOracle);
    }

    // ======== 3. Configuration Tests ========

    function test_UpdateOracleConfigInvalidThresholds() public {
        vm.startPrank(address(timelockInstance)); // Changed from guardian to timelockInstance

        // Test freshness threshold
        vm.expectRevert(
            abi.encodeWithSelector(InvalidThreshold.selector, "freshness", 10 minutes, 15 minutes, 24 hours)
        );
        assetsInstance.updateOracleConfig(
            10 minutes, // Too low
            1 hours,
            10,
            50,
            1
        );

        // Test volatility threshold
        vm.expectRevert(abi.encodeWithSelector(InvalidThreshold.selector, "volatility", 3 minutes, 5 minutes, 4 hours));
        assetsInstance.updateOracleConfig(
            1 hours,
            3 minutes, // Too low
            10,
            50,
            1
        );

        // Test volatility percent
        vm.expectRevert(abi.encodeWithSelector(InvalidThreshold.selector, "volatilityPct", 3, 5, 30));
        assetsInstance.updateOracleConfig(
            1 hours,
            1 hours,
            3, // Too low
            50,
            1
        );

        // Test circuit breaker threshold
        vm.expectRevert(abi.encodeWithSelector(InvalidThreshold.selector, "circuitBreaker", 20, 25, 70));
        assetsInstance.updateOracleConfig(
            1 hours,
            1 hours,
            10,
            20, // Too low
            1
        );

        // Test minimum oracles
        vm.expectRevert(abi.encodeWithSelector(InvalidThreshold.selector, "minOracles", 0, 1, type(uint16).max));
        assetsInstance.updateOracleConfig(
            1 hours,
            1 hours,
            10,
            50,
            0 // Too low
        );

        vm.stopPrank();
    }

    function test_UpdateTierConfigThresholds() public {
        vm.startPrank(address(timelockInstance)); // Changed from guardian to timelockInstance

        // Test jump rate too high
        vm.expectRevert(abi.encodeWithSelector(RateTooHigh.selector, 0.26e6, 0.25e6));
        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.CROSS_A,
            0.26e6, // Too high
            0.02e6
        );

        // Test liquidation fee too high
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 0.11e6, 0.1e6));
        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.CROSS_A,
            0.08e6,
            0.11e6 // Too high
        );

        vm.stopPrank();
    }

    function test_UpdateAssetConfigInvalidThresholds() public {
        vm.startPrank(address(timelockInstance)); // Changed from guardian to timelockInstance

        // Test liquidation threshold too high
        vm.expectRevert(abi.encodeWithSelector(InvalidLiquidationThreshold.selector, 995));
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            address(0),
            8,
            6,
            1,
            800,
            995, // Too high
            1_000_000e6,
            0,
            IASSETS.CollateralTier.STABLE,
            IASSETS.OracleType.CHAINLINK
        );

        // Test borrow threshold too close to liquidation threshold
        vm.expectRevert(abi.encodeWithSelector(InvalidBorrowThreshold.selector, 845));
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            address(0),
            8,
            6,
            1,
            845, // Too close to liquidation threshold
            850,
            1_000_000e6,
            0,
            IASSETS.CollateralTier.STABLE,
            IASSETS.OracleType.CHAINLINK
        );

        vm.stopPrank();
    }

    // ======== 4. Oracle Price Tests ========

    function test_CircuitBreakerActive() public {
        // Trigger circuit breaker - use guardian here since it has CIRCUIT_BREAKER_ROLE
        vm.prank(guardian);
        assetsInstance.triggerCircuitBreaker(address(wethInstance));

        // Verify price function reverts
        vm.expectRevert(abi.encodeWithSelector(CircuitBreakerActive.selector, address(wethInstance)));
        assetsInstance.getAssetPrice(address(wethInstance));

        // Verify getAssetPriceByType also reverts
        vm.expectRevert(abi.encodeWithSelector(CircuitBreakerActive.selector, address(wethInstance)));
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.CHAINLINK);
    }

    function test_GetAssetPriceByTypeNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(OracleNotFound.selector, address(wethInstance)));
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.UNISWAP_V3_TWAP);
    }

    function test_ChainlinkOracleInvalidPrice() public {
        // Set oracle to return invalid price
        mockChainlinkOracle.setPrice(0); // Zero price (invalid)

        vm.expectRevert(abi.encodeWithSelector(OracleInvalidPrice.selector, address(mockChainlinkOracle), 0));
        assetsInstance.getSingleOraclePrice(address(mockChainlinkOracle));
    }

    function test_ChainlinkOracleStalePrice() public {
        // Set oracle to return stale price
        mockChainlinkOracle.setRoundId(10); // Current round
        mockChainlinkOracle.setAnsweredInRound(5); // Answered in stale round

        vm.expectRevert(abi.encodeWithSelector(OracleStalePrice.selector, address(mockChainlinkOracle), 10, 5));
        assetsInstance.getSingleOraclePrice(address(mockChainlinkOracle));
    }

    function test_ChainlinkOracleTimeout() public {
        // Set oracle to return old price
        uint256 oldTimestamp = block.timestamp - 10 hours; // Assuming freshnessThreshold is 8 hours
        mockChainlinkOracle.setTimestamp(oldTimestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleTimeout.selector,
                address(mockChainlinkOracle),
                oldTimestamp,
                block.timestamp,
                28800 // 8 hours default freshness
            )
        );
        assetsInstance.getSingleOraclePrice(address(mockChainlinkOracle));
    }

    // Additional test for price volatility check (using historical data)
    function test_OracleInvalidPriceVolatility() public {
        // Set up oracle configuration first
        vm.prank(address(timelockInstance));
        assetsInstance.updateOracleConfig(
            8 hours, // Default freshness
            30 minutes, // Volatility checking period
            20, // 20% max volatility
            50, // Circuit breaker threshold
            1 // Min oracles
        );

        // Set current price with timestamp exactly at volatilityThreshold age
        uint256 currentTimestamp = block.timestamp - 30 minutes; // Exactly at volatility threshold
        mockChainlinkOracle.setPrice(1000e8); // Current price
        mockChainlinkOracle.setTimestamp(currentTimestamp);
        mockChainlinkOracle.setRoundId(10);
        mockChainlinkOracle.setAnsweredInRound(10);

        // Setup historical data for round 9
        uint256 pastTimestamp = currentTimestamp - 1 hours; // Some time before
        mockChainlinkOracle.setHistoricalRoundData(9, 500e8, pastTimestamp, 9);

        // This should now revert with OracleInvalidPriceVolatility
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleInvalidPriceVolatility.selector,
                address(mockChainlinkOracle),
                1000e8, // Current price
                100 // Percentage (100% change from 500 to 1000)
            )
        );
        assetsInstance.getAssetPrice(address(wethInstance));
    }

    // Test Uniswap TWAP with invalid configuration
    function test_InvalidUniswapConfig() public {
        // Create a virtual oracle address that doesn't have Uniswap config
        address virtualOracle = address(0xBEEF1);

        vm.startPrank(address(timelockInstance)); // Changed from guardian to timelockInstance
        // Register it as an oracle but don't set its Uniswap config
        assetsInstance.addOracle(address(wethInstance), virtualOracle, 8, IASSETS.OracleType.UNISWAP_V3_TWAP);
        vm.stopPrank();

        // This should revert when trying to get price
        vm.expectRevert(abi.encodeWithSelector(InvalidUniswapConfig.selector, virtualOracle));
        assetsInstance.getSingleOraclePrice(virtualOracle);
    }

    // Test NotEnoughValidOracles error
    function test_NotEnoughValidOracles() public {
        // Create a second oracle
        MockPriceOracle secondOracle = new MockPriceOracle();

        vm.startPrank(address(timelockInstance));

        // Add the second oracle
        assetsInstance.addOracle(
            address(wethInstance),
            address(secondOracle),
            8,
            IASSETS.OracleType.UNISWAP_V3_TWAP // Different type than first oracle
        );

        // Configure asset to require 2 oracles
        assetsInstance.updateMinimumOracles(address(wethInstance), 2);

        vm.stopPrank();

        // Make both oracles fail but in ways that don't immediately revert
        // First oracle will fail due to stale data
        mockChainlinkOracle.setPrice(1000e8); // Valid price
        mockChainlinkOracle.setRoundId(10);
        mockChainlinkOracle.setAnsweredInRound(5); // Stale round

        // Second oracle will fail because it's not properly configured for UNISWAP_V3_TWAP
        // The code checks for this after checking valid counts

        // Should revert with NotEnoughValidOracles
        vm.expectRevert(abi.encodeWithSelector(NotEnoughValidOracles.selector, address(wethInstance), 2, 0));
        assetsInstance.getAssetPrice(address(wethInstance));
    }
}
