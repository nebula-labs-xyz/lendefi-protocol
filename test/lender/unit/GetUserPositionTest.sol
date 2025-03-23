// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";

contract GetUserPositionTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

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
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable

        // Setup roles
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
        _addLiquidity(1_000_000e6); // 1M USDC
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier - Changed to struct-based approach
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18, // Asset decimals
                borrowThreshold: 800, // 80% borrow threshold
                liquidationThreshold: 850, // 85% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether, // Supply limit
                isolationDebtCap: 0, // No isolation debt cap for cross assets
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

        // Configure USDC as STABLE tier - Changed to struct-based approach
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6, // USDC decimals
                borrowThreshold: 900, // 90% borrow threshold
                liquidationThreshold: 950, // 95% liquidation threshold
                maxSupplyThreshold: 1_000_000e6, // Supply limit with 6 decimals
                isolationDebtCap: 0, // No isolation debt cap
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

    function test_GetUserPosition_Empty() public {
        // Create a position without any collateral or debt
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false); // Non-isolated position
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get the position
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);

        // Verify initial state
        assertEq(position.isIsolated, false, "Position should not be isolated");
        assertEq(assets.length, 0, "Non Isolated asset should be zero address");
        assertEq(position.debtAmount, 0, "Debt amount should be zero");
        assertEq(position.lastInterestAccrual, 0, "Last interest accrual should be zero");
    }

    function test_GetUserPosition_WithCollateral() public {
        // Create a position and add collateral
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Add ETH collateral
        uint256 collateralAmount = 5 ether;
        vm.deal(alice, collateralAmount);
        vm.startPrank(alice);
        wethInstance.deposit{value: collateralAmount}();
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);
        vm.stopPrank();

        // Get the position
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);

        // Verify state after adding collateral
        assertEq(position.isIsolated, false, "Position should not be isolated");
        assertEq(assets[0], address(wethInstance), "Non Isolated asset should not be zero address");
        assertEq(position.debtAmount, 0, "Debt amount should be zero");
        assertEq(position.lastInterestAccrual, 0, "Last interest accrual should be zero");

        // Verify collateral was added (need separate function call to check this)
        // Changed from getUserCollateralAmount to getCollateralAmount
        uint256 collateralBalance = LendefiInstance.getCollateralAmount(alice, positionId, address(wethInstance));
        assertEq(collateralBalance, collateralAmount, "Collateral balance incorrect");
    }

    function test_GetUserPosition_WithDebt() public {
        // Create a position, add collateral and borrow
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Add ETH collateral
        uint256 collateralAmount = 10 ether; // Worth $25,000
        vm.deal(alice, collateralAmount);
        vm.startPrank(alice);
        wethInstance.deposit{value: collateralAmount}();
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow USDC
        uint256 borrowAmount = 10_000e6; // $10,000
        LendefiInstance.borrow(positionId, borrowAmount);

        // Store current timestamp for verification
        uint256 currentTimestamp = block.timestamp;
        vm.stopPrank();

        // Get the position
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);

        // Verify state after borrowing
        assertEq(position.isIsolated, false, "Position should not be isolated");
        assertEq(assets[0], address(wethInstance), "Non Isolated asset should be weth address");
        assertEq(position.debtAmount, borrowAmount, "Debt amount should match borrowed amount");
        assertEq(position.lastInterestAccrual, currentTimestamp, "Last interest accrual should be current timestamp");
    }

    function test_GetUserPosition_IsolatedMode() public {
        // Create an isolated position
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), true); // Isolated position
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get the position
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(alice, positionId);

        // Verify isolated position state
        assertEq(position.isIsolated, true, "Position should be isolated");
        assertEq(assets[0], address(wethInstance), "Isolated asset should be WETH");
        assertEq(position.debtAmount, 0, "Debt amount should be zero");
        assertEq(position.lastInterestAccrual, 0, "Last interest accrual should be zero");
    }

    function test_GetUserPosition_MultiplePositions() public {
        // Create  different positions
        vm.startPrank(alice);

        // Position 1: Non-isolated with WETH
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId1 = LendefiInstance.getUserPositionsCount(alice) - 1;

        // Position 2: Isolated with USDC
        LendefiInstance.createPosition(address(usdcInstance), true);
        uint256 positionId2 = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Get both positions
        IPROTOCOL.UserPosition memory position1 = LendefiInstance.getUserPosition(alice, positionId1);
        IPROTOCOL.UserPosition memory position2 = LendefiInstance.getUserPosition(alice, positionId2);
        address[] memory assets1 = LendefiInstance.getPositionCollateralAssets(alice, positionId1);
        address[] memory assets2 = LendefiInstance.getPositionCollateralAssets(alice, positionId2);

        // Verify position 1
        assertEq(position1.isIsolated, false, "Position 1 should not be isolated");
        assertEq(assets1.length, 0, "Position 1 isolated asset should be zero address");

        // Verify position 2
        assertEq(position2.isIsolated, true, "Position 2 should be isolated");
        assertEq(assets2[0], address(usdcInstance), "Position 2 isolated asset should be USDC");
    }

    function test_GetUserPosition_InvalidPosition() public {
        // Try to get a position that doesn't exist
        // Use custom error instead of string error
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector));
        LendefiInstance.getUserPosition(alice, 0);

        // Create a position
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        vm.stopPrank();

        // Should work now
        LendefiInstance.getUserPosition(alice, 0);

        // But invalid with position ID 1
        // Use custom error instead of string error
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector));
        LendefiInstance.getUserPosition(alice, 1);
    }

    function test_GetUserPosition_AfterModification() public {
        // Create a position and add collateral
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        uint256 collateralAmount = 10 ether;
        vm.deal(alice, collateralAmount);
        wethInstance.deposit{value: collateralAmount}();
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow USDC
        uint256 borrowAmount = 10_000e6;
        LendefiInstance.borrow(positionId, borrowAmount);

        // Store current timestamp and position
        uint256 borrowTimestamp = block.timestamp;
        // IPROTOCOL.UserPosition memory positionBefore = LendefiInstance.getUserPosition(alice, positionId);

        // Warp time forward to accrue interest
        vm.warp(block.timestamp + 30 days);

        // Get debt with interest before repayment
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        console2.log("Original debt:", borrowAmount);
        console2.log("Debt with interest after 30 days:", debtWithInterest);
        uint256 interestAccrued = debtWithInterest - borrowAmount;
        console2.log("Interest accrued:", interestAccrued);

        // Repay half the loan
        uint256 repayAmount = 5_000e6;
        usdcInstance.approve(address(LendefiInstance), repayAmount);
        LendefiInstance.repay(positionId, repayAmount);

        // Store new timestamp
        uint256 repayTimestamp = block.timestamp;
        vm.stopPrank();

        // Get the position
        IPROTOCOL.UserPosition memory positionAfter = LendefiInstance.getUserPosition(alice, positionId);
        console2.log("Debt amount after repayment:", positionAfter.debtAmount);
        console2.log("Repayment amount:", repayAmount);

        // Verify updated state - accounting for interest accrual
        // The debt should be reduced, but not by the full repayment amount due to interest
        uint256 expectedDebtAfterRepayment = borrowAmount + interestAccrued - repayAmount;
        console2.log("Expected debt after repayment:", expectedDebtAfterRepayment);

        // Use assertApproxEqAbs to allow for tiny rounding differences
        assertApproxEqAbs(
            positionAfter.debtAmount,
            expectedDebtAfterRepayment,
            2, // Allow a very small rounding error
            "Debt amount should match (original + interest - repayment)"
        );

        // Also verify the last interest accrual timestamp was updated
        assertEq(positionAfter.lastInterestAccrual, repayTimestamp, "Last interest accrual should be updated");
        assertTrue(positionAfter.lastInterestAccrual > borrowTimestamp, "Interest accrual timestamp should increase");
    }
}
