// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {ILendefiAssets} from "../../../contracts/interfaces/ILendefiAssets.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";
import {TokenMock} from "../../../contracts/mock/TokenMock.sol";
import {LINK} from "../../../contracts/mock/LINK.sol";

contract getPositionLiquidationFeeTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

    // Mock tokens for different tiers
    LINK internal linkInstance; // For ISOLATED tier
    TokenMock internal uniInstance; // For CROSS_B tier

    // Default liquidation fees as defined in LendefiAssets._initializeDefaultTierParameters()
    uint256 constant STABLE_FEE = 0.01e6; // 1%
    uint256 constant CROSS_A_FEE = 0.02e6; // 2%
    uint256 constant CROSS_B_FEE = 0.03e6; // 3%
    uint256 constant ISOLATED_FEE = 0.04e6; // 4%

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();
        linkInstance = new LINK();
        uniInstance = new TokenMock("Uniswap", "UNI");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(linkInstance), address(wethOracleInstance), 8); // Reusing oracle for simplicity
        oracleInstance.setPrimaryOracle(address(linkInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(uniInstance), address(wethOracleInstance), 8); // Reusing oracle for simplicity
        oracleInstance.setPrimaryOracle(address(uniInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(usdcInstance), address(stableOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(usdcInstance), address(stableOracleInstance));
        vm.stopPrank();

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
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

        // Configure USDC as STABLE tier
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            address(stableOracleInstance),
            8, // Oracle decimals
            6, // USDC decimals
            1, // Active
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000e6, // Supply limit
            ILendefiAssets.CollateralTier.STABLE,
            0 // No isolation debt cap
        );

        // Configure LINK as ISOLATED tier
        assetsInstance.updateAssetConfig(
            address(linkInstance),
            address(wethOracleInstance), // Reuse oracle for simplicity
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            700, // 70% borrow threshold
            750, // 75% liquidation threshold
            100_000 ether, // Supply limit
            ILendefiAssets.CollateralTier.ISOLATED,
            10_000e6 // Isolation debt cap
        );

        // Configure UNI as CROSS_B tier
        assetsInstance.updateAssetConfig(
            address(uniInstance),
            address(wethOracleInstance), // Reuse oracle for simplicity
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            750, // 75% borrow threshold
            800, // 80% liquidation threshold
            200_000 ether, // Supply limit
            ILendefiAssets.CollateralTier.CROSS_B,
            0 // No isolation debt cap
        );

        vm.stopPrank();
    }

    function test_getPositionLiquidationFee_InvalidPosition() public {
        // Try to get liquidation fee for a non-existent position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector));
        LendefiInstance.getPositionLiquidationFee(alice, 0);

        // Create a position
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        vm.stopPrank();

        // Now it should work for position 0
        LendefiInstance.getPositionLiquidationFee(alice, 0);

        // But should still fail for position 1 which doesn't exist
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector));
        LendefiInstance.getPositionLiquidationFee(alice, 1);
    }

    function test_getPositionLiquidationFee_NonIsolatedPosition() public {
        // Create a non-isolated position with WETH (CROSS_A tier)
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Add collateral to ensure tier is properly determined
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        wethInstance.deposit{value: 10 ether}();
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, positionId);
        vm.stopPrank();

        // Get the liquidation fee
        uint256 fee = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        console2.log("CROSS_A position liquidation fee:", fee);

        // Verify non-isolated position uses CROSS_A tier fee
        assertEq(fee, CROSS_A_FEE, "Non-isolated position should use CROSS_A tier liquidation fee");
    }

    function test_getPositionLiquidationFee_DifferentTiers() public {
        // Create positions for each tier type
        vm.startPrank(alice);

        // ISOLATED position (LINK)
        LendefiInstance.createPosition(address(linkInstance), true);
        uint256 isolatedPositionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // CROSS_A position (WETH)
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 crossAPositionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // CROSS_B position (UNI)
        LendefiInstance.createPosition(address(uniInstance), false);
        uint256 crossBPositionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // STABLE position (USDC)
        LendefiInstance.createPosition(address(usdcInstance), false);
        uint256 stablePositionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Add collateral to each position to ensure tier is properly determined
        // For ISOLATED position (LINK)
        linkInstance.mint(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(linkInstance).approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(linkInstance), 10 ether, isolatedPositionId);
        vm.stopPrank();

        // For CROSS_A position (WETH)
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        wethInstance.deposit{value: 10 ether}();
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, crossAPositionId);
        vm.stopPrank();

        // For CROSS_B position (UNI)
        uniInstance.mint(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(uniInstance).approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(uniInstance), 10 ether, crossBPositionId);
        vm.stopPrank();

        // For STABLE position (USDC)
        usdcInstance.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 10_000e6);
        LendefiInstance.supplyCollateral(address(usdcInstance), 10_000e6, stablePositionId);
        vm.stopPrank();

        // Get liquidation fees for each position
        uint256 isolatedFee = LendefiInstance.getPositionLiquidationFee(alice, isolatedPositionId);
        uint256 crossBFee = LendefiInstance.getPositionLiquidationFee(alice, crossBPositionId);
        uint256 crossAFee = LendefiInstance.getPositionLiquidationFee(alice, crossAPositionId);
        uint256 stableFee = LendefiInstance.getPositionLiquidationFee(alice, stablePositionId);

        // Log all fees for debugging
        console2.log("ISOLATED tier fee:", isolatedFee);
        console2.log("CROSS_B tier fee:", crossBFee);
        console2.log("CROSS_A tier fee:", crossAFee);
        console2.log("STABLE tier fee:", stableFee);

        // Verify each position returns the correct tier fee
        assertEq(isolatedFee, ISOLATED_FEE, "ISOLATED position fee incorrect");
        assertEq(crossBFee, CROSS_B_FEE, "CROSS_B position fee incorrect");
        assertEq(crossAFee, CROSS_A_FEE, "CROSS_A position fee incorrect");
        assertEq(stableFee, STABLE_FEE, "STABLE position fee incorrect");

        // Verify fee hierarchy: ISOLATED > CROSS_B > CROSS_A > STABLE
        assertTrue(isolatedFee > crossBFee, "ISOLATED fee should be > CROSS_B fee");
        assertTrue(crossBFee > crossAFee, "CROSS_B fee should be > CROSS_A fee");
        assertTrue(crossAFee > stableFee, "CROSS_A fee should be > STABLE fee");
    }

    function test_getPositionLiquidationFee_CompareToAssetInstance() public {
        // Create positions for each tier type
        vm.startPrank(alice);

        // ISOLATED position (LINK)
        LendefiInstance.createPosition(address(linkInstance), true);
        uint256 isolatedPositionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // CROSS_B position (UNI)
        LendefiInstance.createPosition(address(uniInstance), false);
        uint256 crossBPositionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Add collateral to each position to ensure tier is properly determined
        // For ISOLATED position (LINK)
        linkInstance.mint(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(linkInstance).approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(linkInstance), 10 ether, isolatedPositionId);
        vm.stopPrank();

        // For CROSS_B position (UNI)
        uniInstance.mint(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(uniInstance).approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(uniInstance), 10 ether, crossBPositionId);
        vm.stopPrank();

        // Get fees directly from position and from assets instance
        uint256 isolatedPosFee = LendefiInstance.getPositionLiquidationFee(alice, isolatedPositionId);
        uint256 crossBPosFee = LendefiInstance.getPositionLiquidationFee(alice, crossBPositionId);

        uint256 isolatedAssetFee = assetsInstance.getTierLiquidationFee(ILendefiAssets.CollateralTier.ISOLATED);
        uint256 crossBAssetFee = assetsInstance.getTierLiquidationFee(ILendefiAssets.CollateralTier.CROSS_B);

        // Log values
        console2.log("ISOLATED position fee:", isolatedPosFee);
        console2.log("ISOLATED tier fee from assets:", isolatedAssetFee);
        console2.log("CROSS_B position fee:", crossBPosFee);
        console2.log("CROSS_B tier fee from assets:", crossBAssetFee);

        // Verify position fees match the tier fees from assetsInstance
        assertEq(isolatedPosFee, isolatedAssetFee, "ISOLATED position fee should match assets module value");
        assertEq(crossBPosFee, crossBAssetFee, "CROSS_B position fee should match assets module value");
    }

    function test_getPositionLiquidationFee_AfterUpdate() public {
        // Create an isolated position with LINK
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(linkInstance), true);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Add collateral to ensure tier is properly determined
        linkInstance.mint(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(linkInstance).approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(linkInstance), 10 ether, positionId);
        vm.stopPrank();

        // Get initial liquidation fee
        uint256 initialFee = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        console2.log("Initial ISOLATED liquidation fee:", initialFee);

        // Set a new fee for the ISOLATED tier (LOWER THAN 10% MAX)
        uint256 newFee = 0.08e6; // 8% fee (below 10% max)

        // Get current jump rate to preserve it
        uint256 currentJumpRate = assetsInstance.getTierJumpRate(ILendefiAssets.CollateralTier.ISOLATED);

        vm.startPrank(address(timelockInstance));
        assetsInstance.updateTierParameters(
            ILendefiAssets.CollateralTier.ISOLATED,
            currentJumpRate, // Keep current jump rate
            newFee // New liquidation fee (8%)
        );
        vm.stopPrank();

        // Get updated liquidation fee
        uint256 updatedFee = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        console2.log("Updated ISOLATED liquidation fee:", updatedFee);

        // Verify the fee was updated
        assertEq(updatedFee, newFee, "Liquidation fee should be updated to new value");
        assertGt(updatedFee, initialFee, "New fee should be higher than initial fee");
    }

    function test_getPositionLiquidationFee_TierComparison() public {
        // Test with two different assets to verify their tier fees
        vm.startPrank(alice);

        // UNI is CROSS_B tier
        LendefiInstance.createPosition(address(uniInstance), false);
        uint256 crossBPositionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // WETH is CROSS_A tier
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 crossAPositionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Add collateral to each position to ensure tier is correctly identified

        // For UNI (CROSS_B) position
        uniInstance.mint(alice, 10 ether);
        vm.startPrank(alice);
        uniInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(uniInstance), 10 ether, crossBPositionId);
        vm.stopPrank();

        // For WETH (CROSS_A) position
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        wethInstance.deposit{value: 10 ether}();
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, crossAPositionId);
        vm.stopPrank();

        // Debug: Get position tiers directly
        ILendefiAssets.CollateralTier crossBPosTier = LendefiInstance.getPositionTier(alice, crossBPositionId);
        ILendefiAssets.CollateralTier crossAPosTier = LendefiInstance.getPositionTier(alice, crossAPositionId);

        console2.log("Cross B Position Tier:", uint256(crossBPosTier));
        console2.log("Cross A Position Tier:", uint256(crossAPosTier));

        // Get fees
        uint256 crossBFee = LendefiInstance.getPositionLiquidationFee(alice, crossBPositionId);
        uint256 crossAFee = LendefiInstance.getPositionLiquidationFee(alice, crossAPositionId);

        // Log values
        console2.log("CROSS_B tier fee (UNI):", crossBFee);
        console2.log("CROSS_A tier fee (WETH):", crossAFee);

        // Verify CROSS_B has higher liquidation fee than CROSS_A
        assertEq(crossBFee, CROSS_B_FEE, "CROSS_B fee incorrect");
        assertEq(crossAFee, CROSS_A_FEE, "CROSS_A fee incorrect");
        assertGt(crossBFee, crossAFee, "CROSS_B fee should be higher than CROSS_A fee");
    }

    function test_getPositionLiquidationFee_IsolatedPosition() public {
        // Create an isolated position with LINK (ISOLATED tier)
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(linkInstance), true); // Isolated
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        // Add collateral to ensure tier is properly identified
        linkInstance.mint(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(linkInstance).approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(linkInstance), 10 ether, positionId);
        vm.stopPrank();

        // Get the liquidation fee
        uint256 fee = LendefiInstance.getPositionLiquidationFee(alice, positionId);
        console2.log("ISOLATED position liquidation fee:", fee);

        // Get tier fee directly for verification
        uint256 isolatedTierFee = assetsInstance.getTierLiquidationFee(ILendefiAssets.CollateralTier.ISOLATED);
        console2.log("Expected ISOLATED tier fee:", isolatedTierFee);

        // Verify isolated position uses ISOLATED tier fee
        assertEq(fee, ISOLATED_FEE, "ISOLATED position should use ISOLATED tier fee");
        assertEq(isolatedTierFee, ISOLATED_FEE, "ISOLATED tier fee should match expected value");
    }
}
