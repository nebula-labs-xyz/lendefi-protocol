// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {MockPriceOracle} from "../../../contracts/mock/MockPriceOracle.sol";

contract PositionStatusTest is BasicDeploy {
    // Oracle instance
    MockPriceOracle internal wethOracle;

    // Constants
    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy WETH (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();

        // Deploy price oracle with proper implementation
        wethOracle = new MockPriceOracle();
        wethOracle.setPrice(int256(2500e8)); // $2500 per ETH
        wethOracle.setTimestamp(block.timestamp);
        wethOracle.setRoundId(1);
        wethOracle.setAnsweredInRound(1);

        // Register the oracle with the Oracle module
        vm.startPrank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        // Update asset config for WETH
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
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        assetsInstance.updateTierConfig(IASSETS.CollateralTier.CROSS_A, 0.08e6, 0.02e6);
        vm.stopPrank();

        // Log the updated parameters to verify
        (, uint256[4] memory bonuses) = assetsInstance.getTierRates();
        console2.log("CROSS_A tier liquidation bonus:", bonuses[1]);

        // Add initial liquidity
        usdcInstance.mint(guardian, INITIAL_LIQUIDITY);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), INITIAL_LIQUIDITY);
        LendefiInstance.supplyLiquidity(INITIAL_LIQUIDITY);
        vm.stopPrank();

        // Mint WETH to guardian for distribution
        vm.deal(address(this), 100 ether);
        wethInstance.deposit{value: 100 ether}();
        wethInstance.transfer(guardian, 100 ether);
    }

    function test_InitialPositionStatus() public {
        // Create a new position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Verify initial status is ACTIVE
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(uint256(position.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "New position should be ACTIVE");
    }

    function test_LiquidatedPositionStatus() public {
        // Setup a position that can be liquidated
        uint256 positionId = _setupLiquidatablePosition(bob, address(wethInstance), false);

        // Verify status is ACTIVE before liquidation
        IPROTOCOL.UserPosition memory positionBefore = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(positionBefore.status),
            uint256(IPROTOCOL.PositionStatus.ACTIVE),
            "Position should be ACTIVE before liquidation"
        );

        // Perform liquidation
        _setupLiquidatorAndExecute(bob, positionId, charlie);

        // Verify status is now LIQUIDATED
        IPROTOCOL.UserPosition memory positionAfter = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(positionAfter.status),
            uint256(IPROTOCOL.PositionStatus.LIQUIDATED),
            "Position should be LIQUIDATED after liquidation"
        );
    }

    function test_ClosedPositionStatus() public {
        // Create a new position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Supply some collateral
        uint256 collateralAmount = 1 ether;
        _mintTokens(bob, address(wethInstance), collateralAmount);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Exit position without borrowing
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();

        // Position should still exist but be marked as CLOSED
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(position.status),
            uint256(IPROTOCOL.PositionStatus.CLOSED),
            "Position should be marked as CLOSED after exit"
        );

        // Verify no collateral remains
        address[] memory assets = LendefiInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(assets.length, 0, "Position should have no collateral assets after exit");

        // Verify no debt remains
        assertEq(position.debtAmount, 0, "Position should have no debt after exit");
    }

    function test_InvalidOperationsOnClosedPosition() public {
        // Create a position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Supply collateral
        uint256 collateralAmount = 1 ether;
        _mintTokens(bob, address(wethInstance), collateralAmount);

        vm.startPrank(bob);
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Exit position
        LendefiInstance.exitPosition(positionId);

        // Verify position is actually closed
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(uint256(position.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position should be CLOSED");

        // For borrow, we need to handle the validation in a different way
        // First, borrow amount must be non-zero, otherwise we'll get InvalidBorrowAmount error
        uint256 borrowAmount = 100e6;

        // Use custom error for InactivePosition
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector));
        LendefiInstance.borrow(positionId, borrowAmount);

        // For supply collateral
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector));
        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, positionId);

        // For withdraw collateral
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector));
        LendefiInstance.withdrawCollateral(address(wethInstance), 0.1 ether, positionId);

        vm.stopPrank();
    }

    function test_InvalidOperationsOnLiquidatedPosition() public {
        // Setup a liquidatable position
        uint256 positionId = _setupLiquidatablePosition(bob, address(wethInstance), false);

        // Liquidate the position
        _setupLiquidatorAndExecute(bob, positionId, charlie);

        // Attempt operations on liquidated position
        vm.startPrank(bob);

        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector));
        LendefiInstance.borrow(positionId, 100e6);

        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector));
        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, positionId);

        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector));
        LendefiInstance.withdrawCollateral(address(wethInstance), 0.1 ether, positionId);

        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InactivePosition.selector));
        LendefiInstance.exitPosition(positionId);

        vm.stopPrank();
    }

    function test_PositionCountAfterStatusChange() public {
        // Create multiple positions
        uint256 pos1 = _createPosition(bob, address(wethInstance), false);
        uint256 pos2 = _createPosition(bob, address(wethInstance), false);
        uint256 pos3 = _createPosition(bob, address(wethInstance), false);

        // Verify initial count
        uint256 initialCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(initialCount, 3, "Should have 3 positions initially");

        // Setup and liquidate position 1
        _setupAndLiquidatePosition(bob, pos1, charlie);

        // Close position 2
        _setupAndClosePosition(bob, pos2);

        // Verify count remains unchanged
        uint256 finalCount = LendefiInstance.getUserPositionsCount(bob);
        assertEq(finalCount, initialCount, "Position count should remain unchanged after status changes");

        // Verify individual position statuses
        IPROTOCOL.UserPosition memory position1 = LendefiInstance.getUserPosition(bob, pos1);
        IPROTOCOL.UserPosition memory position2 = LendefiInstance.getUserPosition(bob, pos2);
        IPROTOCOL.UserPosition memory position3 = LendefiInstance.getUserPosition(bob, pos3);

        assertEq(
            uint256(position1.status), uint256(IPROTOCOL.PositionStatus.LIQUIDATED), "Position 1 should be LIQUIDATED"
        );
        assertEq(uint256(position2.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position 2 should be CLOSED");
        assertEq(uint256(position3.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position 3 should be ACTIVE");
    }

    function test_GetPositionStatus() public {
        // Create a new position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Check status in the UserPosition struct
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(uint256(position.status), uint256(IPROTOCOL.PositionStatus.ACTIVE), "Position status should be ACTIVE");

        // Create another position for liquidation
        uint256 positionId2 = _setupLiquidatablePosition(bob, address(wethInstance), false);
        _setupLiquidatorAndExecute(bob, positionId2, charlie);

        // Check liquidated status
        IPROTOCOL.UserPosition memory liquidatedPosition = LendefiInstance.getUserPosition(bob, positionId2);
        assertEq(
            uint256(liquidatedPosition.status),
            uint256(IPROTOCOL.PositionStatus.LIQUIDATED),
            "Position status should be LIQUIDATED"
        );

        // Close the active position
        _setupAndClosePosition(bob, positionId);

        // Check closed status
        IPROTOCOL.UserPosition memory closedPosition = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(
            uint256(closedPosition.status), uint256(IPROTOCOL.PositionStatus.CLOSED), "Position status should be CLOSED"
        );
    }

    // Helper function to create a position
    function _createPosition(address user, address asset, bool isIsolated) internal returns (uint256) {
        vm.prank(user);
        LendefiInstance.createPosition(asset, isIsolated);
        return LendefiInstance.getUserPositionsCount(user) - 1;
    }

    // Helper function to setup and liquidate a position
    function _setupAndLiquidatePosition(address user, uint256 positionId, address liquidator) internal {
        // Setup a liquidatable position
        _mintTokens(user, address(wethInstance), 5 ether);

        vm.startPrank(user);
        wethInstance.approve(address(LendefiInstance), 5 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 5 ether, positionId);

        // Calculate credit limit and borrow close to maximum
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(user, positionId);
        // uint256 borrowAmount = (creditLimit * 90) / 100; // 90% of credit limit
        LendefiInstance.borrow(positionId, creditLimit);
        vm.stopPrank();

        // Crash the price significantly
        wethOracle.setPrice(int256(2124e8)); // $2125 per ETH (15% drop)

        // Make sure position is liquidatable
        require(LendefiInstance.isLiquidatable(user, positionId), "Position should be liquidatable");

        // Liquidate position
        _setupLiquidatorAndExecute(user, positionId, liquidator);
    }

    // Helper function to setup and close a position
    function _setupAndClosePosition(address user, uint256 positionId) internal {
        _mintTokens(user, address(wethInstance), 1 ether);

        vm.startPrank(user);
        wethInstance.approve(address(LendefiInstance), 1 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, positionId);
        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();
    }

    // Helper to setup a liquidatable position and return its ID
    function _setupLiquidatablePosition(address user, address asset, bool isIsolated) internal returns (uint256) {
        uint256 positionId = _createPosition(user, asset, isIsolated);

        // Supply collateral
        uint256 collateralAmount = 5 ether; // Substantial collateral
        _mintTokens(user, asset, collateralAmount);

        vm.startPrank(user);
        IERC20(asset).approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(asset, collateralAmount, positionId);

        // Calculate safe borrow amount - borrow very close to the limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(user, positionId);
        LendefiInstance.borrow(positionId, creditLimit);
        vm.stopPrank();

        // Crash the price significantly - from $2500 to $2120 (16% drop)
        wethOracle.setPrice(int256(2500e8 * 84 / 100)); // $2120 per ETH

        // Debug output after price drop
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(user, positionId);
        uint256 newCreditLimit = LendefiInstance.calculateCreditLimit(user, positionId);
        console2.log("After price drop - debt:", debtWithInterest);
        console2.log("After price drop - credit limit:", newCreditLimit);

        // Verify position is now liquidatable
        bool isLiquidatable = LendefiInstance.isLiquidatable(user, positionId);

        require(isLiquidatable, "Position should be liquidatable after price drop");

        return positionId;
    }

    // Helper to mint tokens for testing
    function _mintTokens(address user, address token, uint256 amount) internal {
        if (token == address(wethInstance)) {
            vm.prank(guardian);
            wethInstance.transfer(user, amount);
        } else {
            // Generic ERC20 minting if needed
            vm.prank(guardian);
            IERC20(token).transfer(user, amount);
        }
    }

    // Helper to setup liquidator and execute liquidation
    function _setupLiquidatorAndExecute(address user, uint256 positionId, address liquidator) internal {
        // Give liquidator enough governance tokens
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();
        uint256 liquidatorThreshold = config.liquidatorThreshold;

        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), liquidator, liquidatorThreshold); // Give enough gov tokens

        // Calculate debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(user, positionId);

        // Give liquidator enough USDC to cover the debt with bonus
        usdcInstance.mint(liquidator, debtWithInterest * 2); // Extra buffer just to be safe

        // Execute liquidation
        vm.startPrank(liquidator);
        usdcInstance.approve(address(LendefiInstance), debtWithInterest * 2);
        LendefiInstance.liquidate(user, positionId);
        vm.stopPrank();
    }
}
