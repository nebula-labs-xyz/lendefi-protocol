// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {AggregatorV3Interface} from
    "../../contracts/vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract OraclePriceTest is BasicDeploy {
    RWAPriceConsumerV3 internal rwaOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    MockPriceOracle internal mockOracle;

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens
        wethInstance = new WETH9();

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();
        mockOracle = new MockPriceOracle();

        // Set up mockOracle with default values for testing
        mockOracle.setPrice(1000e8); // Default price
        mockOracle.setTimestamp(block.timestamp); // Current timestamp
        mockOracle.setRoundId(1);
        mockOracle.setAnsweredInRound(1);

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token
        stableOracleInstance.setPrice(1e8); // $1 per stable token

        vm.startPrank(address(timelockInstance));

        // Set minimum required oracles to 1
        assetsInstance.updateOracleConfig(
            uint80(28800), // Keep default freshness
            uint80(3600), // Keep default volatility
            uint40(20), // Keep default volatility %
            uint40(50), // Keep default circuit breaker %
            1 // # oracles
        );

        // FIRST REGISTER ASSETS using updateAssetConfig

        // Register WETH asset
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(0), // Oracle will be added separately
            8,
            18,
            1,
            900,
            950,
            1_000_000e18,
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );

        // Register mock asset 1
        assetsInstance.updateAssetConfig(
            address(0x1),
            address(0),
            8,
            18,
            1,
            800,
            850,
            1_000_000e18,
            0,
            IASSETS.CollateralTier.CROSS_B,
            IASSETS.OracleType.CHAINLINK
        );

        // Register mock asset 2
        assetsInstance.updateAssetConfig(
            address(0x2),
            address(0),
            8,
            18,
            1,
            950,
            980,
            1_000_000e18,
            0,
            IASSETS.CollateralTier.STABLE,
            IASSETS.OracleType.CHAINLINK
        );

        // Register mock asset 3
        assetsInstance.updateAssetConfig(
            address(0x3),
            address(0),
            8,
            18,
            1,
            850,
            900,
            1_000_000e18,
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );

        // THEN ADD ORACLES to the registered assets
        assetsInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8, IASSETS.OracleType.CHAINLINK);
        assetsInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        assetsInstance.addOracle(address(0x1), address(rwaOracleInstance), 8, IASSETS.OracleType.CHAINLINK);
        assetsInstance.setPrimaryOracle(address(0x1), address(rwaOracleInstance));

        assetsInstance.addOracle(address(0x2), address(stableOracleInstance), 8, IASSETS.OracleType.CHAINLINK);
        assetsInstance.setPrimaryOracle(address(0x2), address(stableOracleInstance));

        assetsInstance.addOracle(address(0x3), address(mockOracle), 8, IASSETS.OracleType.CHAINLINK);
        assetsInstance.setPrimaryOracle(address(0x3), address(mockOracle));

        vm.stopPrank();
    }

    // Test 1: Happy Path - Successfully get price
    function test_GetAssetPrice_Success() public {
        uint256 expectedPrice = 2500e8;

        // Test through the Oracle module
        uint256 price2 = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price2, expectedPrice, "Oracle module price should match");
    }

    // Test 2: Invalid Price - Oracle returns zero or negative price
    function test_GetAssetPrice_InvalidPrice() public {
        // Set price to zero
        mockOracle.setPrice(0);

        // Expect revert when called through Oracle module
        vm.expectRevert();
        assetsInstance.getAssetPrice(address(0x3));

        // Set price to negative
        mockOracle.setPrice(-100);

        vm.expectRevert();
        assetsInstance.getAssetPrice(address(0x3));
    }

    // Test 6: Edge Case - answeredInRound equal to roundId
    function test_GetAssetPriceOracle_EqualRounds() public {
        // Set previous round data with >20% price difference
        mockOracle.setHistoricalRoundData(19, 1002e8, block.timestamp - 4 hours, 19);
        // Set roundId equal to answeredInRound
        mockOracle.setRoundId(20);
        mockOracle.setAnsweredInRound(20);

        // Should succeed
        uint256 price = assetsInstance.getSingleOraclePrice(address(mockOracle));
        assertEq(price, 1000e8, "Should return price when roundId equals answeredInRound");
    }

    // Test 7: Fuzz Test - Different positive prices
    function testFuzz_GetAssetPriceOracle_VariousPrices(int256 testPrice) public {
        // Use only positive prices to avoid expected reverts
        vm.assume(testPrice > 0);

        // Set the test price
        mockOracle.setPrice(testPrice);

        // Get the price from the oracle
        uint256 returnedPrice = assetsInstance.getSingleOraclePrice(address(mockOracle));

        // Verify the result
        assertEq(returnedPrice, uint256(testPrice), "Should return the exact price set");
    }

    // Test 8: Multiple Oracle Types
    function test_GetAssetPrice_MultipleOracleTypes() public {
        // Check WETH price using the oracle instance (not token)
        uint256 wethPrice = assetsInstance.getSingleOraclePrice(address(wethOracleInstance));
        assertEq(wethPrice, 2500e8, "WETH price should be correct");

        // Check RWA price using the oracle instance
        uint256 rwaPrice = assetsInstance.getSingleOraclePrice(address(rwaOracleInstance));
        assertEq(rwaPrice, 1000e8, "RWA price should be correct");

        // Check Stable price using the oracle instance
        uint256 stablePrice = assetsInstance.getSingleOraclePrice(address(stableOracleInstance));
        assertEq(stablePrice, 1e8, "Stable price should be correct");
    }

    // Test 9: Price Changes
    function test_GetAssetPriceOracle_PriceChanges() public {
        // Get initial price
        uint256 initialPrice = assetsInstance.getSingleOraclePrice(address(wethOracleInstance));
        assertEq(initialPrice, 2500e8, "Initial price should be correct");

        // Change price
        wethOracleInstance.setPrice(3000e8);

        // Get updated price
        uint256 updatedPrice = assetsInstance.getSingleOraclePrice(address(wethOracleInstance));
        assertEq(updatedPrice, 3000e8, "Updated price should reflect the change");
    }

    // Test 10: Integration with Asset Config
    function test_GetAssetPriceOracle_WithAssetConfig() public {
        // Setup asset config with WETH oracle
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // borrow threshold
            850, // liquidation threshold
            1_000_000 ether, // supply cap
            0, // isolation debt cap
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );
        vm.stopPrank();

        // Get asset info
        IASSETS.Asset memory assetInfo = assetsInstance.getAssetInfo(address(wethInstance));

        // Use the oracle from asset config
        uint256 price = assetsInstance.getSingleOraclePrice(assetInfo.oracleUSD);
        assertEq(price, 2500e8, "Should get correct price from asset-configured oracle");
    }

    // Test 11: Oracle price volatility check
    function test_GetAssetPriceOracle_VolatilityDetection() public {
        // Set current round data
        mockOracle.setRoundId(20);
        mockOracle.setAnsweredInRound(20);
        mockOracle.setPrice(1200e8);
        mockOracle.setTimestamp(block.timestamp - 30 minutes); // Fresh timestamp

        // Set previous round data with >20% price difference
        mockOracle.setHistoricalRoundData(19, 1000e8, block.timestamp - 4 hours, 19);

        // This should pass since timestamp is recent (< 1 hour)
        uint256 price = assetsInstance.getSingleOraclePrice(address(mockOracle));
        assertEq(price, 1200e8);

        // Now set timestamp to be stale for volatility check (>= 1 hour)
        mockOracle.setTimestamp(block.timestamp - 2 hours);

        // Now this should revert due to volatility with stale timestamp
        vm.expectRevert(
            abi.encodeWithSelector(
                IASSETS.OracleInvalidPriceVolatility.selector,
                address(mockOracle),
                1200e8,
                20 // 20% change
            )
        );
        assetsInstance.getSingleOraclePrice(address(mockOracle));
    }

    // Test 12: Test with Uniswap Oracle Type
    function test_UniswapOracleType() public {
        // This would require a more complex setup with mocked Uniswap pool
        // For a basic test, we can verify that the OracleType enum is correctly used
        vm.startPrank(address(timelockInstance));

        // Create a mock asset with Uniswap oracle type
        assetsInstance.updateAssetConfig(
            address(0x4),
            address(0),
            8,
            18,
            1,
            850,
            900,
            1_000_000e18,
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.UNISWAP_V3_TWAP
        );

        vm.stopPrank();

        // If the interface functions are updated correctly, this test should pass compilation
        // The actual Uniswap oracle functionality would need more complex mocking
    }
}
