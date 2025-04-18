// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {LendefiView} from "../../../contracts/lender/LendefiView.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";

contract GetPositionSummaryTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    LendefiView internal viewInstance;

    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    uint256 constant ETH_PRICE = 2500e8; // $2500 per ETH

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
        wethOracleInstance.setPrice(int256(ETH_PRICE)); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable

        // Setup roles
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
        _addLiquidity(INITIAL_LIQUIDITY);

        // Deploy LendefiView
        viewInstance = new LendefiView(
            address(LendefiInstance), address(usdcInstance), address(yieldTokenInstance), address(ecoInstance)
        );
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier - Changed to new struct-based approach
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18, // WETH decimals
                borrowThreshold: 800, // 80% borrow threshold
                liquidationThreshold: 850, // 85% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether, // Supply limit
                isolationDebtCap: 10_000e6, // Add isolation debt cap of 10,000 USDC
                assetMinimumOracles: 1, // Need at least 1 oracle
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

        // Configure USDC as STABLE tier - Changed to new struct-based approach
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6, // USDC has 6 decimals
                borrowThreshold: 900, // 90% borrow threshold
                liquidationThreshold: 950, // 95% liquidation threshold
                maxSupplyThreshold: 1_000_000e6, // Supply limit with 6 decimals
                isolationDebtCap: 0, // No isolation debt cap for STABLE tier
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(stableOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
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

    function _createPositionWithCollateral(
        address user,
        address collateralAsset,
        uint256 collateralAmount,
        bool isIsolated
    ) internal returns (uint256 positionId) {
        vm.startPrank(user);

        // Create position
        LendefiInstance.createPosition(collateralAsset, isIsolated);
        positionId = LendefiInstance.getUserPositionsCount(user) - 1;

        // Provide collateral
        if (collateralAsset == address(wethInstance)) {
            vm.deal(user, collateralAmount);
            wethInstance.deposit{value: collateralAmount}();
            wethInstance.approve(address(LendefiInstance), collateralAmount);
        } else {
            usdcInstance.mint(user, collateralAmount);
            usdcInstance.approve(address(LendefiInstance), collateralAmount);
        }

        LendefiInstance.supplyCollateral(collateralAsset, collateralAmount, positionId);
        vm.stopPrank();

        return positionId;
    }

    function _borrowUSDC(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        LendefiInstance.borrow(positionId, amount);
        vm.stopPrank();
    }

    function test_GetPositionSummary_NonIsolatedPosition() public {
        // Create a non-isolated position with WETH as collateral
        uint256 collateralAmount = 10 ether; // 10 ETH @ $2500 = $25,000
        uint256 positionId = _createPositionWithCollateral(alice, address(wethInstance), collateralAmount, false);

        // With 80% borrow threshold for CROSS_A tier, credit limit should be $20,000
        uint256 borrowAmount = 10_000e6; // $10,000
        _borrowUSDC(alice, positionId, borrowAmount);

        // Get position summary using view contract
        LendefiView.PositionSummary memory summary = viewInstance.getPositionSummary(alice, positionId);

        // Log results
        console2.log("Total collateral value:", summary.totalCollateralValue);
        console2.log("Current debt:", summary.currentDebt);
        console2.log("Available credit:", summary.availableCredit);
        console2.log("Health factor:", summary.healthFactor);
        console2.log("Is isolated:", summary.isIsolated ? "Yes" : "No");
        console2.log("Position status:", uint256(summary.status));

        // Calculate expected collateral value
        // 10 ETH * $2500 * WAD / 1e18 / 1e8 = $25,000
        uint256 expectedCollateralValue = (10 ether * 2500e8 * 1e6) / 1e18 / 1e8;

        // In the Lendefi.sol contract, the healthFactor function returns (liqLevel * WAD) / debt
        // liqLevel = (10e18 * 2500e8 * 850 * 1e6) / (1e18 * 1000 * 1e8) = 21,250e6
        // healthFactor = (21,250e6 * 1e6) / 10,000e6 = 2,125,000 (2.125e6)
        uint256 expectedHealthFactor = (21_250e6 * 1e6) / 10_000e6; // 2.125e6

        // Verify returned values
        assertEq(summary.totalCollateralValue, expectedCollateralValue, "Total collateral value incorrect");
        assertEq(summary.currentDebt, borrowAmount, "Current debt incorrect"); // No interest has accrued yet
        assertEq(summary.availableCredit, (expectedCollateralValue * 800) / 1000, "Available credit incorrect");
        assertEq(summary.healthFactor, expectedHealthFactor, "Health factor incorrect");
        assertFalse(summary.isIsolated, "Position should not be isolated");
        assertEq(uint256(summary.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position should be active");
    }

    function test_GetPositionSummary_IsolatedPosition() public {
        // Create an isolated position with WETH as collateral
        uint256 collateralAmount = 5 ether; // 5 ETH @ $2500 = $12,500
        uint256 positionId = _createPositionWithCollateral(alice, address(wethInstance), collateralAmount, true);

        // With 80% borrow threshold for CROSS_A tier, credit limit should be $10,000
        // Isolation debt cap is 10,000 USDC so we stay under that limit
        uint256 borrowAmount = 5_000e6; // $5,000
        _borrowUSDC(alice, positionId, borrowAmount);

        // Get position summary using view contract
        LendefiView.PositionSummary memory summary = viewInstance.getPositionSummary(alice, positionId);

        // Log results
        console2.log("Total collateral value (isolated):", summary.totalCollateralValue);
        console2.log("Current debt (isolated):", summary.currentDebt);
        console2.log("Available credit (isolated):", summary.availableCredit);
        console2.log("Health factor (isolated):", summary.healthFactor);
        console2.log("Is isolated:", summary.isIsolated ? "Yes" : "No");
        console2.log("Position status:", uint256(summary.status));

        // Calculate expected collateral value
        // 5 ETH * $2500 * WAD / 1e18 / 1e8 = $12,500
        uint256 expectedCollateralValue = (5 ether * 2500e8 * 1e6) / 1e18 / 1e8;

        // Based on how healthFactor is calculated in Lendefi.sol:
        // For 5 ETH at $2500 with 85% liquidation threshold and $5,000 debt:
        // liqLevel = (5e18 * 2500e8 * 850 * 1e6) / (1e18 * 1000 * 1e8) = 10,625e6
        // healthFactor = (10,625e6 * 1e6) / 5,000e6 = 2,125,000 (2.125e6)
        uint256 expectedHealthFactor = (10_625e6 * 1e6) / 5_000e6; // 2.125e6

        // Verify returned values
        assertEq(summary.totalCollateralValue, expectedCollateralValue, "Total collateral value incorrect");
        assertEq(summary.currentDebt, borrowAmount, "Current debt incorrect"); // No interest has accrued yet
        assertEq(summary.availableCredit, (expectedCollateralValue * 800) / 1000, "Available credit incorrect");
        assertEq(summary.healthFactor, expectedHealthFactor, "Health factor incorrect");
        assertTrue(summary.isIsolated, "Position should be isolated");
        assertEq(uint256(summary.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position should be active");
    }

    function test_GetPositionSummary_WithInterestAccrual() public {
        // Create a position with ETH collateral
        uint256 collateralAmount = 10 ether; // 10 ETH @ $2500 = $25,000
        uint256 positionId = _createPositionWithCollateral(alice, address(wethInstance), collateralAmount, false);

        // Borrow some USDC
        uint256 borrowAmount = 10_000e6; // $10,000
        _borrowUSDC(alice, positionId, borrowAmount);

        // Get position summary before time passes using view contract
        LendefiView.PositionSummary memory initialSummary = viewInstance.getPositionSummary(alice, positionId);
        uint256 initialDebt = initialSummary.currentDebt;
        uint256 initialHealthFactor = initialSummary.healthFactor;

        // Calculate initial remaining credit (what can still be borrowed)
        uint256 initialRemainingCredit = initialSummary.availableCredit - initialDebt;

        // Time passes, interest accrues
        vm.warp(block.timestamp + 365 days); // 1 year passes

        // Update oracle after time warp
        wethOracleInstance.setPrice(int256(ETH_PRICE)); // Same price, updated timestamp

        // Get position summary after time using view contract
        LendefiView.PositionSummary memory finalSummary = viewInstance.getPositionSummary(alice, positionId);
        uint256 finalDebt = finalSummary.currentDebt;
        uint256 finalHealthFactor = finalSummary.healthFactor;

        // Calculate final remaining credit
        uint256 finalRemainingCredit = finalSummary.availableCredit - finalDebt;

        // Log results
        console2.log("Initial debt:", initialDebt);
        console2.log("Initial health factor:", initialHealthFactor);
        console2.log("Debt after 1 year:", finalDebt);
        console2.log("Health factor after 1 year:", finalHealthFactor);
        console2.log("Interest accrued:", finalDebt - initialDebt);
        console2.log("Initial remaining credit:", initialRemainingCredit);
        console2.log("Final remaining credit:", finalRemainingCredit);

        // Verify that debt has increased due to interest
        assertGt(finalDebt, initialDebt, "Debt should increase after time passes");

        // Health factor should decrease as debt increases
        assertLt(finalHealthFactor, initialHealthFactor, "Health factor should decrease as debt increases");

        // Collateral value should remain the same if price hasn't changed
        assertEq(
            finalSummary.totalCollateralValue,
            initialSummary.totalCollateralValue,
            "Collateral value shouldn't change if price is unchanged"
        );

        // Credit limit should remain the same since collateral value hasn't changed
        assertEq(
            finalSummary.availableCredit,
            initialSummary.availableCredit,
            "Credit limit should remain the same if collateral unchanged"
        );

        // Status should remain ACTIVE
        assertEq(
            uint256(finalSummary.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position should remain active"
        );

        // The remaining credit (credit limit - debt) should decrease as debt increases
        assertLt(
            finalRemainingCredit,
            initialRemainingCredit,
            "Remaining borrowable credit should decrease as debt increases"
        );
    }

    function test_GetPositionSummary_AfterPriceChange() public {
        // Create a position with ETH collateral
        uint256 collateralAmount = 10 ether; // 10 ETH @ $2500 = $25,000
        uint256 positionId = _createPositionWithCollateral(alice, address(wethInstance), collateralAmount, false);

        // Get position summary with initial price using view contract
        LendefiView.PositionSummary memory initialSummary = viewInstance.getPositionSummary(alice, positionId);
        uint256 initialCollateralValue = initialSummary.totalCollateralValue;
        uint256 initialHealthFactor = initialSummary.healthFactor;

        // ETH price increases to $3000
        wethOracleInstance.setPrice(int256(3000e8));

        // Get position summary after price increase using view contract
        LendefiView.PositionSummary memory increasedSummary = viewInstance.getPositionSummary(alice, positionId);
        uint256 increasedCollateralValue = increasedSummary.totalCollateralValue;
        uint256 increasedHealthFactor = increasedSummary.healthFactor;
        IPROTOCOL.PositionStatus increasedStatus = increasedSummary.status;

        // ETH price drops to $2000
        wethOracleInstance.setPrice(int256(2000e8));

        // Get position summary after price decrease using view contract
        LendefiView.PositionSummary memory decreasedSummary = viewInstance.getPositionSummary(alice, positionId);
        uint256 decreasedCollateralValue = decreasedSummary.totalCollateralValue;
        uint256 decreasedHealthFactor = decreasedSummary.healthFactor;
        IPROTOCOL.PositionStatus decreasedStatus = decreasedSummary.status;

        // Log results
        console2.log("Collateral value at $2500:", initialCollateralValue);
        console2.log("Health factor at $2500:", initialHealthFactor);
        console2.log("Collateral value at $3000:", increasedCollateralValue);
        console2.log("Health factor at $3000:", increasedHealthFactor);
        console2.log("Collateral value at $2000:", decreasedCollateralValue);
        console2.log("Health factor at $2000:", decreasedHealthFactor);

        // Verify changes in collateral value
        assertGt(increasedCollateralValue, initialCollateralValue, "Collateral value should increase with price");
        assertLt(decreasedCollateralValue, initialCollateralValue, "Collateral value should decrease with price");

        // Calculate expected values
        // 10 ETH * $3000 * 1e6 / 1e18 / 1e8 = $30,000
        uint256 expectedValueAt3000 = (10 ether * 3000e8 * 1e6) / 1e18 / 1e8;
        // 10 ETH * $2000 * 1e6 / 1e18 / 1e8 = $20,000
        uint256 expectedValueAt2000 = (10 ether * 2000e8 * 1e6) / 1e18 / 1e8;

        assertEq(increasedCollateralValue, expectedValueAt3000, "Collateral value at $3000 incorrect");
        assertEq(decreasedCollateralValue, expectedValueAt2000, "Collateral value at $2000 incorrect");

        // Since there's no debt, health factor should be max regardless of price
        assertEq(initialHealthFactor, type(uint256).max, "Health factor should be max with no debt");
        assertEq(increasedHealthFactor, type(uint256).max, "Health factor should be max with no debt");
        assertEq(decreasedHealthFactor, type(uint256).max, "Health factor should be max with no debt");

        // Status should remain ACTIVE regardless of price changes
        assertEq(
            uint256(increasedStatus),
            uint256(IPROTOCOL.PositionStatus.ACTIVE),
            "Position should remain active after price increase"
        );
        assertEq(
            uint256(decreasedStatus),
            uint256(IPROTOCOL.PositionStatus.ACTIVE),
            "Position should remain active after price decrease"
        );
    }

    function test_GetPositionSummary_EmptyPosition() public {
        // Create a position without adding collateral
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get position summary using view contract
        LendefiView.PositionSummary memory summary = viewInstance.getPositionSummary(alice, positionId);

        // Verify returned values for empty position
        assertEq(summary.totalCollateralValue, 0, "Total collateral value should be 0");
        assertEq(summary.currentDebt, 0, "Current debt should be 0");
        assertEq(summary.availableCredit, 0, "Available credit should be 0");
        assertEq(summary.healthFactor, type(uint256).max, "Health factor should be max with no debt");
        assertFalse(summary.isIsolated, "Position should not be isolated");
        assertEq(uint256(summary.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "New position should be ACTIVE");
    }

    function test_GetPositionSummary_MultipleAssets() public {
        // Create a non-isolated position with WETH as collateral
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // Add WETH collateral
        uint256 wethAmount = 5 ether; // 5 ETH @ $2500 = $12,500
        vm.deal(alice, wethAmount);
        wethInstance.deposit{value: wethAmount}();
        wethInstance.approve(address(LendefiInstance), wethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), wethAmount, positionId);

        // Add USDC collateral
        uint256 usdcAmount = 10_000e6; // $10,000
        usdcInstance.mint(alice, usdcAmount);
        usdcInstance.approve(address(LendefiInstance), usdcAmount);
        LendefiInstance.supplyCollateral(address(usdcInstance), usdcAmount, positionId);
        vm.stopPrank();

        // Get position summary using view contract
        LendefiView.PositionSummary memory summary = viewInstance.getPositionSummary(alice, positionId);

        // Calculate expected collateral values
        // WETH: 5 ETH * $2500 * 1e6 / 1e18 / 1e8 = $12,500
        uint256 wethValue = (5 ether * 2500e8 * 1e6) / 1e18 / 1e8;
        // USDC: 10,000 USDC * 1e8 * 1e6 / 1e6 / 1e8 = $10,000
        uint256 usdcValue = (10_000e6 * 1e8 * 1e6) / 1e6 / 1e8;
        uint256 expectedTotalValue = wethValue + usdcValue;

        // Calculate expected credit limit
        // WETH: $12,500 * 800 / 1000 = $10,000
        uint256 wethCredit = (wethValue * 800) / 1000;
        // USDC: $10,000 * 900 / 1000 = $9,000
        uint256 usdcCredit = (usdcValue * 900) / 1000;
        uint256 expectedTotalCredit = wethCredit + usdcCredit;

        // Log results
        console2.log("WETH collateral value:", wethValue);
        console2.log("USDC collateral value:", usdcValue);
        console2.log("Total collateral value:", summary.totalCollateralValue);
        console2.log("Health factor (multi-asset):", summary.healthFactor);

        // Verify returned values
        assertEq(summary.totalCollateralValue, expectedTotalValue, "Total collateral value incorrect");
        assertEq(summary.currentDebt, 0, "Current debt should be 0");
        assertEq(summary.availableCredit, expectedTotalCredit, "Available credit incorrect");
        assertEq(summary.healthFactor, type(uint256).max, "Health factor should be max with no debt");
        assertFalse(summary.isIsolated, "Position should not be isolated");
        assertEq(uint256(summary.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position should be ACTIVE");
    }

    function test_GetPositionSummary_ClosedPosition() public {
        // Create a position with ETH collateral
        uint256 collateralAmount = 1 ether;
        uint256 positionId = _createPositionWithCollateral(alice, address(wethInstance), collateralAmount, false);

        // Close the position
        vm.startPrank(alice);
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Get position summary using view contract
        LendefiView.PositionSummary memory summary = viewInstance.getPositionSummary(alice, positionId);

        // Verify returned values for closed position
        assertEq(summary.totalCollateralValue, 0, "Collateral value should be 0 after closing");
        assertEq(summary.currentDebt, 0, "Debt should be 0 after closing");
        assertEq(summary.availableCredit, 0, "Available credit should be 0 after closing");
        assertEq(summary.healthFactor, type(uint256).max, "Health factor should be max with no debt");
        assertFalse(summary.isIsolated, "Position should not be isolated");
        assertEq(uint256(summary.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position status should be CLOSED");
    }

    function test_GetPositionSummary_LiquidatedPosition() public {
        // Create a position with ETH collateral that we'll liquidate
        uint256 collateralAmount = 5 ether;
        uint256 positionId = _createPositionWithCollateral(alice, address(wethInstance), collateralAmount, false);

        // Borrow close to maximum
        uint256 creditLimit = (collateralAmount * 2500e8 * 800 * 1e6) / 1e18 / 1000 / 1e8; // ~$10,000

        _borrowUSDC(alice, positionId, creditLimit);

        // Crash ETH price to trigger liquidation
        wethOracleInstance.setPrice(int256(2500e8 * 84 / 100)); // Liquidation threshold is 85%

        // Setup liquidator
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();
        uint256 liquidatorThreshold = config.liquidatorThreshold;
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), bob, liquidatorThreshold);

        // Calculate liquidation cost
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);

        // Liquidate the position
        usdcInstance.mint(bob, debtWithInterest * 2); // Extra buffer
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), debtWithInterest * 2);
        LendefiInstance.liquidate(alice, positionId);
        vm.stopPrank();

        // Get position summary using view contract
        LendefiView.PositionSummary memory summary = viewInstance.getPositionSummary(alice, positionId);

        // Verify returned values for liquidated position
        assertEq(summary.totalCollateralValue, 0, "Collateral value should be 0 after liquidation");
        assertEq(summary.currentDebt, 0, "Debt should be 0 after liquidation");
        assertEq(summary.availableCredit, 0, "Available credit should be 0 after liquidation");
        assertEq(summary.healthFactor, type(uint256).max, "Health factor should be max with no debt");
        assertFalse(summary.isIsolated, "Position should not be isolated");
        assertEq(
            uint256(summary.status),
            uint256(IPROTOCOL.PositionStatus.LIQUIDATED),
            "Position status should be LIQUIDATED"
        );
    }
}
