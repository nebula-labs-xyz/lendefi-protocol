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

contract GetSupplyRateTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    LendefiView internal viewInstance;

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

        // Deploy LendefiView
        viewInstance = new LendefiView(
            address(LendefiInstance), address(usdcInstance), address(yieldTokenInstance), address(ecoInstance)
        );
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier - Updated to new struct-based approach
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18, // WETH decimals
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

        // Configure USDC as STABLE tier - Updated to new struct-based approach
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
        usdcInstance.mint(guardian, amount);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), amount);
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();

        // Verify liquidity was added
        uint256 baseAfter = viewInstance.getProtocolSnapshot().totalSuppliedLiquidity; // Changed to viewInstance
        assertGe(baseAfter, amount, "Total base should increase after adding liquidity");
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

        // Borrow USDC if amount > 0
        if (borrowAmount > 0) {
            LendefiInstance.borrow(positionId, borrowAmount);
        }
        vm.stopPrank();

        return positionId;
    }

    // Helper to simulate protocol profits (payments from borrowers, fees, etc.)
    function _simulateProtocolProfits(uint256 amount) internal {
        // Mint USDC and send it directly to protocol to simulate profits
        usdcInstance.mint(address(this), amount);
        usdcInstance.approve(address(LendefiInstance), amount);
        usdcInstance.transfer(address(LendefiInstance), amount);

        // Log protocol state after simulating profits
        LendefiView.ProtocolSnapshot memory snapshot = viewInstance.getProtocolSnapshot(); // Changed to viewInstance
        console2.log("Protocol USDC balance after profit simulation:", usdcInstance.balanceOf(address(LendefiInstance)));
        console2.log("Total base:", snapshot.totalSuppliedLiquidity);
        console2.log("Total borrow:", snapshot.totalBorrow);
    }

    function test_GetSupplyRate_Initial() public {
        // Initially no deposits or borrowing, should be 0
        uint256 supplyRate = LendefiInstance.getSupplyRate();

        // Get state using viewInstance
        LendefiView.ProtocolSnapshot memory snapshot = viewInstance.getProtocolSnapshot(); // Changed to viewInstance
        console2.log("Initial totalSuppliedLiquidity:", snapshot.totalSuppliedLiquidity);
        console2.log("Initial totalBorrow:", snapshot.totalBorrow);
        console2.log("Initial supply rate:", supplyRate);

        assertEq(supplyRate, 0, "Initial supply rate should be 0");
    }

    function test_GetSupplyRate_AfterAddingLiquidity() public {
        // Add liquidity
        uint256 liquidityAmount = 1_000_000e6; // 1M USDC
        _addLiquidity(liquidityAmount);

        // Check supply rate after adding liquidity
        uint256 supplyRate = LendefiInstance.getSupplyRate();

        // Get protocol state for debugging
        LendefiView.ProtocolSnapshot memory snapshot = viewInstance.getProtocolSnapshot(); // Changed to viewInstance
        console2.log("totalSuppliedLiquidity after adding liquidity:", snapshot.totalSuppliedLiquidity);
        console2.log("totalBorrow after adding liquidity:", snapshot.totalBorrow);
        console2.log("totalSupply:", yieldTokenInstance.totalSupply());
        console2.log("Supply rate after adding liquidity:", supplyRate);

        // With no borrowing or profits, supply rate should still be 0
        assertEq(supplyRate, 0, "Supply rate after adding liquidity should be 0 with no borrowing");
    }

    function test_GetSupplyRate_WithProtocolProfits() public {
        // Add liquidity first
        uint256 liquidityAmount = 1_000_000e6; // 1M USDC
        _addLiquidity(liquidityAmount);

        // Check initial supply rate (should be 0)
        uint256 initialSupplyRate = LendefiInstance.getSupplyRate();
        console2.log("Initial supply rate (before profits):", initialSupplyRate);

        // Simulate protocol profits - sending 50,000 USDC to protocol (simulating interest payments)
        _simulateProtocolProfits(50_000e6);

        // Get supply rate after profits
        uint256 supplyRateAfterProfits = LendefiInstance.getSupplyRate();
        console2.log("Supply rate after profits:", supplyRateAfterProfits);

        // Supply rate should be positive now
        assertGt(supplyRateAfterProfits, 0, "Supply rate should increase after protocol profits");
    }

    function test_GetSupplyRate_WithBorrowingAndProfits() public {
        // Add liquidity first
        uint256 liquidityAmount = 1_000_000e6; // 1M USDC
        _addLiquidity(liquidityAmount);

        // Create position and borrow
        uint256 borrowAmount = 500_000e6; // 500k USDC (50% utilization)
        _createPositionAndBorrow(alice, 300 ether, borrowAmount);

        // Check supply rate after borrowing (no profits yet, should be 0)
        uint256 supplyRateAfterBorrow = LendefiInstance.getSupplyRate();
        console2.log("Supply rate after borrowing (no profits):", supplyRateAfterBorrow);

        // Simulate interest payments - 5% of borrow amount as profit
        _simulateProtocolProfits(borrowAmount * 5 / 100);

        // Get supply rate after profits
        uint256 supplyRateAfterProfits = LendefiInstance.getSupplyRate();
        console2.log("Supply rate after profits with borrowing:", supplyRateAfterProfits);

        // Supply rate should be positive now
        assertGt(supplyRateAfterProfits, 0, "Supply rate should increase after profits with borrowing");
    }

    function test_GetSupplyRate_IncreasingProfits() public {
        // Add liquidity first
        uint256 liquidityAmount = 1_000_000e6; // 1M USDC
        _addLiquidity(liquidityAmount);

        // Create position and borrow
        _createPositionAndBorrow(alice, 300 ether, 500_000e6);

        // Simulate small profits
        _simulateProtocolProfits(10_000e6);
        uint256 supplyRateWithSmallProfits = LendefiInstance.getSupplyRate();
        console2.log("Supply rate with small profits:", supplyRateWithSmallProfits);

        // Simulate larger profits
        _simulateProtocolProfits(40_000e6);
        uint256 supplyRateWithMoreProfits = LendefiInstance.getSupplyRate();
        console2.log("Supply rate with more profits:", supplyRateWithMoreProfits);

        // Supply rate should increase with more profits
        assertGt(supplyRateWithMoreProfits, supplyRateWithSmallProfits, "Supply rate should increase with more profits");
    }

    function test_GetSupplyRate_WithDifferentBaseProfitTargets() public {
        // Add liquidity first
        uint256 liquidityAmount = 1_000_000e6; // 1M USDC
        _addLiquidity(liquidityAmount);

        // Create position and borrow
        _createPositionAndBorrow(alice, 300 ether, 500_000e6);

        // Simulate profits
        _simulateProtocolProfits(50_000e6);

        // Get initial supply rate
        uint256 initialSupplyRate = LendefiInstance.getSupplyRate();
        uint256 initialBaseProfitTarget = viewInstance.getProtocolSnapshot().baseProfitTarget;

        console2.log("Initial base profit target:", initialBaseProfitTarget);
        console2.log("Initial supply rate with profits:", initialSupplyRate);

        // Let's debug the current permissions
        bytes32 MANAGER_ROLE = keccak256("MANAGER_ROLE");
        console2.log("Current timelock address:", address(timelockInstance));
        console2.log("Timelock has manager role:", LendefiInstance.hasRole(MANAGER_ROLE, address(timelockInstance)));

        // Start a prank properly as timelock
        vm.startPrank(address(timelockInstance));

        // Get current config
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // Update base profit target (keep other parameters unchanged)
        config.profitTargetRate = initialBaseProfitTarget * 2; // double the base profit target

        // Apply updated config
        LendefiInstance.loadProtocolConfig(config);

        // End the prank
        vm.stopPrank();

        // Get new supply rate
        uint256 newSupplyRate = LendefiInstance.getSupplyRate();
        uint256 newBaseProfitTarget = viewInstance.getProtocolSnapshot().baseProfitTarget;

        console2.log("New base profit target:", newBaseProfitTarget);
        console2.log("New supply rate with increased profit target:", newSupplyRate);

        // Higher profit target typically means lower supply rate (more profit to protocol)
        assertLt(newSupplyRate, initialSupplyRate, "Supply rate should decrease with higher profit target");
    }

    function test_GetSupplyRate_AfterWithdrawal() public {
        // Add liquidity first
        uint256 liquidityAmount = 1_000_000e6; // 1M USDC
        _addLiquidity(liquidityAmount);

        // Create position and borrow
        _createPositionAndBorrow(alice, 300 ether, 500_000e6);

        // Simulate profits
        _simulateProtocolProfits(50_000e6);

        // Get initial supply rate
        uint256 initialSupplyRate = LendefiInstance.getSupplyRate();
        console2.log("Initial supply rate with profits:", initialSupplyRate);

        // Have guardian withdraw some liquidity
        uint256 guardianBalance = yieldTokenInstance.balanceOf(guardian);
        uint256 withdrawAmount = guardianBalance / 2; // Withdraw half of LP tokens

        vm.startPrank(guardian);
        LendefiInstance.exchange(withdrawAmount);
        vm.stopPrank();

        // Get new supply rate after withdrawal
        uint256 supplyRateAfterWithdrawal = LendefiInstance.getSupplyRate();
        console2.log("Supply rate after withdrawal:", supplyRateAfterWithdrawal);

        // When liquidity is withdrawn, supply rate typically increases for remaining LPs
        // because the same profit is distributed among fewer LP tokens
        assertGt(supplyRateAfterWithdrawal, initialSupplyRate, "Supply rate should increase after liquidity withdrawal");
    }
}
