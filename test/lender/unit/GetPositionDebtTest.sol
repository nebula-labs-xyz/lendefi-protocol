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

contract GetPositionDebtTest is BasicDeploy {
    // Assets
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

    // Constants
    uint256 constant ETH_PRICE = 2500e8; // $2500 per ETH
    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    uint256 constant COLLATERAL_AMOUNT = 10 ether; // 10 ETH
    uint256 constant BORROW_AMOUNT_SMALL = 10_000e6; // 10k USDC
    uint256 constant BORROW_AMOUNT_LARGE = 100_000e6; // 100k USDC

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

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(usdcInstance), address(stableOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(usdcInstance), address(stableOracleInstance));
        vm.stopPrank();

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        // Configure assets
        _setupAssets();

        // Add liquidity to enable borrowing
        usdcInstance.mint(guardian, INITIAL_LIQUIDITY);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), INITIAL_LIQUIDITY);
        LendefiInstance.supplyLiquidity(INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier - Changed from LendefiInstance to assetsInstance
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // Supply limit
            ILendefiAssets.CollateralTier.CROSS_A, // Changed from IPROTOCOL to ILendefiAssets
            10_000e6 // Isolation debt cap
        );

        // Configure USDC as STABLE tier - Changed from LendefiInstance to assetsInstance
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            address(stableOracleInstance),
            8, // Oracle decimals
            6, // USDC decimals
            1, // Active
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000e6, // Supply limit
            ILendefiAssets.CollateralTier.STABLE, // Changed from IPROTOCOL to ILendefiAssets
            0 // No isolation debt cap
        );

        vm.stopPrank();
    }

    function _setupBorrowPosition(address user, uint256 collateralAmount, uint256 borrowAmount)
        internal
        returns (uint256)
    {
        vm.startPrank(user);

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(user) - 1;

        // Add ETH as collateral
        vm.deal(user, collateralAmount);
        wethInstance.deposit{value: collateralAmount}();
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow USDC
        LendefiInstance.borrow(positionId, borrowAmount);

        vm.stopPrank();

        return positionId;
    }

    function test_GetPositionDebt_ZeroDebt() public {
        vm.startPrank(alice);

        // Create position without borrowing
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        vm.stopPrank();

        // Check debt (should be zero) - Access through position struct now
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        uint256 debt = position.debtAmount;

        assertEq(debt, 0, "New position should have zero debt");
    }

    // Replace all calls to getPositionDebt with this pattern
    function test_GetPositionDebt_AfterBorrowing() public {
        // Setup position with collateral and borrow
        uint256 positionId = _setupBorrowPosition(alice, COLLATERAL_AMOUNT, BORROW_AMOUNT_SMALL);

        // Check debt through position struct
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        uint256 debt = position.debtAmount;

        assertEq(debt, BORROW_AMOUNT_SMALL, "Debt should match borrowed amount");
    }

    function test_GetPositionDebt_AfterFullRepay() public {
        // Setup position with collateral and borrow
        uint256 positionId = _setupBorrowPosition(alice, COLLATERAL_AMOUNT, BORROW_AMOUNT_SMALL);

        // Repay full debt
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), BORROW_AMOUNT_SMALL);
        LendefiInstance.repay(positionId, BORROW_AMOUNT_SMALL);
        vm.stopPrank();

        // Check debt after repayment through position struct
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        uint256 debtAfterRepay = position.debtAmount;

        assertEq(debtAfterRepay, 0, "Debt should be zero after full repayment");
    }

    function test_GetPositionDebt_InterestAccrual() public {
        // Setup position with collateral and borrow
        uint256 positionId = _setupBorrowPosition(alice, COLLATERAL_AMOUNT, BORROW_AMOUNT_SMALL);

        // Check initial debt
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        uint256 initialDebt = position.debtAmount;
        assertEq(initialDebt, BORROW_AMOUNT_SMALL, "Initial debt should match borrowed amount");

        // Fast forward time to accrue interest (1 year)
        vm.warp(block.timestamp + 365 days);

        // Note: getPositionDebt returns the raw debt amount without interest
        // We should compare with calculateDebtWithInterest which includes accrued interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(alice, positionId);
        position = LendefiInstance.getUserPosition(alice, positionId);
        uint256 currentDebt = position.debtAmount;

        assertEq(currentDebt, BORROW_AMOUNT_SMALL, "Raw debt should remain unchanged");
        assertGt(debtWithInterest, BORROW_AMOUNT_SMALL, "Debt with interest should be higher than initial debt");
    }

    function test_GetPositionDebt_MultiplePositions() public {
        // Setup  positions with different borrow amounts
        // Increase collateral for large borrow to avoid exceeding credit limit
        uint256 positionId1 = _setupBorrowPosition(alice, COLLATERAL_AMOUNT, BORROW_AMOUNT_SMALL);
        uint256 positionId2 = _setupBorrowPosition(alice, COLLATERAL_AMOUNT * 5, BORROW_AMOUNT_LARGE);

        // Check debt for each position
        IPROTOCOL.UserPosition memory position1 = LendefiInstance.getUserPosition(alice, positionId1);
        uint256 debt1 = position1.debtAmount;
        IPROTOCOL.UserPosition memory position2 = LendefiInstance.getUserPosition(alice, positionId2);
        uint256 debt2 = position2.debtAmount;

        assertEq(debt1, BORROW_AMOUNT_SMALL, "Debt for position 1 should match");
        assertEq(debt2, BORROW_AMOUNT_LARGE, "Debt for position 2 should match");
    }

    function test_GetPositionDebt_AfterPartialRepay() public {
        // Setup position with collateral and borrow
        // Increase collateral to avoid exceeding credit limit
        uint256 positionId = _setupBorrowPosition(alice, COLLATERAL_AMOUNT * 5, BORROW_AMOUNT_LARGE);

        // Repay half of the debt
        uint256 repayAmount = BORROW_AMOUNT_LARGE / 2;

        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), repayAmount);
        LendefiInstance.repay(positionId, repayAmount);
        vm.stopPrank();

        // Check debt after repayment
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(alice, positionId);
        uint256 debtAfterRepay = position.debtAmount;
        assertEq(debtAfterRepay, BORROW_AMOUNT_LARGE - repayAmount, "Debt should be reduced by repayment amount");
    }

    function test_GetPositionDebt_DifferentUsers() public {
        // Setup positions for  different users
        uint256 positionId1 = _setupBorrowPosition(alice, COLLATERAL_AMOUNT, BORROW_AMOUNT_SMALL);
        uint256 positionId2 = _setupBorrowPosition(bob, COLLATERAL_AMOUNT * 5, BORROW_AMOUNT_LARGE);

        // Check debt for each user
        IPROTOCOL.UserPosition memory position1 = LendefiInstance.getUserPosition(alice, positionId1);
        uint256 aliceDebt = position1.debtAmount;
        IPROTOCOL.UserPosition memory position2 = LendefiInstance.getUserPosition(bob, positionId2);
        uint256 bobDebt = position2.debtAmount;

        assertEq(aliceDebt, BORROW_AMOUNT_SMALL, "Alice's debt should match");
        assertEq(bobDebt, BORROW_AMOUNT_LARGE, "Bob's debt should match");
    }

    function testRevert_GetPositionDebt_InvalidPosition() public {
        // This should fail since position ID 999 doesn't exist
        vm.expectRevert(bytes("IN"));
        LendefiInstance.getUserPosition(alice, 999);
    }

    function testRevert_GetPositionDebt_WrongUser() public {
        // Setup position for Alice
        uint256 positionId = _setupBorrowPosition(alice, COLLATERAL_AMOUNT, BORROW_AMOUNT_SMALL);

        // Try to access Alice's position debt as Bob (should fail)
        vm.expectRevert(bytes("IN"));
        LendefiInstance.getUserPosition(bob, positionId);
    }
}
