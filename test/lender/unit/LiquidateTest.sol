// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {ILendefiAssets} from "../../../contracts/interfaces/ILendefiAssets.sol";

contract LiquidateTest is BasicDeploy {
    // Events to verify
    event Liquidated(address indexed user, uint256 indexed positionId, uint256 debtAmount);
    event WithdrawCollateral(address indexed user, uint256 indexed positionId, address indexed asset, uint256 amount);

    MockRWA internal rwaToken;
    MockRWA internal stableToken;
    MockRWA internal crossBToken;

    RWAPriceConsumerV3 internal rwaOracleInstance;
    RWAPriceConsumerV3 internal stableOracleInstance;
    RWAPriceConsumerV3 internal crossBOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();
        rwaToken = new MockRWA("Ondo Finance", "ONDO");
        stableToken = new MockRWA("USDT", "USDT");
        crossBToken = new MockRWA("Cross B Token", "CROSSB");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();
        stableOracleInstance = new RWAPriceConsumerV3();
        crossBOracleInstance = new RWAPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token
        stableOracleInstance.setPrice(1e8); // $1 per USDT
        crossBOracleInstance.setPrice(500e8); // $500 per CROSSB token

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(rwaToken), address(rwaOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(rwaToken), address(rwaOracleInstance));

        oracleInstance.addOracle(address(stableToken), address(stableOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(stableToken), address(stableOracleInstance));

        oracleInstance.addOracle(address(crossBToken), address(crossBOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(crossBToken), address(crossBOracleInstance));
        vm.stopPrank();

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
        _setupLiquidity();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8,
            18,
            1,
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether,
            ILendefiAssets.CollateralTier.CROSS_A,
            0
        );

        // Configure RWA token as ISOLATED tier
        assetsInstance.updateAssetConfig(
            address(rwaToken),
            address(rwaOracleInstance),
            8,
            18,
            1,
            650, // 65% borrow threshold
            750, // 75% liquidation threshold
            1_000_000 ether,
            ILendefiAssets.CollateralTier.ISOLATED,
            100_000e6 // Isolation debt cap of 100,000 USDC
        );

        // Configure USDT as STABLE tier
        assetsInstance.updateAssetConfig(
            address(stableToken),
            address(stableOracleInstance),
            8,
            18,
            1,
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000 ether,
            ILendefiAssets.CollateralTier.STABLE,
            0
        );

        // Configure Cross B token
        assetsInstance.updateAssetConfig(
            address(crossBToken),
            address(crossBOracleInstance),
            8,
            18,
            1,
            700, // 70% borrow threshold
            800, // 80% liquidation threshold
            1_000_000 ether,
            ILendefiAssets.CollateralTier.CROSS_B,
            0
        );

        vm.stopPrank();
    }

    function _setupLiquidity() internal {
        // Provide liquidity to the protocol
        usdcInstance.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    function _createPosition(address user, address asset, bool isIsolated) internal returns (uint256) {
        vm.startPrank(user);
        LendefiInstance.createPosition(asset, isIsolated);
        uint256 positionId = LendefiInstance.getUserPositionsCount(user) - 1;
        vm.stopPrank();
        return positionId;
    }

    function _mintTokens(address user, address token, uint256 amount) internal {
        if (token == address(wethInstance)) {
            vm.deal(user, amount);
            vm.prank(user);
            wethInstance.deposit{value: amount}();
        } else {
            MockRWA(token).mint(user, amount);
        }
    }

    // Helper to setup a liquidatable position
    function _setupLiquidatablePosition(address user, address asset, bool isIsolated) internal returns (uint256) {
        // Create position
        uint256 positionId = _createPosition(user, asset, isIsolated);

        // Supply collateral
        uint256 collateralAmount = 10 ether;
        _mintTokens(user, asset, collateralAmount);

        vm.startPrank(user);
        IERC20(asset).approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(asset, collateralAmount, positionId);

        // Borrow max amount
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(user, positionId);
        LendefiInstance.borrow(positionId, creditLimit);
        vm.stopPrank();

        // Drop price to make position liquidatable
        if (asset == address(wethInstance)) {
            wethOracleInstance.setPrice(2500e8 * 84 / 100); // Drop from $2500 to $2120
        } else if (asset == address(rwaToken)) {
            rwaOracleInstance.setPrice(1000e8 * 74 / 100); // Drop from $1000 to $740
        } else if (asset == address(stableToken)) {
            stableOracleInstance.setPrice(1e8 * 945 / 1000); // Drop from $1 to $0.945
        } else if (asset == address(crossBToken)) {
            crossBOracleInstance.setPrice(500e8 * 79 / 100); // Drop from $500 to $399
        }

        return positionId;
    }

    // Test successful liquidation of non-isolated position
    function test_SuccessfulLiquidation() public {
        // Setup a liquidatable position for Bob
        uint256 positionId = _setupLiquidatablePosition(bob, address(wethInstance), false);

        // Setup Charlie as liquidator
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), charlie, 50_000 ether); // Give enough gov tokens

        // Get the debt amount before liquidation
        uint256 debtAmount = LendefiInstance.calculateDebtWithInterest(bob, positionId);

        // Approve USDC for liquidation with buffer
        vm.startPrank(charlie);
        usdcInstance.mint(charlie, debtAmount * 2); // Give enough USDC
        usdcInstance.approve(address(LendefiInstance), debtAmount * 2);

        // Perform liquidation
        LendefiInstance.liquidate(bob, positionId);
        vm.stopPrank();

        // Verify position state
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(position.debtAmount, 0, "Debt should be cleared");

        // Verify collateral transfer
        uint256 charlieWethBalance = wethInstance.balanceOf(charlie);
        assertEq(charlieWethBalance, 10 ether, "Liquidator should receive all collateral");
    }

    // Test liquidation of isolated position
    function test_LiquidationOfIsolatedPosition() public {
        // Setup a liquidatable isolated position for Bob
        uint256 positionId = _setupLiquidatablePosition(bob, address(rwaToken), true);

        // Setup Charlie as liquidator
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), charlie, 50_000 ether); // Give enough gov tokens
        usdcInstance.mint(charlie, 100_000e6); // Give enough USDC

        // Get the debt amount before liquidation
        uint256 debtAmount = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        uint256 liquidationBonus = LendefiInstance.getPositionLiquidationFee(bob, positionId);
        uint256 totalDebt = debtAmount + (debtAmount * liquidationBonus / 1e18);

        // Add a 15% buffer to account for isolated asset higher liquidation bonus
        uint256 bufferedAmount = totalDebt + (totalDebt * 15 / 100);

        vm.startPrank(charlie);
        usdcInstance.approve(address(LendefiInstance), bufferedAmount);

        // Perform liquidation
        LendefiInstance.liquidate(bob, positionId);
        vm.stopPrank();

        // Verify position state
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(position.debtAmount, 0, "Debt should be cleared");

        // Verify collateral transfer
        uint256 charlieRwaBalance = rwaToken.balanceOf(charlie);
        assertEq(charlieRwaBalance, 10 ether, "Liquidator should receive all collateral");
    }

    // Test liquidation with insufficient governance tokens
    function test_LiquidationWithInsufficientGovTokens() public {
        // Setup a liquidatable position
        uint256 positionId = _setupLiquidatablePosition(bob, address(wethInstance), false);

        // Charlie has no governance tokens
        usdcInstance.mint(charlie, 100_000e6);

        vm.startPrank(charlie);
        usdcInstance.approve(address(LendefiInstance), 100_000e6);

        // Attempt liquidation without enough governance tokens
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.NotEnoughGovernanceTokens.selector));
        LendefiInstance.liquidate(bob, positionId);
        vm.stopPrank();
    }

    // Test liquidation of non-liquidatable position
    function test_LiquidationOfNonLiquidatablePosition() public {
        // Create a healthy position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Supply collateral but don't borrow
        vm.deal(bob, 10 ether);
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, positionId);
        vm.stopPrank();

        // Setup Charlie as liquidator
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), charlie, 50_000 ether);

        vm.startPrank(charlie);

        // Attempt to liquidate a healthy position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.NotLiquidatable.selector));
        LendefiInstance.liquidate(bob, positionId);
        vm.stopPrank();
    }

    // Test liquidation of invalid position
    function test_LiquidationOfInvalidPosition() public {
        // No positions created

        // Setup Charlie as liquidator
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), charlie, 50_000 ether);

        vm.startPrank(charlie);

        // Attempt to liquidate nonexistent position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector));
        LendefiInstance.liquidate(bob, 0);
        vm.stopPrank();
    }

    // Test for liquidation when protocol is paused
    function test_LiquidationWhenPaused() public {
        // Setup a liquidatable position
        uint256 positionId = _setupLiquidatablePosition(bob, address(wethInstance), false);

        // Setup Charlie as liquidator
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), charlie, 50_000 ether);
        usdcInstance.mint(charlie, 100_000e6);

        // Pause the protocol
        vm.prank(guardian);
        LendefiInstance.pause();

        vm.startPrank(charlie);
        usdcInstance.approve(address(LendefiInstance), 100_000e6);

        // Attempt liquidation when paused
        bytes memory expError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expError);
        LendefiInstance.liquidate(bob, positionId);
        vm.stopPrank();
    }

    // Test liquidation with insufficient USDC
    function test_LiquidationWithInsufficientUSDC() public {
        // Setup a liquidatable position
        uint256 positionId = _setupLiquidatablePosition(bob, address(wethInstance), false);

        // Setup Charlie with gov tokens but insufficient USDC
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), charlie, 50_000 ether);
        usdcInstance.mint(charlie, 1e6); // Only $1 USDC

        vm.startPrank(charlie);
        usdcInstance.approve(address(LendefiInstance), 1e6);

        // Attempt liquidation without enough USDC
        vm.expectRevert();
        LendefiInstance.liquidate(bob, positionId);
        vm.stopPrank();
    }

    // Test liquidation of a position with multiple collateral assets
    function test_LiquidationWithMultipleCollateralAssets() public {
        // Only create a cross-collateral position (not isolated)
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Set up collateral amounts
        uint256 wethAmount = 5 ether;
        uint256 crossBAmount = 10 ether;

        // Supply collateral
        _supplyMultipleCollateral(bob, positionId, wethAmount, crossBAmount);

        // Drop prices to make position liquidatable
        wethOracleInstance.setPrice(2500e8 * 84 / 100); // 84% of $2500
        crossBOracleInstance.setPrice(500e8 * 80 / 100); // 80% of $500

        // Set up liquidator and perform liquidation
        _setupLiquidatorAndExecute(bob, positionId, charlie);

        // Verify results
        _verifyLiquidationResults(bob, positionId, charlie, wethAmount, crossBAmount);
    }

    // Helper functions to reduce stack depth
    function _supplyMultipleCollateral(address user, uint256 positionId, uint256 wethAmount, uint256 crossBAmount)
        internal
    {
        _mintTokens(user, address(wethInstance), wethAmount);
        _mintTokens(user, address(crossBToken), crossBAmount);

        vm.startPrank(user);

        wethInstance.approve(address(LendefiInstance), wethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), wethAmount, positionId);

        crossBToken.approve(address(LendefiInstance), crossBAmount);
        LendefiInstance.supplyCollateral(address(crossBToken), crossBAmount, positionId);

        // Borrow to make position liquidatable later
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(user, positionId);
        LendefiInstance.borrow(positionId, creditLimit);

        vm.stopPrank();
    }

    function _setupLiquidatorAndExecute(address user, uint256 positionId, address liquidator_) internal {
        // Setup liquidator
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), liquidator_, 50_000 ether);
        usdcInstance.mint(liquidator_, 200_000e6);

        // Calculate debt and approve with buffer
        uint256 debtAmount = LendefiInstance.calculateDebtWithInterest(user, positionId);
        vm.startPrank(liquidator_);
        usdcInstance.approve(address(LendefiInstance), debtAmount * 2);
        // Perform liquidation
        LendefiInstance.liquidate(user, positionId);
        vm.stopPrank();
    }

    function _verifyLiquidationResults(
        address user,
        uint256 positionId,
        address liquidator,
        uint256 wethAmount,
        uint256 crossBAmount
    ) internal {
        // Verify collateral transfer
        assertEq(wethInstance.balanceOf(liquidator), wethAmount, "Liquidator should receive all WETH");
        assertEq(crossBToken.balanceOf(liquidator), crossBAmount, "Liquidator should receive all CrossB");

        // Verify position state
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(user, positionId);
        assertEq(position.debtAmount, 0, "Debt should be cleared");

        // Verify collateral amounts cleared
        assertEq(
            LendefiInstance.getCollateralAmount(user, positionId, address(wethInstance)),
            0,
            "WETH collateral should be cleared"
        );
        assertEq(
            LendefiInstance.getCollateralAmount(user, positionId, address(crossBToken)),
            0,
            "CrossB collateral should be cleared"
        );

        // Verify position assets array cleared
        assertEq(
            LendefiInstance.getPositionCollateralAssets(user, positionId).length,
            0,
            "Position assets array should be empty"
        );
    }

    // Fuzz test for liquidating positions with different debt amounts
    function testFuzz_LiquidationWithVaryingDebt(uint256 borrowPercent, uint256 priceDropPercent) public {
        // Bound to reasonable percentage (10-90%)
        borrowPercent = bound(borrowPercent, 10, 99);
        // FIX: Use priceDropPercent instead of borrowPercent in the bound function
        priceDropPercent = bound(priceDropPercent, 83, 99);

        // Create position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Supply collateral
        uint256 collateralAmount = 10 ether;
        _mintTokens(bob, address(wethInstance), collateralAmount);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow percentage of max
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);
        uint256 borrowAmount = (creditLimit * borrowPercent) / 100;
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Drop price to make position liquidatable
        wethOracleInstance.setPrice(int256(2500e8 * priceDropPercent / 100)); // Drop from $2500 to percentage of original price

        // Setup Charlie as liquidator
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), charlie, 50_000 ether);
        usdcInstance.mint(charlie, borrowAmount * 2); // Give enough USDC

        vm.startPrank(charlie);
        usdcInstance.approve(address(LendefiInstance), borrowAmount * 2);

        // Check if position is liquidatable
        bool isLiquidatable = LendefiInstance.isLiquidatable(bob, positionId);

        if (isLiquidatable) {
            // Perform liquidation
            LendefiInstance.liquidate(bob, positionId);

            // Verify position was liquidated
            IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
            assertEq(position.debtAmount, 0, "Debt should be cleared after liquidation");

            uint256 charlieWethBalance = wethInstance.balanceOf(charlie);
            assertEq(charlieWethBalance, collateralAmount, "Liquidator should receive all collateral");
        } else {
            // Attempt liquidation of non-liquidatable position should revert
            vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.NotLiquidatable.selector));
            LendefiInstance.liquidate(bob, positionId);
        }
        vm.stopPrank();
    }

    function test_LiquidationWithMaximumAssets() public {
        // Setup liquidator first
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), charlie, 50_000 ether);
        usdcInstance.mint(charlie, 1_000_000e6); // Give plenty of USDC

        // Create a position for Bob
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Create 20 different mock assets
        MockRWA[] memory mockAssets = new MockRWA[](20);
        address[] memory assetAddresses = new address[](20);

        // Deploy and configure 20 unique mock tokens
        vm.startPrank(address(timelockInstance));
        for (uint256 i = 0; i < 20; i++) {
            // Create a new mock token with unique name
            string memory name = string(abi.encodePacked("Asset", vm.toString(i)));
            string memory symbol = string(abi.encodePacked("AST", vm.toString(i)));
            mockAssets[i] = new MockRWA(name, symbol);
            assetAddresses[i] = address(mockAssets[i]);

            // Create oracle for each asset
            RWAPriceConsumerV3 oracle = new RWAPriceConsumerV3();
            oracle.setPrice(1000e8); // $1000 per token

            // Configure asset in protocol
            assetsInstance.updateAssetConfig(
                address(mockAssets[i]),
                address(oracle),
                8,
                18,
                1,
                800, // 80% borrow threshold
                850, // 85% liquidation threshold
                1_000_000 ether,
                ILendefiAssets.CollateralTier.CROSS_A,
                0
            );

            // Register oracle
            oracleInstance.addOracle(address(mockAssets[i]), address(oracle), 8);
            oracleInstance.setPrimaryOracle(address(mockAssets[i]), address(oracle));
        }
        vm.stopPrank();

        // Add all 20 assets as collateral
        uint256 totalCollateralValue = 0;
        uint256 collateralAmount = 5 ether;

        vm.startPrank(bob);
        for (uint256 i = 0; i < 20; i++) {
            // Mint tokens to Bob
            mockAssets[i].mint(bob, collateralAmount);

            // Add as collateral
            mockAssets[i].approve(address(LendefiInstance), collateralAmount);
            LendefiInstance.supplyCollateral(address(mockAssets[i]), collateralAmount, positionId);

            // Track total value for logging
            totalCollateralValue += collateralAmount * 1000 * 80 / 100; // 80% of $1000 per token
        }

        // Borrow near the maximum allowed - CHANGE: increase from 95% to 98%
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(bob, positionId);
        uint256 borrowAmount = creditLimit * 98 / 100; // 98% of credit limit
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();

        // Log initial state
        console2.log("Position created with 20 different assets");
        console2.log("Total collateral value (USD): ", totalCollateralValue);
        console2.log("Borrow amount (USDC): ", borrowAmount);
        console2.log("Credit limit: ", creditLimit);

        // Make position liquidatable by dropping all asset prices
        // CHANGE: drop by 15% instead of 10%
        vm.startPrank(address(timelockInstance));
        for (uint256 i = 0; i < 20; i++) {
            // Get the oracle for this asset
            address oracle = assetInfo(assetAddresses[i]).oracleUSD;
            RWAPriceConsumerV3(oracle).setPrice(850e8); // Drop from $1000 to $850 (15% drop)
        }
        vm.stopPrank();

        // Calculate and log health factor
        uint256 healthFactor = LendefiInstance.healthFactor(bob, positionId);
        console2.log("Health factor after price drop: ", healthFactor);

        // Verify position is now liquidatable
        bool isLiquidatable = LendefiInstance.isLiquidatable(bob, positionId);
        assertTrue(isLiquidatable, "Position should be liquidatable after price drop");

        // Execute liquidation with gas measurement
        vm.startPrank(charlie);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6); // Approve more than needed

        uint256 gasStart = gasleft();
        LendefiInstance.liquidate(bob, positionId);
        uint256 gasUsed = gasStart - gasleft();
        vm.stopPrank();

        // Log gas usage
        console2.log("Gas used for liquidation of 20 assets: ", gasUsed);

        // Verify liquidation was successful
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(position.debtAmount, 0, "Debt should be cleared");

        // Verify all 20 assets were transferred to Charlie
        for (uint256 i = 0; i < 20; i++) {
            uint256 charlieBalance = mockAssets[i].balanceOf(charlie);
            assertEq(charlieBalance, collateralAmount, "Liquidator should receive all collateral");
        }
    }

    // Add this test to the LiquidateTest contract
    function test_LiquidationUpdatesTotalBorrow() public {
        // Setup a liquidatable position
        uint256 positionId = _setupLiquidatablePosition(bob, address(wethInstance), false);

        // Get the position debt amount before liquidation
        // We need to use position.debtAmount, not calculateDebtWithInterest, because
        // that's what the contract subtracts from totalBorrow in the liquidate function
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        uint256 positionDebtAmount = position.debtAmount;

        // Get the total borrow amount before liquidation
        uint256 totalBorrowBefore = LendefiInstance.totalBorrow();

        // Ensure we have a meaningful test by verifying the debt is included in totalBorrow
        assertGt(positionDebtAmount, 0, "Position must have debt for this test");
        assertGe(totalBorrowBefore, positionDebtAmount, "Total borrow must include position debt");

        console2.log("Position debt amount:", positionDebtAmount);
        console2.log("Total borrow before liquidation:", totalBorrowBefore);

        // Setup Charlie as liquidator
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), charlie, 50_000 ether); // Give enough gov tokens

        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        uint256 liquidationFee = LendefiInstance.getPositionLiquidationFee(bob, positionId);
        uint256 feeAmount = (debtWithInterest * liquidationFee) / 1e6;
        uint256 totalRequired = debtWithInterest + feeAmount;

        // Prepare the liquidator with enough USDC
        usdcInstance.mint(charlie, totalRequired);

        // Perform the liquidation
        vm.startPrank(charlie);
        usdcInstance.approve(address(LendefiInstance), totalRequired);
        LendefiInstance.liquidate(bob, positionId);
        vm.stopPrank();

        // Get the total borrow amount after liquidation
        uint256 totalBorrowAfter = LendefiInstance.totalBorrow();
        console2.log("Total borrow after liquidation:", totalBorrowAfter);

        // Verify that totalBorrow was reduced by exactly the position's debt amount
        assertEq(
            totalBorrowBefore - positionDebtAmount,
            totalBorrowAfter,
            "totalBorrow should be reduced by exactly position.debtAmount"
        );
    }
    // Helper function to access assetInfo storage for tests

    function assetInfo(address asset) internal view returns (ILendefiAssets.Asset memory) {
        return assetsInstance.getAssetInfo(asset);
    }
}
