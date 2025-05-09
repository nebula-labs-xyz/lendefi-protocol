// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";

contract LendefiExtendedTest is BasicDeploy {
    uint256 constant WAD = 1e6;
    MockRWA internal rwaToken;

    RWAPriceConsumerV3 internal rwaOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();
        assertEq(tokenInstance.totalSupply(), 0);

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Note: usdcInstance is already deployed in deployCompleteWithOracle()
        // We only need to deploy WETH and RWA tokens
        wethInstance = new WETH9();
        rwaToken = new MockRWA("Ondo Finance", "ONDO");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token

        // Setup roles
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
        _setupLiquidity();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure RWA token (isolated)
        assetsInstance.updateAssetConfig(
            address(rwaToken),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 650, // 65% LTV
                liquidationThreshold: 750, // 75% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether, // max supply
                isolationDebtCap: 100_000e6, // isolation debt cap
                assetMinimumOracles: 1, // Need at least 1 oracle
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.ISOLATED,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(rwaOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure WETH (cross-collateral)
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800, // 80% LTV
                liquidationThreshold: 850, // 85% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether, // max supply
                isolationDebtCap: 0, // no isolation debt cap
                assetMinimumOracles: 1, // Need at least 1 oracle
                porFeed: address(0),
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

        vm.stopPrank();
    }

    function _setupLiquidity() internal {
        // Setup initial USDC liquidity with alice (1M USDC)
        usdcInstance.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();

        // Setup USDC for bob (100k USDC)
        usdcInstance.mint(bob, 100_000e6);
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), type(uint256).max);
        vm.stopPrank();

        // Setup ETH for bob (100 ETH)
        vm.deal(bob, 100 ether);

        // Set initial prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
    }

    function test_FullPositionLifecycle() public {
        // Setup initial state
        vm.deal(charlie, 10 ether);
        usdcInstance.mint(charlie, 1_000_000e6);
        vm.startPrank(charlie);

        // Setup WETH collateral
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);

        // Pass CROSS_A tier since we're using WETH
        uint256 borrowRate = LendefiInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_A);
        console2.log("Borrow rate (%):", borrowRate * 100 / 1e6);

        // Log rates and utilization
        uint256 utilization = LendefiInstance.getUtilization();

        // Get base borrow rate
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();
        uint256 baseRate = config.borrowRate;
        uint256 tierRate = LendefiInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_A);

        console2.log("Initial utilization (%):", utilization * 100 / WAD);
        console2.log("Base borrow rate (%):", baseRate * 100 / 1e6);
        console2.log("Tier borrow rate (%):", tierRate * 100 / 1e6);

        // Calculate and log credit limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(charlie, 0);
        console2.log("Credit limit (USDC):", creditLimit / 1e6);

        // Borrow 75% of credit limit to increase utilization
        uint256 borrowAmount = (creditLimit * 75) / 100;
        console2.log("Borrow amount (USDC):", borrowAmount / 1e6);

        // Approve and borrow
        usdcInstance.approve(address(LendefiInstance), type(uint256).max);
        LendefiInstance.borrow(0, borrowAmount);

        // Log post-borrow state
        utilization = LendefiInstance.getUtilization();
        console2.log("Post-borrow utilization (%):", utilization * 100 / WAD);

        uint256 initialDebt = LendefiInstance.calculateDebtWithInterest(charlie, 0);
        console2.log("Initial debt (USDC):", initialDebt / 1e6);

        // Accumulate interest for 1 year
        vm.warp(block.timestamp + 365 days);
        wethOracleInstance.setPrice(2500e8); // same price, but this updates the blockstamp as well
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(charlie, 0);

        // Replace the APR calculation section
        // Calculate and log the effective APR
        uint256 effectiveAPR = ((debtWithInterest - initialDebt) * 100 * 1e6) / initialDebt;
        console2.log("Interest accrued (USDC):", (debtWithInterest - initialDebt) / 1e6);
        console2.log("Raw APR calculation:", effectiveAPR);
        console2.log("Effective APR (%):", effectiveAPR / 1e6);
        console2.log("Final debt (USDC):", debtWithInterest / 1e6);

        // Add more detailed rate logging
        console2.log("Expected minimum rate (%):", baseRate * 100 / 1e6);
        console2.log("Expected maximum rate (%):", (baseRate + tierRate) * 100 / 1e6);

        // Update assertions to match actual rates
        assertTrue(effectiveAPR >= baseRate * 100, "APR below base rate");
        assertTrue(effectiveAPR <= (baseRate + tierRate) * 100, "APR above max rate");

        // Full repayment
        LendefiInstance.repay(0, debtWithInterest);

        // Verify debt is cleared
        uint256 remainingDebt = LendefiInstance.calculateDebtWithInterest(charlie, 0);
        assertEq(remainingDebt, 0, "Debt should be fully repaid");

        // Exit Position
        LendefiInstance.exitPosition(0);
        vm.stopPrank();
    }

    function test_CrossCollateralManagement() public {
        vm.startPrank(bob);

        // Setup first collateral
        wethInstance.deposit{value: 5 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 5 ether, 0);

        uint256 initialLimit = LendefiInstance.calculateCreditLimit(bob, 0);

        // Add second collateral
        wethInstance.deposit{value: 5 ether}();
        LendefiInstance.supplyCollateral(address(wethInstance), 5 ether, 0);

        uint256 newLimit = LendefiInstance.calculateCreditLimit(bob, 0);
        assertTrue(newLimit > initialLimit, "Credit limit should increase");
        vm.stopPrank();
    }

    function test_RewardMechanics() public {
        vm.startPrank(alice);
        // Already has liquidity from setup

        // Wait for reward interval
        vm.warp(block.timestamp + 180 days);

        // Check reward eligibility
        bool isEligible = LendefiInstance.isRewardable(alice);
        assertTrue(isEligible, "Should be eligible for rewards");

        vm.stopPrank();
    }

    // Fixed - Using proper IASSETS.OracleInvalidPrice error
    function test_OracleFailures() public {
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);

        // Mock oracle failure
        wethOracleInstance.setPrice(0); // Set invalid price

        // Use custom error from IASSETS interface
        vm.expectRevert(abi.encodeWithSelector(IASSETS.OracleInvalidPrice.selector, address(wethOracleInstance), 0));
        LendefiInstance.borrow(0, 1000e6);
        vm.stopPrank();
    }

    function test_ParameterUpdates() public {
        vm.startPrank(address(timelockInstance));

        // Create a ProtocolConfig struct with the new values
        IPROTOCOL.ProtocolConfig memory config = IPROTOCOL.ProtocolConfig({
            profitTargetRate: 0.005e6, // 0.5% profit target
            borrowRate: 0.02e6, // 2% base borrow rate
            rewardAmount: 2_000 ether, // 2,000 tokens reward
            rewardInterval: 180 days, // 180 days reward interval
            rewardableSupply: 100_000e6, // 100,000 USDC minimum supply
            liquidatorThreshold: 20_000 ether, // 20,000 tokens to liquidate
            flashLoanFee: 9 // 9 basis points (0.09%) flash loan fee
        });

        // Update protocol config using the new loadProtocolConfig function
        LendefiInstance.loadProtocolConfig(config);

        vm.stopPrank();

        // Verify updates - get values from the mainConfig struct
        IPROTOCOL.ProtocolConfig memory updatedConfig = LendefiInstance.getConfig();
        assertEq(updatedConfig.profitTargetRate, 0.005e6);
        assertEq(updatedConfig.borrowRate, 0.02e6);
        assertEq(updatedConfig.rewardAmount, 2_000 ether);
        assertEq(updatedConfig.rewardInterval, 180 days);
        assertEq(updatedConfig.rewardableSupply, 100_000e6);
        assertEq(updatedConfig.liquidatorThreshold, 20_000 ether);
        assertEq(updatedConfig.flashLoanFee, 9);
    }

    function test_TVLTracking() public {
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);

        uint256 initialTVL = LendefiInstance.assetTVL(address(wethInstance));
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);
        uint256 newTVL = LendefiInstance.assetTVL(address(wethInstance));

        assertEq(newTVL - initialTVL, 10 ether, "TVL should increase by deposit amount");
        vm.stopPrank();
    }

    // Fixed - Using proper IASSETS.OracleTimeout error
    function testRevert_OracleTimeout() public {
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);

        // Warp time far into future to cause oracle timeout
        vm.warp(block.timestamp + 30 days);

        // Use custom error from IASSETS interface
        // The parameters must match the exact format used in the contract
        vm.expectRevert(
            abi.encodeWithSelector(
                IASSETS.OracleTimeout.selector,
                address(wethOracleInstance),
                block.timestamp - 30 days, // Oracle timestamp
                block.timestamp, // Current timestamp
                8 hours // Max age
            )
        );
        LendefiInstance.borrow(0, 1000e6);
        vm.stopPrank();
    }

    function testRevert_BorrowZeroAmount() public {
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);

        // Get the initial state
        uint256 initialDebt = LendefiInstance.getUserPosition(bob, 0).debtAmount;
        uint256 initialLastAccrual = LendefiInstance.getUserPosition(bob, 0).lastInterestAccrual;

        // Borrow with zero amount - SHOULD revert with "ZA" error
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.ZeroAmount.selector));
        LendefiInstance.borrow(0, 0);

        // Verify state hasn't changed (these assertions won't execute if the revert works properly)
        uint256 newDebt = LendefiInstance.getUserPosition(bob, 0).debtAmount;
        uint256 newLastAccrual = LendefiInstance.getUserPosition(bob, 0).lastInterestAccrual;

        assertEq(newDebt, initialDebt, "Debt should not change after reverting");
        assertEq(newLastAccrual, initialLastAccrual, "Last accrual timestamp should not change after reverting");

        vm.stopPrank();
    }

    function testRevert_BorrowWhenPaused() public {
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);
        vm.stopPrank();

        // Pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        // Try to borrow when paused
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        LendefiInstance.borrow(0, 1000e6);
        vm.stopPrank();
    }

    function testRevert_InvalidPosition() public {
        vm.startPrank(bob);

        // Try to borrow from non-existent position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector));
        LendefiInstance.borrow(999, 1000e6);

        vm.stopPrank();
    }

    // Test - Use proper asset capacity error code
    function testRevert_ExceedAssetSupplyLimit() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // Setup low max supply for WETH
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 5 ether, // Low max supply of 5 ETH
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
        vm.stopPrank();

        // Try to supply more than the limit
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);

        // First supply 5 ETH (at limit)
        LendefiInstance.supplyCollateral(address(wethInstance), 5 ether, 0);

        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.AssetCapacityReached.selector));
        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, 0);
        vm.stopPrank();
    }

    function test_GetUserPositions() public {
        // Create multiple positions with different configurations
        vm.startPrank(bob);

        // Create position 0 - cross-collateral with WETH
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.deposit{value: 2 ether}();
        wethInstance.approve(address(LendefiInstance), 2 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 2 ether, 0);

        // Create position 1 - isolated with RWA
        LendefiInstance.createPosition(address(rwaToken), true);
        rwaToken.mint(bob, 5 ether);
        rwaToken.approve(address(LendefiInstance), 5 ether);
        LendefiInstance.supplyCollateral(address(rwaToken), 5 ether, 1);

        // Create position 2 - cross-collateral with WETH + borrow
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.deposit{value: 3 ether}();
        wethInstance.approve(address(LendefiInstance), 3 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 3 ether, 2);
        LendefiInstance.borrow(2, 1000e6);

        // Get all positions
        IPROTOCOL.UserPosition[] memory positions = LendefiInstance.getUserPositions(bob);

        // Verify positions count
        assertEq(positions.length, 3, "Should have 3 positions");

        // Verify position 0 details (cross-collateral, no debt)
        assertFalse(positions[0].isIsolated, "Position 0 should be cross-collateral");
        assertEq(positions[0].debtAmount, 0, "Position 0 should have no debt");
        assertEq(uint8(positions[0].status), uint8(IPROTOCOL.PositionStatus.ACTIVE), "Position 0 should be active");

        // Verify position 1 details (isolated, no debt)
        assertTrue(positions[1].isIsolated, "Position 1 should be isolated");
        assertEq(positions[1].debtAmount, 0, "Position 1 should have no debt");
        assertEq(uint8(positions[1].status), uint8(IPROTOCOL.PositionStatus.ACTIVE), "Position 1 should be active");

        // Verify position 2 details (cross-collateral, with debt)
        assertFalse(positions[2].isIsolated, "Position 2 should be cross-collateral");
        assertEq(positions[2].debtAmount, 1000e6, "Position 2 should have 1000 USDC debt");
        assertEq(uint8(positions[2].status), uint8(IPROTOCOL.PositionStatus.ACTIVE), "Position 2 should be active");

        // Test that getUserPositionsCount returns the correct value
        assertEq(LendefiInstance.getUserPositionsCount(bob), 3, "getUserPositionsCount should return 3");

        // Close position 0 and verify status update
        LendefiInstance.exitPosition(0);
        positions = LendefiInstance.getUserPositions(bob);
        assertEq(uint8(positions[0].status), uint8(IPROTOCOL.PositionStatus.CLOSED), "Position 0 should be closed");

        vm.stopPrank();
    }
}
