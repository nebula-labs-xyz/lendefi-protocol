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

contract GetUtilizationTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    LendefiView internal viewInstance;

    // Constants
    uint256 constant WAD = 1e6; // The utilization is in 1e6 precision

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

        // Deploy LendefiView BEFORE adding liquidity
        viewInstance = new LendefiView(
            address(LendefiInstance), address(usdcInstance), address(yieldTokenInstance), address(ecoInstance)
        );

        // Now add liquidity after viewInstance is created
        _addLiquidity(1_000_000e6); // Add 1M USDC liquidity
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18, // Asset decimals
                borrowThreshold: 800, // 80% borrow threshold
                liquidationThreshold: 850, // 85% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether, // Supply limit
                isolationDebtCap: 0, // No isolation debt cap
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

        // Configure USDC as STABLE tier
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6, // USDC has 6 decimals
                borrowThreshold: 900, // 90% borrow threshold
                liquidationThreshold: 950, // 95% liquidation threshold
                maxSupplyThreshold: 1_000_000e6, // Supply limit
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
        // Get the base amount before adding liquidity
        LendefiView.ProtocolSnapshot memory snapshotBefore = viewInstance.getProtocolSnapshot();

        uint256 totalSuppliedLiquidityBefore = snapshotBefore.totalSuppliedLiquidity;

        // Add liquidity
        usdcInstance.mint(guardian, amount);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), amount);
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();

        // Get the base amount after adding liquidity
        LendefiView.ProtocolSnapshot memory snapshotAfter = viewInstance.getProtocolSnapshot();
        uint256 totalSuppliedLiquidityAfter = snapshotAfter.totalSuppliedLiquidity;

        // Verify the totalSuppliedLiquidity increased by the added amount
        assert(totalSuppliedLiquidityAfter == totalSuppliedLiquidityBefore + amount);
    }

    // Helper to create position and borrow
    function _createPositionAndBorrow(address user, uint256 ethAmount, uint256 borrowAmount)
        internal
        returns (uint256)
    {
        // Create position
        vm.startPrank(user);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(user) - 1;
        vm.stopPrank();

        // Supply ETH collateral
        vm.deal(user, ethAmount);
        vm.startPrank(user);
        wethInstance.deposit{value: ethAmount}();
        wethInstance.approve(address(LendefiInstance), ethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), ethAmount, positionId);

        // Borrow USDC
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        return positionId;
    }

    function test_GetUtilization_Initial() public {
        // Initially no borrowing, should be 0
        uint256 utilization = LendefiInstance.getUtilization();

        // Log the values to help debug
        console2.log("Initial totalBorrow:", viewInstance.getProtocolSnapshot().totalBorrow);
        console2.log("Initial totalSuppliedLiquidity:", viewInstance.getProtocolSnapshot().totalSuppliedLiquidity);
        console2.log("Initial utilization:", utilization);

        assertEq(utilization, 0, "Initial utilization should be 0");
    }

    function test_GetUtilization_AfterBorrowing() public {
        // Create position and borrow 200,000 USDC
        _createPositionAndBorrow(alice, 100 ether, 200_000e6);

        // Get protocol state after borrowing
        LendefiView.ProtocolSnapshot memory snapshot = viewInstance.getProtocolSnapshot();
        uint256 utilization = LendefiInstance.getUtilization();

        console2.log("totalBorrow after borrowing:", snapshot.totalBorrow);
        console2.log("totalSuppliedLiquidity after borrowing:", snapshot.totalSuppliedLiquidity);
        console2.log("Actual utilization:", utilization);

        // Expected: (WAD * totalBorrow) / totalSuppliedLiquidity = (10^6 * 200_000e6) / 1_000_000e6 = 0.2 * 10^6
        uint256 expectedUtilization = (WAD * 200_000e6) / 1_000_000e6;
        console2.log("Expected utilization:", expectedUtilization);

        assertEq(utilization, expectedUtilization, "Utilization should be 20% (0.2e6)");
    }

    function test_GetUtilization_MultipleUsers() public {
        // First user borrows 200,000 USDC
        _createPositionAndBorrow(alice, 100 ether, 200_000e6);

        // Second user borrows 300,000 USDC
        _createPositionAndBorrow(bob, 150 ether, 300_000e6);

        // Get protocol state after both borrowings
        LendefiView.ProtocolSnapshot memory snapshot = viewInstance.getProtocolSnapshot();
        uint256 utilization = LendefiInstance.getUtilization();

        console2.log("totalBorrow after multiple borrowings:", snapshot.totalBorrow);
        console2.log("totalSuppliedLiquidity after multiple borrowings:", snapshot.totalSuppliedLiquidity);
        console2.log("Actual utilization:", utilization);

        // Expected: (WAD * totalBorrow) / totalSuppliedLiquidity = (10^6 * 500_000e6) / 1_000_000e6 = 0.5 * 10^6
        uint256 expectedUtilization = (WAD * 500_000e6) / 1_000_000e6;
        console2.log("Expected utilization:", expectedUtilization);

        assertEq(utilization, expectedUtilization, "Utilization should be 50% (0.5e6)");
    }

    function test_GetUtilization_AfterRepayment() public {
        // Create position and borrow 500,000 USDC
        uint256 positionId = _createPositionAndBorrow(alice, 300 ether, 500_000e6);

        // Check utilization before repayment
        uint256 utilizationBefore = LendefiInstance.getUtilization();
        uint256 expectedUtilizationBefore = (WAD * 500_000e6) / 1_000_000e6;

        assertEq(utilizationBefore, expectedUtilizationBefore, "Utilization before repayment should be 50%");

        // Repay 300,000 USDC
        usdcInstance.mint(alice, 300_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 300_000e6);
        LendefiInstance.repay(positionId, 300_000e6);
        vm.stopPrank();

        // Check protocol state after repayment
        LendefiView.ProtocolSnapshot memory snapshot = viewInstance.getProtocolSnapshot();
        uint256 utilizationAfter = LendefiInstance.getUtilization();

        console2.log("totalBorrow after repayment:", snapshot.totalBorrow);
        console2.log("totalSuppliedLiquidity after repayment:", snapshot.totalSuppliedLiquidity);
        console2.log("Actual utilization after repayment:", utilizationAfter);

        // Expected: (WAD * totalBorrow) / totalSuppliedLiquidity = (10^6 * 200_000e6) / 1_000_000e6 = 0.2 * 10^6
        uint256 expectedUtilizationAfter = (WAD * 200_000e6) / 1_000_000e6;
        console2.log("Expected utilization after repayment:", expectedUtilizationAfter);

        assertEq(utilizationAfter, expectedUtilizationAfter, "Utilization after repayment should be 20% (0.2e6)");
    }

    function test_GetUtilization_AfterAddingLiquidity() public {
        // Create position and borrow 500,000 USDC
        _createPositionAndBorrow(alice, 300 ether, 500_000e6);

        // Check utilization before adding liquidity
        uint256 utilizationBefore = LendefiInstance.getUtilization();
        uint256 expectedUtilizationBefore = (WAD * 500_000e6) / 1_000_000e6;

        assertEq(utilizationBefore, expectedUtilizationBefore, "Utilization before adding liquidity should be 50%");

        // Add another 1,000,000 USDC liquidity (total becomes 2M)
        _addLiquidity(1_000_000e6);

        // Check protocol state after adding liquidity
        LendefiView.ProtocolSnapshot memory snapshot = viewInstance.getProtocolSnapshot();
        uint256 utilizationAfter = LendefiInstance.getUtilization();

        console2.log("totalBorrow after adding liquidity:", snapshot.totalBorrow);
        console2.log("totalSuppliedLiquidity after adding liquidity:", snapshot.totalSuppliedLiquidity);
        console2.log("Actual utilization after adding liquidity:", utilizationAfter);

        // Expected: (WAD * totalBorrow) / totalSuppliedLiquidity = (10^6 * 500_000e6) / 2_000_000e6 = 0.25 * 10^6
        uint256 expectedUtilizationAfter = (WAD * 500_000e6) / 2_000_000e6;
        console2.log("Expected utilization after adding liquidity:", expectedUtilizationAfter);

        assertEq(
            utilizationAfter, expectedUtilizationAfter, "Utilization after adding liquidity should be 25% (0.25e6)"
        );
    }

    function test_GetUtilization_MaxUtilization() public {
        // Create position with large collateral to enable borrowing the full amount
        _createPositionAndBorrow(alice, 1000 ether, 950_000e6); // Borrowing slightly less than total to avoid rounding issues

        // Check protocol state at near-max utilization
        LendefiView.ProtocolSnapshot memory snapshot = viewInstance.getProtocolSnapshot();
        uint256 utilization = LendefiInstance.getUtilization();

        console2.log("totalBorrow at near-max:", snapshot.totalBorrow);
        console2.log("totalSuppliedLiquidity at near-max:", snapshot.totalSuppliedLiquidity);
        console2.log("Actual near-max utilization:", utilization);

        // Expected: (WAD * totalBorrow) / totalSuppliedLiquidity should be close to 95% (0.95e6)
        uint256 expectedUtilization = (WAD * 950_000e6) / 1_000_000e6;
        console2.log("Expected near-max utilization:", expectedUtilization);

        assertEq(utilization, expectedUtilization, "Utilization should be close to 95% (0.95e6)");
    }
}
