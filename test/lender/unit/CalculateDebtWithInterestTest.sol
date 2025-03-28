// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {RWAPriceConsumerV3} from "../../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";
import {MockRWA} from "../../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {LendefiRates} from "../../../contracts/lender/lib/LendefiRates.sol";

contract CalculateDebtWithInterestTest is BasicDeploy {
    MockRWA internal rwaToken;

    RWAPriceConsumerV3 internal rwaassetsInstance;
    WETHPriceConsumerV3 internal wethassetsInstance;
    StablePriceConsumerV3 internal stableassetsInstance;

    function setUp() public {
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);
        // Deploy mock tokens

        wethInstance = new WETH9();
        rwaToken = new MockRWA("Ondo Finance", "ONDO");

        // Deploy oracles
        wethassetsInstance = new WETHPriceConsumerV3();
        rwaassetsInstance = new RWAPriceConsumerV3();
        stableassetsInstance = new StablePriceConsumerV3();

        // Set prices
        wethassetsInstance.setPrice(2500e8); // $2500 per ETH
        rwaassetsInstance.setPrice(1000e8); // $1000 per RWA token
        stableassetsInstance.setPrice(1e8); // $1 per stable token

        // Setup roles
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
        _setupLiquidity();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800, // 80% borrow threshold
                liquidationThreshold: 850, // 85% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0, // no isolation debt cap
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethassetsInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure RWA token as ISOLATED tier
        assetsInstance.updateAssetConfig(
            address(rwaToken),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 650, // 65% borrow threshold
                liquidationThreshold: 750, // 75% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 100_000e6, // Isolation debt cap of 100,000 USDC
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.ISOLATED,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(rwaassetsInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure stable token as STABLE tier
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6, // USDC has 6 decimals
                borrowThreshold: 900, // 90% borrow threshold
                liquidationThreshold: 950, // 95% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(stableassetsInstance), active: 1}),
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
        // Add liquidity to the protocol to enable borrowing
        usdcInstance.mint(guardian, 1_000_000e6);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    // Helper function to create position
    function _createPosition(address user, address asset, bool isIsolated) internal returns (uint256) {
        vm.prank(user);
        LendefiInstance.createPosition(asset, isIsolated);
        return LendefiInstance.getUserPositionsCount(user) - 1;
    }

    // Helper to mint and supply collateral
    function _mintAndSupplyCollateral(address user, address asset, uint256 amount, uint256 positionId) internal {
        // Mint tokens to user
        if (asset == address(wethInstance)) {
            vm.deal(user, amount);
            vm.prank(user);
            wethInstance.deposit{value: amount}();
        } else if (asset == address(rwaToken)) {
            rwaToken.mint(user, amount);
        } else if (asset == address(usdcInstance)) {
            usdcInstance.mint(user, amount);
        }

        // Supply collateral
        vm.startPrank(user);
        IERC20(asset).approve(address(LendefiInstance), amount);
        LendefiInstance.supplyCollateral(asset, amount, positionId);
        vm.stopPrank();
    }

    // Helper to borrow
    function _borrowFromPosition(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        LendefiInstance.borrow(positionId, amount);
        vm.stopPrank();
    }

    // Test 1: Zero debt returns zero
    function test_ZeroDebtReturnsZero() public {
        // Create a position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply collateral but don't borrow
        _mintAndSupplyCollateral(alice, address(wethInstance), 10 ether, positionId);

        // Check that debt with interest is zero
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        assertEq(debtWithInterest, 0, "Zero debt should return zero interest");
    }

    // Test 2: Interest calculation for isolated position
    function test_IsolatedPositionInterestCalculation() public {
        // Create isolated position
        uint256 positionId = _createPosition(alice, address(rwaToken), true);

        // Supply collateral and borrow
        _mintAndSupplyCollateral(alice, address(rwaToken), 100 ether, positionId);
        uint256 borrowAmount = 10_000e6; // 10,000 USDC
        _borrowFromPosition(alice, positionId, borrowAmount);

        // Get initial debt - UPDATED: use getUserPosition().debtAmount instead of getPositionDebt
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        uint256 initialDebt = position.debtAmount;
        assertEq(initialDebt, borrowAmount, "Initial debt should match borrowed amount");

        // Move forward in time (30 days)
        vm.warp(block.timestamp + 30 days);

        // Check that debt has increased due to interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        assertTrue(debtWithInterest > borrowAmount, "Debt should increase due to interest");

        // Get isolated tier rate for verification - UPDATED: using IASSETS.CollateralTier
        uint256 isolatedRate = LendefiInstance.getBorrowRate(IASSETS.CollateralTier.ISOLATED);

        // Calculate expected interest manually using LendefiRates
        uint256 timeElapsed = 30 days;
        // UPDATED: Calculate directly with LendefiRates library
        uint256 expectedDebt = LendefiRates.calculateDebtWithInterest(borrowAmount, isolatedRate, timeElapsed);

        // Allow small deviation (1 wei) due to potential rounding differences
        uint256 deviation =
            debtWithInterest > expectedDebt ? debtWithInterest - expectedDebt : expectedDebt - debtWithInterest;

        assertLe(deviation, 1, "Interest calculation should match expected value");
    }

    function test_CrossPositionInterestCalculation() public {
        // Create cross-collateral position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply collateral and borrow
        _mintAndSupplyCollateral(alice, address(wethInstance), 10 ether, positionId);
        uint256 borrowAmount = 10_000e6; // 10,000 USDC
        _borrowFromPosition(alice, positionId, borrowAmount);

        // Move forward in time (90 days)
        vm.warp(block.timestamp + 180 days);

        // Get position data
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);

        // Get highest tier from collateral assets - UPDATED: use LendefiRates library via the contract
        IASSETS.CollateralTier tier = LendefiInstance.getPositionTier(alice, positionId);

        uint256 actualTierRate = LendefiInstance.getBorrowRate(tier);

        console2.log("Highest tier detected:", uint256(tier));
        console2.log("CROSS_A tier value:", uint256(IASSETS.CollateralTier.CROSS_A));

        // Calculate using the same tier determined by the contract
        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;
        // UPDATED: Calculate directly with LendefiRates library
        uint256 expectedDebt = LendefiRates.calculateDebtWithInterest(position.debtAmount, actualTierRate, timeElapsed);

        // Check debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);

        uint256 deviation =
            debtWithInterest > expectedDebt ? debtWithInterest - expectedDebt : expectedDebt - debtWithInterest;

        // Debug logging
        console2.log("Position debt amount:", position.debtAmount / 1e6);
        console2.log("Expected debt:", expectedDebt / 1e6);
        console2.log("Actual debt with interest:", debtWithInterest / 1e6);
        console2.log("Deviation:", deviation);

        // The deviation should now be zero or very small
        assertEq(deviation, 0, "Interest calculation should match exactly");
    }

    function test_MultiTierPositionInterestCalculation() public {
        // Create cross-collateral position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply WETH (CROSS_A tier)
        _mintAndSupplyCollateral(alice, address(wethInstance), 10 ether, positionId);

        // Add STABLE tier collateral to the same position
        _mintAndSupplyCollateral(alice, address(usdcInstance), 10_000e6, positionId);

        uint256 borrowAmount = 15_000e6; // 15,000 USDC
        _borrowFromPosition(alice, positionId, borrowAmount);

        // Move forward in time (180 days), 90 days beyond the setUp warp
        vm.warp(block.timestamp + 180 days);

        // Get position data first - this is crucial
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);

        // Check debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);

        // The highest tier should be CROSS_A (not STABLE)
        // This is because numerically CROSS_A (1) > STABLE (0)
        // UPDATED: Get highest tier using LendefiRates
        IASSETS.CollateralTier tier = LendefiInstance.getPositionTier(alice, positionId);

        // Debug information
        console2.log("Highest tier value:", uint256(tier));
        console2.log("STABLE tier value:", uint256(IASSETS.CollateralTier.STABLE));
        console2.log("CROSS_A tier value:", uint256(IASSETS.CollateralTier.CROSS_A));

        assertEq(
            uint256(tier),
            uint256(IASSETS.CollateralTier.CROSS_A),
            "Highest tier should be CROSS_A (numerically higher than STABLE)"
        );

        // Get CROSS_A tier rate (not STABLE)
        uint256 crossATierRate = LendefiInstance.getBorrowRate(tier);

        // Calculate expected debt with EXACT same values used in contract
        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;
        // UPDATED: Calculate directly with LendefiRates library
        uint256 expectedDebt = LendefiRates.calculateDebtWithInterest(position.debtAmount, crossATierRate, timeElapsed);

        // Verify interest calculation
        uint256 deviation =
            debtWithInterest > expectedDebt ? debtWithInterest - expectedDebt : expectedDebt - debtWithInterest;

        // Add debug logs
        console2.log("Position debt amount:", position.debtAmount / 1e6);
        console2.log("Time elapsed (days):", timeElapsed / 1 days);
        console2.log("Expected debt:", expectedDebt / 1e6);
        console2.log("Actual debt with interest:", debtWithInterest / 1e6);
        console2.log("Deviation:", deviation);

        assertLe(deviation, 1, "Multi-tier interest calculation should use highest tier rate");
    }

    function test_LongTermInterestCalculation() public {
        // Create position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply collateral and borrow
        _mintAndSupplyCollateral(alice, address(wethInstance), 20 ether, positionId);
        uint256 borrowAmount = 5_000e6; // 5,000 USDC
        _borrowFromPosition(alice, positionId, borrowAmount);

        // Move forward 1 year
        vm.warp(block.timestamp + 365 days);

        // Check debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);

        // Get rate - UPDATED: using IASSETS.CollateralTier
        uint256 tierRate = LendefiInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_A);

        // For a full year, interest should be approximately borrowAmount * rate
        uint256 expectedInterest = (borrowAmount * tierRate) / 1e6;
        uint256 expectedDebt = borrowAmount + expectedInterest;

        // Use a slightly larger tolerance for longer periods due to compounding effects
        uint256 tolerance = (expectedDebt * 1) / 100; // 1% tolerance

        assertTrue(
            debtWithInterest >= expectedDebt - tolerance && debtWithInterest <= expectedDebt + tolerance,
            "Long-term interest calculation should be approximately correct"
        );
    }

    function test_InvalidPositionReverts() public {
        // Try to calculate debt for a position that doesn't exist
        // UPDATED: use specific error code "IN" for invalid position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector));
        LendefiInstance.calculateDebtWithInterest(alice, 999);
    }
}
