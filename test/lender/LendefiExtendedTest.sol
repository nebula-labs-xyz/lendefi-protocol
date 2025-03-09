// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {ILendefiAssets} from "../../contracts/interfaces/ILendefiAssets.sol";
import {ILendefiOracle} from "../../contracts/interfaces/ILendefiOracle.sol";
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

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(rwaToken), address(rwaOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(rwaToken), address(rwaOracleInstance));
        vm.stopPrank();

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
        _setupLiquidity();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure RWA token (isolated)
        // Changed from LendefiInstance to assetsInstance
        assetsInstance.updateAssetConfig(
            address(rwaToken), // asset
            address(rwaOracleInstance), // oracle
            8, // oracle decimals
            18, // asset decimals
            1, // active
            650, // borrow threshold (65%)
            750, // liquidation threshold (75%)
            1_000_000 ether, // max supply
            ILendefiAssets.CollateralTier.ISOLATED,
            100_000e6 // isolation debt cap
        );

        // Configure WETH (cross-collateral)
        // Changed from LendefiInstance to assetsInstance
        assetsInstance.updateAssetConfig(
            address(wethInstance), // asset
            address(wethOracleInstance), // oracle
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // borrow threshold (80%)
            850, // liquidation threshold (85%)
            1_000_000 ether, // max supply
            ILendefiAssets.CollateralTier.CROSS_A,
            0 // no isolation debt cap
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
        uint256 borrowRate = LendefiInstance.getBorrowRate(ILendefiAssets.CollateralTier.CROSS_A);
        console2.log("Borrow rate (%):", borrowRate * 100 / 1e6);

        // Log rates and utilization
        uint256 utilization = LendefiInstance.getUtilization();

        // Get base borrow rate
        uint256 baseRate = LendefiInstance.baseBorrowRate();
        uint256 tierRate = LendefiInstance.getBorrowRate(ILendefiAssets.CollateralTier.CROSS_A);

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

    // Fixed - Using proper ILendefiOracle.OracleInvalidPrice error
    function test_OracleFailures() public {
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);

        // Mock oracle failure
        wethOracleInstance.setPrice(0); // Set invalid price

        // Use custom error from ILendefiOracle interface
        vm.expectRevert(
            abi.encodeWithSelector(ILendefiOracle.OracleInvalidPrice.selector, address(wethOracleInstance), 0)
        );
        LendefiInstance.borrow(0, 1000e6);
        vm.stopPrank();
    }

    function test_ParameterUpdates() public {
        vm.startPrank(address(timelockInstance));

        // Update protocol metrics - consolidated method
        LendefiInstance.updateProtocolMetrics(
            0.005e6, // base profit target
            0.02e6, // base borrow rate
            2_000 ether, // target reward
            180 days, // reward interval
            100_000e6, // rewardable supply
            20_000 ether // liquidator threshold
        );

        // Update tier parameters - moved to assetsInstance
        assetsInstance.updateTierParameters(ILendefiAssets.CollateralTier.CROSS_A, 0.1e6, 0.1e6);

        vm.stopPrank();

        // Verify updates
        assertEq(LendefiInstance.baseProfitTarget(), 0.005e6);
        assertEq(LendefiInstance.baseBorrowRate(), 0.02e6);
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

    // Fixed - Using proper ILendefiOracle.OracleTimeout error
    function testRevert_OracleTimeout() public {
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);

        // Warp time far into future to cause oracle timeout
        vm.warp(block.timestamp + 30 days);

        // Use custom error from ILendefiOracle interface
        // The parameters must match the exact format used in the contract
        vm.expectRevert(
            abi.encodeWithSelector(
                ILendefiOracle.OracleTimeout.selector,
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
        vm.expectRevert(bytes("ZA"));
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
        vm.expectRevert(bytes("IN")); // IN = Invalid position
        LendefiInstance.borrow(999, 1000e6);

        vm.stopPrank();
    }

    // Test - Use proper asset capacity error code
    function testRevert_ExceedAssetSupplyLimit() public {
        // Setup low max supply for WETH
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8,
            18,
            1,
            800,
            850,
            5 ether, // Low max supply of 5 ETH
            ILendefiAssets.CollateralTier.CROSS_A,
            0
        );
        vm.stopPrank();

        // Try to supply more than the limit
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        wethInstance.approve(address(LendefiInstance), 10 ether);

        // First supply 5 ETH (at limit)
        LendefiInstance.supplyCollateral(address(wethInstance), 5 ether, 0);

        // Use "AC" instead of "MS" to match the actual error in Lendefi.sol
        // In _validateDeposit(): require(!assetsModule.isAssetAtCapacity(asset, amount), "AC");
        vm.expectRevert(bytes("AC")); // AC = Asset Capacity
        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, 0);
        vm.stopPrank();
    }
}
