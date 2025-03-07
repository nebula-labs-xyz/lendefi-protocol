// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";
import {ILendefiAssets} from "../../../contracts/interfaces/ILendefiAssets.sol";

contract IsLiquidatableTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    int256 constant ETH_PRICE = 2500e8; // $2500 per ETH
    uint256 constant WAD = 1e6; // Same as contract's WAD

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy WETH (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(ETH_PRICE); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        // Register USDC oracle if needed
        oracleInstance.addOracle(address(usdcInstance), address(stableOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(usdcInstance), address(stableOracleInstance));
        vm.stopPrank();

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
        _addLiquidity(INITIAL_LIQUIDITY);
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // Supply limit
            ILendefiAssets.CollateralTier.CROSS_A,
            0 // No isolation debt cap
        );

        vm.stopPrank();
    }

    function _addLiquidity(uint256 amount) internal {
        usdcInstance.mint(guardian, amount);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), amount);
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();
    }

    function _createPositionWithCollateral(address user, uint256 collateralEth) internal returns (uint256 positionId) {
        vm.startPrank(user);

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        positionId = LendefiInstance.getUserPositionsCount(user) - 1;

        // Provide ETH collateral
        vm.deal(user, collateralEth);
        wethInstance.deposit{value: collateralEth}();
        wethInstance.approve(address(LendefiInstance), collateralEth);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralEth, positionId);

        vm.stopPrank();
        return positionId;
    }

    function _borrowUSDC(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        LendefiInstance.borrow(positionId, amount);
        vm.stopPrank();
    }

    function test_IsLiquidatable_ZeroDebt() public {
        // Create a position with collateral but no debt
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // Check health factor - should be max value (type(uint256).max) with zero debt
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        assertEq(healthFactorValue, type(uint256).max, "Health factor should be max for zero debt");

        // Check isLiquidatable - should be false with no debt
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertFalse(liquidatable, "Position with zero debt should not be liquidatable");
    }

    function test_IsLiquidatable_SafePosition() public {
        // Create a position with 10 ETH collateral (worth $25,000)
        uint256 positionId = _createPositionWithCollateral(alice, 10 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is $20,000
        uint256 borrowAmount = 15_000e6; // $15,000 - well under the limit
        _borrowUSDC(alice, positionId, borrowAmount);

        // Check health factor - should be above 1.0 (WAD)
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        assertGt(healthFactorValue, WAD, "Health factor should be above 1.0 for safe position");

        // Check isLiquidatable - should be false (safe position)
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertFalse(liquidatable, "Position with debt under credit limit should not be liquidatable");

        // Get position details for logging
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);
        uint256 collateralValue = LendefiInstance.calculateCollateralValue(alice, positionId);

        console2.log("Debt for safe position:", debt);
        console2.log("Credit limit for safe position:", creditLimit);
        console2.log("Collateral value:", collateralValue);
        console2.log("Health factor:", healthFactorValue);
    }

    function test_IsLiquidatable_BorderlinePosition() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is $2,000
        // and liquidation threshold is 85% ($2,125)
        uint256 borrowAmount = 1_999e6; // $1,999 - just below the limit
        _borrowUSDC(alice, positionId, borrowAmount);

        // Check health factor initially
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        assertGt(healthFactorValue, WAD, "Health factor should be above 1.0 initially");

        // Should not be liquidatable at this point
        assertFalse(
            LendefiInstance.isLiquidatable(alice, positionId),
            "Position just below liquidation threshold should not be liquidatable"
        );

        // Time passes, interest accrues
        vm.roll(block.number + 10000); // Some blocks pass
        vm.warp(block.timestamp + 400 days); // 400 days pass

        // Update the oracle after time warp to prevent timeout
        // The oracle must be updated with a fresh timestamp after time warping
        wethOracleInstance.setPrice(ETH_PRICE); // Same price, but updated timestamp

        // Now check if it's liquidatable after interest accrual
        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Get position details for logging
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 collateralValue = LendefiInstance.calculateCollateralValue(alice, positionId);
        uint256 liqThresholdValue = (collateralValue * 850) / 1000; // 85% liquidation threshold

        console2.log("Debt after interest accrual:", debt);
        console2.log("Liquidation threshold value:", liqThresholdValue);
        console2.log("Health factor after interest:", healthFactorValue);

        // Check if debt has grown beyond the liquidation threshold
        if (healthFactorValue < WAD) {
            assertTrue(liquidatable, "Position should be liquidatable when health factor < 1.0");
            assertGt(debt, liqThresholdValue, "Debt should exceed liquidation threshold");
        } else {
            assertFalse(liquidatable, "Position should not be liquidatable when health factor >= 1.0");
            assertLe(debt, liqThresholdValue, "Debt should be below liquidation threshold");
        }
    }

    function test_IsLiquidatable_PriceDropLiquidation() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is $2,000
        // and liquidation threshold is 85% ($2,125)
        uint256 borrowAmount = 1_800e6; // $1,800 - safe initially
        _borrowUSDC(alice, positionId, borrowAmount);

        // Check health factor initially
        uint256 initialHealthFactor = LendefiInstance.healthFactor(alice, positionId);
        assertGt(initialHealthFactor, WAD, "Health factor should be above 1.0 initially");

        // Initially not liquidatable
        assertFalse(LendefiInstance.isLiquidatable(alice, positionId), "Position should not be liquidatable initially");

        // ETH price drops 20% from $2500 to $2000
        wethOracleInstance.setPrice(2000e8);

        // Check health factor after price drop
        uint256 newHealthFactor = LendefiInstance.healthFactor(alice, positionId);
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Get updated position details
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 newCollateralValue = LendefiInstance.calculateCollateralValue(alice, positionId);
        uint256 liqThresholdValue = (newCollateralValue * 850) / 1000; // 85% liquidation threshold

        console2.log("Debt after price drop:", debt);
        console2.log("New collateral value:", newCollateralValue);
        console2.log("Liquidation threshold value:", liqThresholdValue);
        console2.log("Health factor after price drop:", newHealthFactor);

        // With $1800 debt and collateral now worth $2000, liquidation threshold is $1700 (85% of $2000)
        // Position should be liquidatable
        assertLt(newHealthFactor, WAD, "Health factor should be below 1.0 after price drop");
        assertTrue(liquidatable, "Position should be liquidatable after price drop");
        assertGt(debt, liqThresholdValue, "Debt should exceed liquidation threshold after price drop");
    }

    function test_IsLiquidatable_ExactlyAtLiquidationThreshold() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is $2,000
        // This is the maximum we can borrow
        uint256 borrowAmount = 1_990e6; // Just below the credit limit
        _borrowUSDC(alice, positionId, borrowAmount);

        // Check initial health factor - should be above 1.0
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        console2.log("Initial health factor:", healthFactorValue);

        // Verify position is not liquidatable yet
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertFalse(liquidatable, "Position should not be liquidatable initially");

        // Drop ETH price slightly to push below liquidation threshold
        // Need to drop from $2500 to around $2320 to make the position liquidatable
        // At $2320, liquidation threshold value = $2320 * 0.85 = $1972
        // With debt of $1990, position becomes undercollateralized
        wethOracleInstance.setPrice(2320e8);

        // Check health factor after price drop
        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Calculate values for verification and logging
        uint256 collateralValue = LendefiInstance.calculateCollateralValue(alice, positionId);
        uint256 liqThresholdValue = (collateralValue * 850) / 1000; // 85% liquidation threshold
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);

        console2.log("Health factor after price drop:", healthFactorValue);
        console2.log("Liquidatable after price drop:", liquidatable);
        console2.log("Collateral value:", collateralValue);
        console2.log("Liquidation threshold value:", liqThresholdValue);
        console2.log("Debt:", debt);

        // Check if debt has crossed liquidation threshold
        if (healthFactorValue < WAD) {
            assertTrue(liquidatable, "Position should be liquidatable when health factor < 1.0");
        } else {
            assertFalse(liquidatable, "Position should not be liquidatable when health factor >= 1.0");

            // Drop price further to ensure liquidation
            wethOracleInstance.setPrice(2300e8);

            healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
            liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

            assertLt(healthFactorValue, WAD, "Health factor should be below 1.0 after further price drop");
            assertTrue(liquidatable, "Position should be liquidatable after further price drop");
        }
    }

    function test_IsLiquidatable_AfterPartialRepayment() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is $2,000
        uint256 borrowAmount = 1_900e6; // $1,900 - within the limit
        _borrowUSDC(alice, positionId, borrowAmount);

        // Check initial health factor
        uint256 initialHealthFactor = LendefiInstance.healthFactor(alice, positionId);
        assertGt(initialHealthFactor, WAD, "Health factor should be above 1.0 initially");

        // Not liquidatable yet
        assertFalse(LendefiInstance.isLiquidatable(alice, positionId), "Position should not be liquidatable initially");

        // Drop ETH price to make position liquidatable
        wethOracleInstance.setPrice(2100e8); // Drop from $2500 to $2100

        // Credit limit is now $1680 (80% of $2100)
        // Liquidation threshold is $1785 (85% of $2100)

        // Check health factor after price drop
        uint256 healthFactorAfterDrop = LendefiInstance.healthFactor(alice, positionId);
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Should be liquidatable after price drop
        assertLt(healthFactorAfterDrop, WAD, "Health factor should be below 1.0 after price drop");
        assertTrue(liquidatable, "Position should be liquidatable after price drop");

        // Now partially repay the loan
        usdcInstance.mint(alice, 300e6); // Give Alice some USDC
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 300e6);
        LendefiInstance.repay(positionId, 300e6); // Repay $300
        vm.stopPrank();

        // Check health factor after repayment
        uint256 healthFactorAfterRepay = LendefiInstance.healthFactor(alice, positionId);
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Get updated position details
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 collateralValue = LendefiInstance.calculateCollateralValue(alice, positionId);
        uint256 liqThresholdValue = (collateralValue * 850) / 1000; // 85% liquidation threshold

        console2.log("Debt after partial repayment:", debt);
        console2.log("Liquidation threshold value:", liqThresholdValue);
        console2.log("Health factor after repayment:", healthFactorAfterRepay);

        // Now the position should be safe ($1,900 - $300 = $1,600 debt, which is less than $1,785 liquidation threshold)
        assertGt(healthFactorAfterRepay, WAD, "Health factor should be above 1.0 after repayment");
        assertFalse(liquidatable, "Position should not be liquidatable after partial repayment");
        assertLe(debt, liqThresholdValue, "Debt should be below liquidation threshold after repayment");
    }

    function test_IsLiquidatable_NearZeroDebt() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // Borrow a very small amount
        uint256 borrowAmount = 1e6; // $1 - tiny debt amount
        _borrowUSDC(alice, positionId, borrowAmount);

        // Check health factor - should be very high but not max
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        assertGt(healthFactorValue, WAD, "Health factor should be above 1.0 for minimal debt");
        assertLt(healthFactorValue, type(uint256).max, "Health factor should be less than max for non-zero debt");

        // Position should not be liquidatable
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertFalse(liquidatable, "Position with tiny debt should not be liquidatable");

        // Even with extreme price drop, position should remain safe
        wethOracleInstance.setPrice(10e8); // Drop to $10 per ETH

        // Check health factor again
        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Even with extreme price drop, $1 debt is still safe with $10 * 0.85 = $8.5 liquidation threshold
        assertGt(healthFactorValue, WAD, "Health factor should remain above 1.0 even after extreme price drop");
        assertFalse(liquidatable, "Position with tiny debt should remain safe even after extreme price drop");
    }
}
