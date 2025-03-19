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
import {MockWBTC} from "../../contracts/mock/MockWBTC.sol";

contract LendefiAssetsBranchTest is BasicDeploy {
    // Mock contracts
    MockUniswapV3Pool mockUniswapPool;
    MockUniswapV3Pool invalidPool;
    MockPriceOracle mockChainlinkOracle;
    MockWBTC mockWBTC; // Use MockWBTC

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
        usdcInstance = new USDC();
        wethInstance = new WETH9();
        deployCompleteWithOracle();

        // Deploy mock contracts
        mockUniswapPool = new MockUniswapV3Pool(address(wethInstance), address(usdcInstance), 3000);
        invalidPool = new MockUniswapV3Pool(address(0xBBB), address(0xCCC), 3000);
        mockChainlinkOracle = new MockPriceOracle();
        mockWBTC = new MockWBTC(); // Initialize MockWBTC

        // Set up initial asset
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({
                    oracleUSD: address(mockChainlinkOracle),
                    oracleDecimals: 8,
                    active: 1
                }),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0),
                    quoteToken: address(0),
                    isToken0: false,
                    decimalsUniswap: 0,
                    twapPeriod: 0,
                    active: 0
                })
            })
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

    function test_updateUniswapOracleWithInvalidAsset() public {
        address invalidAsset = address(0xDEAD);

        vm.prank(address(timelockInstance)); // Changed from guardian to timelockInstance
        vm.expectRevert(abi.encodeWithSelector(AssetNotListed.selector, invalidAsset));
        assetsInstance.updateUniswapOracle(invalidAsset, address(mockUniswapPool), address(usdcInstance), 1800, 8, 1);
    }

    function test_updateUniswapOracleAssetNotInPool() public {
        // First add the tokenNotInPool as a valid asset
        vm.startPrank(address(timelockInstance));

        address tokenNotInPool = address(0xFFFF);

        // Fix: First add the token as a valid asset
        assetsInstance.updateAssetConfig(
            tokenNotInPool,
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({
                    oracleUSD: address(mockChainlinkOracle),
                    oracleDecimals: 8,
                    active: 1
                }),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0),
                    quoteToken: address(0),
                    isToken0: false,
                    decimalsUniswap: 0,
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Now try to add a Uniswap oracle where token is not in the pool
        vm.expectRevert(
            abi.encodeWithSelector(AssetNotInUniswapPool.selector, tokenNotInPool, address(mockUniswapPool))
        );
        assetsInstance.updateUniswapOracle(tokenNotInPool, address(mockUniswapPool), address(usdcInstance), 1800, 8, 1);
        vm.stopPrank();
    }

    function test_updateUniswapOracleQuoteTokenNotInPool() public {
        address invalidQuote = address(0xEEEE);

        vm.prank(address(timelockInstance)); // Changed from guardian to timelockInstance
        vm.expectRevert(abi.encodeWithSelector(TokenNotInUniswapPool.selector, invalidQuote, address(mockUniswapPool)));
        assetsInstance.updateUniswapOracle(address(wethInstance), address(mockUniswapPool), invalidQuote, 1800, 8, 1);
    }

    // ======== 3. Configuration Tests ========

    function test_UpdateOracleConfigInvalidThresholds() public {
        vm.startPrank(address(timelockInstance)); // Changed from guardian to timelockInstance

        // Test freshness threshold
        vm.expectRevert(
            abi.encodeWithSelector(InvalidThreshold.selector, "freshness", 10 minutes, 15 minutes, 24 hours)
        );
        assetsInstance.updateMainOracleConfig(
            10 minutes, // Too low
            1 hours,
            10,
            50,
            1
        );

        // Test volatility threshold
        vm.expectRevert(abi.encodeWithSelector(InvalidThreshold.selector, "volatility", 3 minutes, 5 minutes, 4 hours));
        assetsInstance.updateMainOracleConfig(
            1 hours,
            3 minutes, // Too low
            10,
            50,
            1
        );

        // Test volatility percent
        vm.expectRevert(abi.encodeWithSelector(InvalidThreshold.selector, "volatilityPct", 3, 5, 30));
        assetsInstance.updateMainOracleConfig(
            1 hours,
            1 hours,
            3, // Too low
            50,
            1
        );

        // Test circuit breaker threshold
        vm.expectRevert(abi.encodeWithSelector(InvalidThreshold.selector, "circuitBreaker", 20, 25, 70));
        assetsInstance.updateMainOracleConfig(
            1 hours,
            1 hours,
            10,
            20, // Too low
            1
        );

        // Test minimum oracles
        vm.expectRevert(abi.encodeWithSelector(InvalidThreshold.selector, "minOracles", 0, 1, type(uint16).max));
        assetsInstance.updateMainOracleConfig(
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
        vm.startPrank(address(timelockInstance));

        // Fix: Update the vm.expectRevert to use the exact same bytes as the error
        bytes memory encodedError = abi.encodeWithSignature("InvalidLiquidationThreshold(uint256)", 995);
        vm.expectRevert(encodedError);

        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 800,
                liquidationThreshold: 995, // > 990 (maximum allowed)
                maxSupplyThreshold: 1_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({
                    oracleUSD: address(mockChainlinkOracle),
                    oracleDecimals: 8,
                    active: 1
                }),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0),
                    quoteToken: address(0),
                    isToken0: false,
                    decimalsUniswap: 0,
                    twapPeriod: 0,
                    active: 0
                })
            })
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
        // Fix: Update expectation to match the new error type in the contract
        vm.expectRevert(abi.encodeWithSelector(InvalidUniswapConfig.selector, address(wethInstance)));
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.UNISWAP_V3_TWAP);
    }

    function test_ChainlinkOracleInvalidPrice() public {
        // Set oracle to return invalid price
        mockChainlinkOracle.setPrice(0); // Zero price (invalid)

        vm.expectRevert(abi.encodeWithSelector(OracleInvalidPrice.selector, address(mockChainlinkOracle), 0));
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.CHAINLINK);
    }

    function test_ChainlinkOracleStalePrice() public {
        // Set oracle to return stale price
        mockChainlinkOracle.setRoundId(10); // Current round
        mockChainlinkOracle.setAnsweredInRound(5); // Answered in stale round

        vm.expectRevert(abi.encodeWithSelector(OracleStalePrice.selector, address(mockChainlinkOracle), 10, 5));
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.CHAINLINK);
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
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.CHAINLINK);
    }

    // Additional test for price volatility check (using historical data)
    function test_OracleInvalidPriceVolatility() public {
        // Set up oracle configuration first
        vm.prank(address(timelockInstance));
        assetsInstance.updateMainOracleConfig(
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

        vm.startPrank(address(timelockInstance));

        // Update asset config with invalid Uniswap pool
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.UNISWAP_V3_TWAP,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({
                    oracleUSD: address(mockChainlinkOracle),
                    oracleDecimals: 8,
                    active: 0
                }),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: virtualOracle,
                    quoteToken: address(usdcInstance),
                    isToken0: true,
                    decimalsUniswap: 8,
                    twapPeriod: 1800,
                    active: 0 // Set to inactive to trigger the error
                })
            })
        );
        vm.stopPrank();

        // Fix: the InvalidUniswapConfig error contains the asset address (wethInstance), not the pool address
        vm.expectRevert(abi.encodeWithSelector(InvalidUniswapConfig.selector, address(wethInstance)));
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.UNISWAP_V3_TWAP);
    }

    function testRevert_NotEnoughValidOracles() public {
        // First make sure oracle has both current and previous round data
        // Current round data is already set in setUp(), but we need previous round
        mockChainlinkOracle.setHistoricalRoundData(
            9, // Previous round ID
            2400e8, // Previous price
            block.timestamp - 1 hours, // Previous timestamp
            9 // Previous answeredInRound
        );

        // Update asset to require 2 oracles
        vm.startPrank(address(timelockInstance));

        // Also update the asset's specific minimum oracle count
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        asset.assetMinimumOracles = 2; // Ensure the asset specifically requires 2 oracles
        assetsInstance.updateAssetConfig(address(wethInstance), asset);

        vm.stopPrank();

        // Now we should get the NotEnoughValidOracles error
        // The asset requires 2 oracles but only has 1 valid one (Chainlink)
        vm.expectRevert(abi.encodeWithSelector(IASSETS.NotEnoughValidOracles.selector, address(wethInstance), 2, 1));
        assetsInstance.checkPriceDeviation(address(wethInstance));
    }

    function test_IsAssetAtCapacity() public {
        // Use LendefiInstance from BasicDeploy instead of creating a new mock
        vm.startPrank(guardian);
        assetsInstance.setCoreAddress(address(LendefiInstance));
        vm.stopPrank();

        vm.startPrank(address(timelockInstance));

        // Use a mock method to simulate TVL in LendefiInstance
        // We need to configure how to mock this in BasicDeploy or directly access internals
        vm.mockCall(
            address(LendefiInstance),
            abi.encodeWithSelector(LendefiInstance.assetTVL.selector, address(wethInstance)),
            abi.encode(500_000e18) // Half capacity
        );

        vm.stopPrank();

        // Test not at capacity
        bool atCapacity1 = assetsInstance.isAssetAtCapacity(address(wethInstance), 400_000e18);
        assertFalse(atCapacity1, "Should not be at capacity with 900,000e18 total");

        // Test at capacity
        bool atCapacity2 = assetsInstance.isAssetAtCapacity(address(wethInstance), 600_000e18);
        assertTrue(atCapacity2, "Should be at capacity with 1,100,000e18 total");
    }

    function test_AssetActivationDeactivation() public {
        vm.startPrank(address(timelockInstance));

        // First activate an asset (active = 1)
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1, // Active
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({
                    oracleUSD: address(mockChainlinkOracle),
                    oracleDecimals: 8,
                    active: 1
                }),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0),
                    quoteToken: address(0),
                    isToken0: false,
                    decimalsUniswap: 0,
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Verify asset is active
        assertTrue(assetsInstance.isAssetValid(address(wethInstance)), "Asset should be active");

        // Now deactivate the asset (active = 0)
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 0, // Inactive
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({
                    oracleUSD: address(mockChainlinkOracle),
                    oracleDecimals: 8,
                    active: 1
                }),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0),
                    quoteToken: address(0),
                    isToken0: false,
                    decimalsUniswap: 0,
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Verify asset is inactive
        assertFalse(assetsInstance.isAssetValid(address(wethInstance)), "Asset should be inactive");

        vm.stopPrank();
    }
}
