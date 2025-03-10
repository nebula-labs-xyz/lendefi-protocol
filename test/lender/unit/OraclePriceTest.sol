// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";
import {MockRWA} from "../../../contracts/mock/MockRWA.sol";
import {MockPriceOracle} from "../../../contracts/mock/MockPriceOracle.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {ILendefiAssets} from "../../../contracts/interfaces/ILendefiAssets.sol";
import {ILendefiOracle} from "../../../contracts/interfaces/ILendefiOracle.sol";
import {AggregatorV3Interface} from
    "../../../contracts/vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract OraclePriceTest is BasicDeploy {
    RWAPriceConsumerV3 internal rwaOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    MockPriceOracle internal mockOracle;

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        // This will set up the Oracle module and Lendefi with it
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens - note that usdcInstance is already deployed by deployCompleteWithOracle()
        // We only need to deploy WETH here
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

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.updateMinimumOracles(1);
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        // Register mock oracles for direct testing of the oracle module
        oracleInstance.addOracle(address(0x1), address(rwaOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(0x1), address(rwaOracleInstance));

        oracleInstance.addOracle(address(0x2), address(stableOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(0x2), address(stableOracleInstance));

        oracleInstance.addOracle(address(0x3), address(mockOracle), 8);
        oracleInstance.setPrimaryOracle(address(0x3), address(mockOracle));
        vm.stopPrank();
    }

    // Test 1: Happy Path - Successfully get price
    function test_GetAssetPriceOracle_Success() public {
        uint256 expectedPrice = 2500e8;

        // Test through the Lendefi oracle wrapper
        uint256 price1 = assetsInstance.getAssetPriceOracle(address(wethOracleInstance));
        assertEq(price1, expectedPrice, "Oracle wrapper price should match");

        // Test through the Oracle module
        uint256 price2 = oracleInstance.getAssetPrice(address(wethInstance));
        assertEq(price2, expectedPrice, "Oracle module price should match");
    }

    // Test 2: Invalid Price - Oracle returns zero or negative price
    function test_GetAssetPriceOracle_InvalidPrice() public {
        // Set price to zero
        mockOracle.setPrice(0);

        // Expect revert when called through Lendefi
        vm.expectRevert();
        assetsInstance.getAssetPriceOracle(address(mockOracle));

        // Expect revert when called through Oracle module
        vm.expectRevert();
        oracleInstance.getAssetPrice(address(0x3));

        // Set price to negative
        mockOracle.setPrice(-100);

        // Expect revert with both approaches
        vm.expectRevert();
        assetsInstance.getAssetPriceOracle(address(mockOracle));

        vm.expectRevert();
        oracleInstance.getAssetPrice(address(0x3));
    }

    // Test 3: Stale Price - answeredInRound < roundId
    function test_GetAssetPriceOracle_StalePrice() public {
        // Set round ID higher than answeredInRound
        mockOracle.setRoundId(10);
        mockOracle.setAnsweredInRound(5);

        // Expect revert with OracleStalePrice
        vm.expectRevert(abi.encodeWithSelector(ILendefiOracle.OracleStalePrice.selector, address(mockOracle), 10, 5));
        assetsInstance.getAssetPriceOracle(address(mockOracle));
    }

    // Test 4: Timeout - Oracle data is too old
    function test_GetAssetPriceOracle_Timeout() public {
        // Set timestamp to 9 hours ago, getAssetPriceOracle has a 8 hour timeout
        uint256 oldTimestamp = block.timestamp - 9 hours;
        mockOracle.setTimestamp(oldTimestamp);

        // Expect revert with OracleTimeout
        vm.expectRevert(
            abi.encodeWithSelector(
                ILendefiOracle.OracleTimeout.selector, address(mockOracle), oldTimestamp, block.timestamp, 8 hours
            )
        );
        assetsInstance.getAssetPriceOracle(address(mockOracle));
    }

    // Test 5: Edge Case - Price exactly at time boundary
    function test_GetAssetPriceOracle_ExactTimeLimit() public {
        // Set timestamp to exactly 8 hours ago
        uint256 borderlineTimestamp = block.timestamp - 8 hours;
        mockOracle.setTimestamp(borderlineTimestamp);

        // Should succeed as it's exactly at the limit
        uint256 price = assetsInstance.getAssetPriceOracle(address(mockOracle));
        assertEq(price, 1000e8, "Should return price when timestamp is exactly at 8 hour limit");
    }

    // Test 6: Edge Case - answeredInRound equal to roundId
    function test_GetAssetPriceOracle_EqualRounds() public {
        // Set previous round data with >20% price difference
        mockOracle.setHistoricalRoundData(19, 1002e8, block.timestamp - 4 hours, 19);
        // Set roundId equal to answeredInRound
        mockOracle.setRoundId(20);
        mockOracle.setAnsweredInRound(20);

        // Should succeed
        uint256 price = assetsInstance.getAssetPriceOracle(address(mockOracle));
        assertEq(price, 1000e8, "Should return price when roundId equals answeredInRound");
    }

    // Test 7: Fuzz Test - Different positive prices
    function testFuzz_GetAssetPriceOracle_VariousPrices(int256 testPrice) public {
        // Use only positive prices to avoid expected reverts
        vm.assume(testPrice > 0);

        // Set the test price
        mockOracle.setPrice(testPrice);

        // Get the price from the oracle
        uint256 returnedPrice = assetsInstance.getAssetPriceOracle(address(mockOracle));

        // Verify the result
        assertEq(returnedPrice, uint256(testPrice), "Should return the exact price set");
    }

    // Test 8: Multiple Oracle Types
    function test_GetAssetPriceOracle_MultipleOracleTypes() public {
        // Check WETH price
        uint256 wethPrice = assetsInstance.getAssetPriceOracle(address(wethOracleInstance));
        assertEq(wethPrice, 2500e8, "WETH price should be correct");

        // Check RWA price
        uint256 rwaPrice = assetsInstance.getAssetPriceOracle(address(rwaOracleInstance));
        assertEq(rwaPrice, 1000e8, "RWA price should be correct");

        // Check Stable price
        uint256 stablePrice = assetsInstance.getAssetPriceOracle(address(stableOracleInstance));
        assertEq(stablePrice, 1e8, "Stable price should be correct");
    }

    // Test 9: Price Changes
    function test_GetAssetPriceOracle_PriceChanges() public {
        // Get initial price
        uint256 initialPrice = assetsInstance.getAssetPriceOracle(address(wethOracleInstance));
        assertEq(initialPrice, 2500e8, "Initial price should be correct");

        // Change price
        wethOracleInstance.setPrice(3000e8);

        // Get updated price
        uint256 updatedPrice = assetsInstance.getAssetPriceOracle(address(wethOracleInstance));
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
            ILendefiAssets.CollateralTier.CROSS_A,
            0 // no isolation debt cap
        );
        vm.stopPrank();

        // Get asset info
        ILendefiAssets.Asset memory assetInfo = assetsInstance.getAssetInfo(address(wethInstance));

        // Use the oracle from asset config
        uint256 price = assetsInstance.getAssetPriceOracle(assetInfo.oracleUSD);
        assertEq(price, 2500e8, "Should get correct price from asset-configured oracle");
    }

    // Test 11, Oracle price volatility checkfunction test_GetAssetPriceOracle_VolatilityDetection() public {
    function test_GetAssetPriceOracle_VolatilityDetection() public {
        // Set current round data
        mockOracle.setRoundId(20);
        mockOracle.setAnsweredInRound(20); // Add this line to fix the test
        mockOracle.setPrice(1200e8);
        mockOracle.setTimestamp(block.timestamp - 30 minutes); // Fresh timestamp

        // Set previous round data with >20% price difference
        mockOracle.setHistoricalRoundData(19, 1000e8, block.timestamp - 4 hours, 19);

        // This should pass since timestamp is recent (< 1 hour)
        uint256 price = assetsInstance.getAssetPriceOracle(address(mockOracle));
        assertEq(price, 1200e8);

        // Now set timestamp to be stale for volatility check (>= 1 hour)
        mockOracle.setTimestamp(block.timestamp - 2 hours);

        // Now this should revert due to volatility with stale timestamp
        vm.expectRevert(
            abi.encodeWithSelector(
                ILendefiOracle.OracleInvalidPriceVolatility.selector,
                address(mockOracle),
                1200e8,
                20 // 20% change
            )
        );
        assetsInstance.getAssetPriceOracle(address(mockOracle));
    }
}
