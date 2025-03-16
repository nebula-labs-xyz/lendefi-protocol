// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";
import {RWAPriceConsumerV3} from "../../../contracts/mock/RWAOracle.sol";
import {MockRWA} from "../../../contracts/mock/MockRWA.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";

contract IsLiquidatableComprehensiveTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    RWAPriceConsumerV3 internal rwaOracleInstance;
    RWAPriceConsumerV3 internal crossBOracleInstance;

    MockRWA internal stableToken;
    MockRWA internal rwaToken;
    MockRWA internal crossBToken;

    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    uint256 constant ETH_PRICE = 2500e8; // $2500 per ETH
    uint256 constant WAD = 1e6; // Same as contract's WAD

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy tokens
        wethInstance = new WETH9();
        stableToken = new MockRWA("USDT", "USDT");
        rwaToken = new MockRWA("Ondo Finance", "ONDO");
        crossBToken = new MockRWA("Cross B Token", "CROSSB");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();
        crossBOracleInstance = new RWAPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(int256(ETH_PRICE)); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token
        crossBOracleInstance.setPrice(500e8); // $500 per CROSSB token

        // Setup roles
        vm.prank(address(timelockInstance));
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
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );

        // Configure Stable token as STABLE tier
        assetsInstance.updateAssetConfig(
            address(stableToken),
            address(stableOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000 ether, // Supply limit
            0,
            IASSETS.CollateralTier.STABLE,
            IASSETS.OracleType.CHAINLINK
        );

        // Configure RWA token as ISOLATED tier
        assetsInstance.updateAssetConfig(
            address(rwaToken),
            address(rwaOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            650, // 65% borrow threshold
            750, // 75% liquidation threshold
            1_000_000 ether, // Supply limit
            100_000e6, // Isolation debt cap
            IASSETS.CollateralTier.ISOLATED,
            IASSETS.OracleType.CHAINLINK
        );

        // Configure CROSS_B token
        assetsInstance.updateAssetConfig(
            address(crossBToken),
            address(crossBOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            700, // 70% borrow threshold
            800, // 80% liquidation threshold
            1_000_000 ether, // Supply limit
            0,
            IASSETS.CollateralTier.CROSS_B,
            IASSETS.OracleType.CHAINLINK
        );

        assetsInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));
        assetsInstance.setPrimaryOracle(address(stableToken), address(stableOracleInstance));
        assetsInstance.setPrimaryOracle(address(rwaToken), address(rwaOracleInstance));
        assetsInstance.setPrimaryOracle(address(crossBToken), address(crossBOracleInstance));
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

    function _createPositionWithAsset(address user, address asset, uint256 amount, bool isIsolated)
        internal
        returns (uint256 positionId)
    {
        vm.startPrank(user);

        // Create position
        LendefiInstance.createPosition(asset, isIsolated);
        positionId = LendefiInstance.getUserPositionsCount(user) - 1;

        // Mint and provide collateral
        if (asset == address(stableToken) || asset == address(rwaToken) || asset == address(crossBToken)) {
            MockRWA(asset).mint(user, amount);
            MockRWA(asset).approve(address(LendefiInstance), amount);
        } else if (asset == address(wethInstance)) {
            vm.deal(user, amount);
            wethInstance.deposit{value: amount}();
            wethInstance.approve(address(LendefiInstance), amount);
        }

        LendefiInstance.supplyCollateral(asset, amount, positionId);

        vm.stopPrank();
        return positionId;
    }

    function _borrowUSDC(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        LendefiInstance.borrow(positionId, amount);
        vm.stopPrank();
    }

    // Test 1: Zero debt position should never be liquidatable
    function test_IsLiquidatable_ZeroDebt() public {
        // Create a position with collateral but no debt
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // Check health factor - should be max value with zero debt
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        assertEq(healthFactorValue, type(uint256).max, "Health factor should be max for zero debt");

        // Check isLiquidatable - should be false with no debt
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertFalse(liquidatable, "Position with zero debt should not be liquidatable");
    }

    // Test 2: Well-collateralized position should not be liquidatable
    function test_IsLiquidatable_SafePosition() public {
        // Create a position with 10 ETH collateral (worth $25,000)
        uint256 positionId = _createPositionWithCollateral(alice, 10 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is $20,000
        uint256 borrowAmount = 15_000e6; // $15,000 - well under the limit
        _borrowUSDC(alice, positionId, borrowAmount);

        // Check health factor - should be well above 1.0 (WAD)
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        console2.log("Health factor for safe position:", healthFactorValue);
        assertGt(healthFactorValue, WAD, "Health factor should be above 1.0 for safe position");

        // Check isLiquidatable - should be false (safe position)
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertFalse(liquidatable, "Position with debt under credit limit should not be liquidatable");

        // Get position details for logging
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);
        uint256 collateralValue = LendefiInstance.calculateCollateralValue(alice, positionId);
        uint256 liqThresholdValue = (collateralValue * 850) / 1000; // 85% liquidation threshold

        console2.log("Debt for safe position:", debt);
        console2.log("Credit limit for safe position:", creditLimit);
        console2.log("Collateral value:", collateralValue);
        console2.log("Liquidation threshold value:", liqThresholdValue);
        console2.log("Safety margin:", liqThresholdValue - debt);
    }

    // Test 3: Position becomes liquidatable after interest accrual
    function test_IsLiquidatable_BorderlinePosition() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 80% borrow threshold, credit limit is $2,000
        // (not the 85% liquidation threshold of $2,125)
        uint256 borrowAmount = 1_990e6; // $1,990 - just below credit limit
        _borrowUSDC(alice, positionId, borrowAmount);

        // Should not be liquidatable at this point (close but not over)
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        console2.log("Initial health factor:", healthFactorValue);

        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        assertGt(healthFactorValue, WAD, "Health factor should be above 1.0 initially");
        assertFalse(liquidatable, "Position should not be liquidatable initially");

        // Time passes, interest accrues
        vm.roll(block.number + 10000); // Some blocks pass
        vm.warp(block.timestamp + 400 days); // 400 days pass

        // Update the oracle after time warp to prevent timeout
        // The oracle must be updated with a fresh timestamp after time warping
        wethOracleInstance.setPrice(int256(ETH_PRICE)); // Same price, but updated timestamp

        // Now with accrued interest, it might be liquidatable
        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Get position details for logging
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 collateralValue = LendefiInstance.calculateCollateralValue(alice, positionId);
        uint256 liqThresholdValue = (collateralValue * 850) / 1000; // 85% liquidation threshold

        console2.log("Debt after interest accrual:", debt);
        console2.log("Liquidation threshold:", liqThresholdValue);
        console2.log("Health factor after interest:", healthFactorValue);

        // Check if debt has crossed liquidation threshold
        if (healthFactorValue < WAD) {
            assertTrue(liquidatable, "Position should be liquidatable after interest accrual");
            assertGt(debt, liqThresholdValue, "Debt should exceed liquidation threshold");
        } else {
            assertFalse(liquidatable, "Position should not be liquidatable if health factor >= 1.0");
            assertLe(debt, liqThresholdValue, "Debt should be below liquidation threshold");

            // Force liquidatable state by dropping the price instead of raising debt
            wethOracleInstance.setPrice(2300e8); // Drop price from $2500 to $2300

            // Now should be liquidatable
            liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
            healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
            assertTrue(liquidatable, "Position should be liquidatable after price drop");
            assertLt(healthFactorValue, WAD, "Health factor should be below 1.0");
        }
    }

    // Test 4: Position becomes liquidatable after price drop
    function test_IsLiquidatable_PriceDropLiquidation() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 85% liquidation threshold, liquidation threshold is $2,125
        uint256 borrowAmount = 1_900e6; // $1,900 - safe initially
        _borrowUSDC(alice, positionId, borrowAmount);

        // Initially not liquidatable
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        assertGt(healthFactorValue, WAD, "Health factor should be above 1.0 initially");
        assertFalse(LendefiInstance.isLiquidatable(alice, positionId), "Position should not be liquidatable initially");

        // ETH price drops to push below liquidation threshold
        // At $2,235 per ETH, liquidation threshold = $2,235 * 0.85 = $1,900
        wethOracleInstance.setPrice(2235e8);

        // Check if exactly at liquidation threshold
        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        console2.log("Health factor at $2,235:", healthFactorValue);
        console2.log("Liquidatable at $2,235:", liquidatable);

        // Now drop it below liquidation threshold (slightly below $2,235)
        wethOracleInstance.setPrice(2230e8);

        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Get updated position details
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 collateralValue = LendefiInstance.calculateCollateralValue(alice, positionId);
        uint256 liqThresholdValue = (collateralValue * 850) / 1000; // 85% liquidation threshold

        console2.log("Health factor at $2,230:", healthFactorValue);
        console2.log("Liquidatable at $2,230:", liquidatable);
        console2.log("Debt:", debt);
        console2.log("Collateral value:", collateralValue);
        console2.log("Liquidation threshold value:", liqThresholdValue);

        // Position should be liquidatable
        assertLt(healthFactorValue, WAD, "Health factor should be below 1.0 after sufficient price drop");
        assertTrue(liquidatable, "Position should be liquidatable after sufficient price drop");
        assertGt(debt, liqThresholdValue, "Debt should exceed liquidation threshold");
    }

    // Test 5: Position becomes safe again after price increase
    function test_IsLiquidatable_PriceRecovery() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 85% liquidation threshold, liquidation threshold is $2,125
        uint256 borrowAmount = 1_900e6; // $1,900
        _borrowUSDC(alice, positionId, borrowAmount);

        // Drop ETH price to make position liquidatable
        // At $2,200 per ETH, liquidation threshold = $2,200 * 0.85 = $1,870
        wethOracleInstance.setPrice(2200e8);

        // Check if liquidatable
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        console2.log("Health factor at $2,200:", healthFactorValue);
        console2.log("Liquidatable at $2,200:", liquidatable);
        assertTrue(liquidatable, "Position should be liquidatable after price drop");
        assertLt(healthFactorValue, WAD, "Health factor should be below 1.0 after price drop");

        // Now price recovers
        wethOracleInstance.setPrice(2500e8); // Back to original price

        // Check if safe again
        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        console2.log("Health factor after recovery:", healthFactorValue);
        console2.log("Liquidatable after recovery:", liquidatable);
        assertFalse(liquidatable, "Position should not be liquidatable after price recovery");
        assertGt(healthFactorValue, WAD, "Health factor should be above 1.0 after price recovery");
    }

    // Test 6: Position becomes safe after partial repayment
    function test_IsLiquidatable_AfterPartialRepayment() public {
        // Create a position with 1 ETH collateral (worth $2,500)
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // For CROSS_A tier with 85% liquidation threshold, liquidation threshold is $2,125
        uint256 borrowAmount = 2_000e6; // $2,000 - within the borrow limit but close to liquidation threshold
        _borrowUSDC(alice, positionId, borrowAmount);

        // Not liquidatable yet
        assertFalse(LendefiInstance.isLiquidatable(alice, positionId), "Position should not be liquidatable initially");

        // Drop ETH price to make position liquidatable
        // At $2,200 per ETH, liquidation threshold = $2,200 * 0.85 = $1,870
        wethOracleInstance.setPrice(2200e8); // Drop from $2500 to $2200

        // Should be liquidatable after price drop
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);

        console2.log("Health factor after price drop:", healthFactorValue);
        console2.log("Liquidatable after price drop:", liquidatable);
        assertTrue(liquidatable, "Position should be liquidatable after price drop");
        assertLt(healthFactorValue, WAD, "Health factor should be below 1.0 after price drop");

        // Now partially repay the loan to make it safe again
        usdcInstance.mint(alice, 300e6); // Give Alice some USDC
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 300e6);
        LendefiInstance.repay(positionId, 300e6); // Repay $300
        vm.stopPrank();

        // Check if still liquidatable after repayment
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);

        // Get updated position details
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        uint256 collateralValue = LendefiInstance.calculateCollateralValue(alice, positionId);
        uint256 liqThresholdValue = (collateralValue * 850) / 1000; // 85% liquidation threshold

        console2.log("Health factor after partial repayment:", healthFactorValue);
        console2.log("Liquidatable after partial repayment:", liquidatable);
        console2.log("Debt after partial repayment:", debt);
        console2.log("Liquidation threshold value:", liqThresholdValue);

        // Now the position should be safe (debt reduced below liquidation threshold)
        assertFalse(liquidatable, "Position should not be liquidatable after partial repayment");
        assertGt(healthFactorValue, WAD, "Health factor should be above 1.0 after partial repayment");
        assertLe(debt, liqThresholdValue, "Debt should be below liquidation threshold after repayment");
    }

    // Test 7: Test with isolated position (RWA token)
    function test_IsLiquidatable_IsolatedPosition() public {
        // Create an isolated position with RWA token (worth $1000 per token)
        uint256 positionId = _createPositionWithAsset(alice, address(rwaToken), 5 ether, true);

        // For ISOLATED tier with 75% liquidation threshold, liquidation threshold is $3750
        uint256 borrowAmount = 3_000e6; // $3,000 - safe initially
        _borrowUSDC(alice, positionId, borrowAmount);

        // Check initial health factor
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        console2.log("Initial health factor for isolated position:", healthFactorValue);
        console2.log("Initial liquidatable status:", liquidatable);
        assertGt(healthFactorValue, WAD, "Health factor should be above 1.0 initially");
        assertFalse(liquidatable, "Isolated position should not be liquidatable initially");

        // Drop RWA token price to $800 per token
        // Collateral value: 5 * $800 = $4,000
        // Liquidation threshold: $4,000 * 0.75 = $3,000
        // Debt: $3,000 - exactly at liquidation threshold
        rwaOracleInstance.setPrice(800e8);

        // Check health factor at threshold
        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        console2.log("Health factor at threshold:", healthFactorValue);
        console2.log("Liquidatable at threshold:", liquidatable);

        // Now drop price further to $790
        // Liquidation threshold: 5 * $790 * 0.75 = $2,962.50
        // Position should be liquidatable
        rwaOracleInstance.setPrice(790e8);

        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        uint256 collateralValue = LendefiInstance.calculateCollateralValue(alice, positionId);
        uint256 liqThresholdValue = (collateralValue * 750) / 1000; // 75% liquidation threshold for isolated
        uint256 debt = LendefiInstance.calculateDebtWithInterest(alice, positionId);

        console2.log("Health factor below threshold:", healthFactorValue);
        console2.log("Liquidatable below threshold:", liquidatable);
        console2.log("Collateral value at $790:", collateralValue);
        console2.log("Liquidation threshold value:", liqThresholdValue);
        console2.log("Debt:", debt);

        assertLt(healthFactorValue, WAD, "Health factor should be below 1.0 when undercollateralized");
        assertTrue(liquidatable, "Position should be liquidatable when below liquidation threshold");
        assertGt(debt, liqThresholdValue, "Debt should exceed liquidation threshold");
    }

    // Test 8: Multi-collateral position liquidation check
    function test_IsLiquidatable_MultipleCollateralAssets() public {
        // Create position with ETH
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // Add ETH collateral
        vm.deal(alice, 1 ether);
        wethInstance.deposit{value: 1 ether}();
        wethInstance.approve(address(LendefiInstance), 1 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, positionId);

        // Add CROSSB collateral
        crossBToken.mint(alice, 2e18);
        crossBToken.approve(address(LendefiInstance), 2e18);
        LendefiInstance.supplyCollateral(address(crossBToken), 2e18, positionId);
        vm.stopPrank();

        // Calculate total collateral value (weighted by respective liquidation thresholds)
        // ETH: 1 ETH * $2500 * 85% = $2,125
        // CROSSB: 2 tokens * $500 * 80% = $800
        // Total weighted: $2,925

        // Borrow close to this aggregated liquidation threshold
        _borrowUSDC(alice, positionId, 2600e6);

        // Initially not liquidatable
        assertFalse(
            LendefiInstance.isLiquidatable(alice, positionId),
            "Multi-collateral position should not be liquidatable initially"
        );

        // Drop ETH price by 10%
        wethOracleInstance.setPrice(2250e8); // $2250 per ETH

        // Position may still be safe
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        console2.log("Health factor after ETH price drop:", healthFactorValue);

        // Now drop both asset prices
        wethOracleInstance.setPrice(2250e8); // $2250 per ETH (-10%)
        crossBOracleInstance.setPrice(450e8); // $450 per CROSSB token (-10%)

        healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
        console2.log("Health factor after both price drops:", healthFactorValue);
        console2.log("Liquidatable after both price drops:", liquidatable);

        if (healthFactorValue < 1e6) {
            assertTrue(liquidatable, "Position should be liquidatable after both prices drop");
        } else {
            // If not liquidatable, drop prices more
            wethOracleInstance.setPrice(2000e8); // $2000 per ETH (-20%)
            crossBOracleInstance.setPrice(400e8); // $400 per CROSSB token (-20%)

            healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
            liquidatable = LendefiInstance.isLiquidatable(alice, positionId);
            console2.log("Health factor after larger price drops:", healthFactorValue);
            console2.log("Liquidatable after larger price drops:", liquidatable);
            assertTrue(liquidatable, "Position should be liquidatable after larger price drops");
            assertTrue(healthFactorValue < 1e6, "Health factor should be less than 1e6");
        }
    }

    // Test 9: Fuzz test for health factor calculation and liquidation threshold
    function testFuzz_IsLiquidatable_HealthFactorThreshold(uint256 pricePercent) public {
        // Bound the price percentage between 70% and 100% of the original
        pricePercent = bound(pricePercent, 70, 100);

        // Create position with 1 ETH
        uint256 positionId = _createPositionWithCollateral(alice, 1 ether);

        // Borrow 1900e6 (below the credit limit)
        _borrowUSDC(alice, positionId, 1900e6);

        // Calculate new price based on percentage
        uint256 newPrice = (ETH_PRICE * pricePercent) / 100;
        wethOracleInstance.setPrice(int256(newPrice));

        // Check health factor and liquidation status
        uint256 healthFactorValue = LendefiInstance.healthFactor(alice, positionId);
        bool liquidatable = LendefiInstance.isLiquidatable(alice, positionId);

        // Log values for analysis
        console2.log("Price percent:", pricePercent);
        console2.log("New price:", newPrice);
        console2.log("Health factor:", healthFactorValue);
        console2.log("Liquidatable:", liquidatable);
    }
}
