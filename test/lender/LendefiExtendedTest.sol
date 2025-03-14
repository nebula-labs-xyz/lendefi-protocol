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

    RWAPriceConsumerV3 internal rwaassetsInstance;
    WETHPriceConsumerV3 internal wethassetsInstance;

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
        wethassetsInstance = new WETHPriceConsumerV3();
        rwaassetsInstance = new RWAPriceConsumerV3();

        // Set prices
        wethassetsInstance.setPrice(2500e8); // $2500 per ETH
        rwaassetsInstance.setPrice(1000e8); // $1000 per RWA token

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
        _setupLiquidity();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure RWA token (isolated)
        // Updated parameter order and added OracleType parameter
        assetsInstance.updateAssetConfig(
            address(rwaToken), // asset
            address(rwaassetsInstance), // oracle
            8, // oracle decimals
            18, // asset decimals
            1, // active
            650, // borrow threshold (65%)
            750, // liquidation threshold (75%)
            1_000_000 ether, // max supply
            100_000e6, // isolation debt cap (moved before tier)
            IASSETS.CollateralTier.ISOLATED, // tier
            IASSETS.OracleType.CHAINLINK // new oracle type parameter
        );

        // Configure WETH (cross-collateral)
        // Updated parameter order and added OracleType parameter
        assetsInstance.updateAssetConfig(
            address(wethInstance), // asset
            address(wethassetsInstance), // oracle
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // borrow threshold (80%)
            850, // liquidation threshold (85%)
            1_000_000 ether, // max supply
            0, // no isolation debt cap (moved before tier)
            IASSETS.CollateralTier.CROSS_A, // tier
            IASSETS.OracleType.CHAINLINK // new oracle type parameter
        );

        // Register oracles with Oracle module
        // Updated addOracle calls with OracleType parameter
        //assetsInstance.addOracle(address(wethInstance), address(wethassetsInstance), 8, IASSETS.OracleType.CHAINLINK);
        assetsInstance.setPrimaryOracle(address(wethInstance), address(wethassetsInstance));

        //assetsInstance.addOracle(address(rwaToken), address(rwaassetsInstance), 8, IASSETS.OracleType.CHAINLINK);
        assetsInstance.setPrimaryOracle(address(rwaToken), address(rwaassetsInstance));
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
        wethassetsInstance.setPrice(2500e8); // $2500 per ETH
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
        wethassetsInstance.setPrice(0); // Set invalid price

        // Use custom error from IASSETS interface
        vm.expectRevert(abi.encodeWithSelector(IASSETS.OracleInvalidPrice.selector, address(wethassetsInstance), 0));
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
                address(wethassetsInstance),
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
        vm.prank(guardian);
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
        // Setup low max supply for WETH
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(wethassetsInstance),
            8,
            18,
            1,
            800,
            850,
            5 ether, // Low max supply of 5 ETH
            0, // no isolation debt cap (moved before tier)
            IASSETS.CollateralTier.CROSS_A, // tier
            IASSETS.OracleType.CHAINLINK // new oracle type parameter
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
}
