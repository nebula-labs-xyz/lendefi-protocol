// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {ILendefiAssets} from "../../../contracts/interfaces/ILendefiAssets.sol";
import {MockPriceOracle} from "../../../contracts/mock/MockPriceOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract UpdateProtocolParametersTest is BasicDeploy {
    // Default values from initialize()
    uint256 constant DEFAULT_BASE_PROFIT_TARGET = 0.01e6; // 1%
    uint256 constant DEFAULT_BASE_BORROW_RATE = 0.06e6; // 6%
    uint256 constant DEFAULT_TARGET_REWARD = 2_000 ether;
    uint256 constant DEFAULT_REWARD_INTERVAL = 180 days;
    uint256 constant DEFAULT_REWARDABLE_SUPPLY = 100_000 * 1e6;
    uint256 constant DEFAULT_LIQUIDATOR_THRESHOLD = 20_000 ether;

    // New values for testing
    uint256 constant NEW_BASE_PROFIT_TARGET = 0.02e6; // 2%
    uint256 constant NEW_BASE_BORROW_RATE = 0.08e6; // 8%
    uint256 constant NEW_TARGET_REWARD = 3_000 ether;
    uint256 constant NEW_REWARD_INTERVAL = 365 days;
    uint256 constant NEW_REWARDABLE_SUPPLY = 150_000 * 1e6;
    uint256 constant NEW_LIQUIDATOR_THRESHOLD = 30_000 ether;

    // Minimum values for testing
    uint256 constant MIN_BASE_PROFIT_TARGET = 0.0025e6; // 0.25%
    uint256 constant MIN_BASE_BORROW_RATE = 0.01e6; // 1%
    uint256 constant MIN_REWARD_INTERVAL = 90 days;
    uint256 constant MIN_REWARDABLE_SUPPLY = 20_000 * 1e6;
    uint256 constant MIN_LIQUIDATOR_THRESHOLD = 10 ether;

    function setUp() public {
        // Use the updated deployment function that includes Oracle setup
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
    }

    /* --------------- Access Control Tests --------------- */

    function testRevert_UpdateProtocolMetrics_AccessControl() public {
        // Regular user should not be able to update
        vm.startPrank(alice);

        // OZ AccessControl v5 error format
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, MANAGER_ROLE)
        );

        LendefiInstance.updateProtocolMetrics(
            NEW_BASE_PROFIT_TARGET,
            NEW_BASE_BORROW_RATE,
            NEW_TARGET_REWARD,
            NEW_REWARD_INTERVAL,
            NEW_REWARDABLE_SUPPLY,
            NEW_LIQUIDATOR_THRESHOLD
        );
        vm.stopPrank();

        // Manager should be able to update
        vm.prank(address(timelockInstance));
        LendefiInstance.updateProtocolMetrics(
            NEW_BASE_PROFIT_TARGET,
            NEW_BASE_BORROW_RATE,
            NEW_TARGET_REWARD,
            NEW_REWARD_INTERVAL,
            NEW_REWARDABLE_SUPPLY,
            NEW_LIQUIDATOR_THRESHOLD
        );
    }

    /* --------------- State Change Tests --------------- */

    function test_UpdateProtocolMetrics_StateChange() public {
        // Verify initial values
        assertEq(LendefiInstance.baseProfitTarget(), DEFAULT_BASE_PROFIT_TARGET);
        assertEq(LendefiInstance.baseBorrowRate(), DEFAULT_BASE_BORROW_RATE);
        assertEq(LendefiInstance.targetReward(), DEFAULT_TARGET_REWARD);
        assertEq(LendefiInstance.rewardInterval(), DEFAULT_REWARD_INTERVAL);
        assertEq(LendefiInstance.rewardableSupply(), DEFAULT_REWARDABLE_SUPPLY);
        assertEq(LendefiInstance.liquidatorThreshold(), DEFAULT_LIQUIDATOR_THRESHOLD);

        // Update values
        vm.prank(address(timelockInstance));
        LendefiInstance.updateProtocolMetrics(
            NEW_BASE_PROFIT_TARGET,
            NEW_BASE_BORROW_RATE,
            NEW_TARGET_REWARD,
            NEW_REWARD_INTERVAL,
            NEW_REWARDABLE_SUPPLY,
            NEW_LIQUIDATOR_THRESHOLD
        );

        // Verify updated values
        assertEq(LendefiInstance.baseProfitTarget(), NEW_BASE_PROFIT_TARGET);
        assertEq(LendefiInstance.baseBorrowRate(), NEW_BASE_BORROW_RATE);
        assertEq(LendefiInstance.targetReward(), NEW_TARGET_REWARD);
        assertEq(LendefiInstance.rewardInterval(), NEW_REWARD_INTERVAL);
        assertEq(LendefiInstance.rewardableSupply(), NEW_REWARDABLE_SUPPLY);
        assertEq(LendefiInstance.liquidatorThreshold(), NEW_LIQUIDATOR_THRESHOLD);
    }

    /* --------------- Minimum Value Tests --------------- */

    function testRevert_UpdateProtocolMetrics_ProfitTargetTooLow() public {
        vm.prank(address(timelockInstance));

        // Profit target too low error code is "I1"
        vm.expectRevert(bytes("I1"));

        LendefiInstance.updateProtocolMetrics(
            MIN_BASE_PROFIT_TARGET - 1, // Too low
            DEFAULT_BASE_BORROW_RATE,
            DEFAULT_TARGET_REWARD,
            DEFAULT_REWARD_INTERVAL,
            DEFAULT_REWARDABLE_SUPPLY,
            DEFAULT_LIQUIDATOR_THRESHOLD
        );
    }

    function testRevert_UpdateProtocolMetrics_BorrowRateTooLow() public {
        vm.prank(address(timelockInstance));

        // Borrow rate too low error code is "I2"
        vm.expectRevert(bytes("I2"));

        LendefiInstance.updateProtocolMetrics(
            DEFAULT_BASE_PROFIT_TARGET,
            MIN_BASE_BORROW_RATE - 1, // Too low
            DEFAULT_TARGET_REWARD,
            DEFAULT_REWARD_INTERVAL,
            DEFAULT_REWARDABLE_SUPPLY,
            DEFAULT_LIQUIDATOR_THRESHOLD
        );
    }

    function test_UpdateProtocolMetrics_TargetRewardLimit() public {
        vm.prank(address(timelockInstance));

        // Target reward has upper limit (10,000 ether); error code is "I3"
        vm.expectRevert(bytes("I3"));

        LendefiInstance.updateProtocolMetrics(
            DEFAULT_BASE_PROFIT_TARGET,
            DEFAULT_BASE_BORROW_RATE,
            10_001 ether, // Too high (> 10,000 ether)
            DEFAULT_REWARD_INTERVAL,
            DEFAULT_REWARDABLE_SUPPLY,
            DEFAULT_LIQUIDATOR_THRESHOLD
        );
    }

    function testRevert_UpdateProtocolMetrics_RewardIntervalTooShort() public {
        vm.prank(address(timelockInstance));

        // Reward interval too short error code is "I4"
        vm.expectRevert(bytes("I4"));

        LendefiInstance.updateProtocolMetrics(
            DEFAULT_BASE_PROFIT_TARGET,
            DEFAULT_BASE_BORROW_RATE,
            DEFAULT_TARGET_REWARD,
            MIN_REWARD_INTERVAL - 1, // Too short
            DEFAULT_REWARDABLE_SUPPLY,
            DEFAULT_LIQUIDATOR_THRESHOLD
        );
    }

    function testRevert_UpdateProtocolMetrics_RewardableSupplyTooLow() public {
        vm.prank(address(timelockInstance));

        // Rewardable supply too low error code is "I5"
        vm.expectRevert(bytes("I5"));

        LendefiInstance.updateProtocolMetrics(
            DEFAULT_BASE_PROFIT_TARGET,
            DEFAULT_BASE_BORROW_RATE,
            DEFAULT_TARGET_REWARD,
            DEFAULT_REWARD_INTERVAL,
            MIN_REWARDABLE_SUPPLY - 1, // Too low
            DEFAULT_LIQUIDATOR_THRESHOLD
        );
    }

    function testRevert_UpdateProtocolMetrics_LiquidatorThresholdTooLow() public {
        vm.prank(address(timelockInstance));

        // Liquidator threshold too low error code is "I6"
        vm.expectRevert(bytes("I6"));

        LendefiInstance.updateProtocolMetrics(
            DEFAULT_BASE_PROFIT_TARGET,
            DEFAULT_BASE_BORROW_RATE,
            DEFAULT_TARGET_REWARD,
            DEFAULT_REWARD_INTERVAL,
            DEFAULT_REWARDABLE_SUPPLY,
            MIN_LIQUIDATOR_THRESHOLD - 1 // Too low
        );
    }

    function test_UpdateProtocolMetrics_MinimumValues() public {
        // Should succeed with minimum values
        vm.prank(address(timelockInstance));

        LendefiInstance.updateProtocolMetrics(
            MIN_BASE_PROFIT_TARGET,
            MIN_BASE_BORROW_RATE,
            DEFAULT_TARGET_REWARD, // No minimum
            MIN_REWARD_INTERVAL,
            MIN_REWARDABLE_SUPPLY,
            MIN_LIQUIDATOR_THRESHOLD
        );

        // Verify state changes
        assertEq(LendefiInstance.baseProfitTarget(), MIN_BASE_PROFIT_TARGET);
        assertEq(LendefiInstance.baseBorrowRate(), MIN_BASE_BORROW_RATE);
        assertEq(LendefiInstance.rewardInterval(), MIN_REWARD_INTERVAL);
        assertEq(LendefiInstance.rewardableSupply(), MIN_REWARDABLE_SUPPLY);
        assertEq(LendefiInstance.liquidatorThreshold(), MIN_LIQUIDATOR_THRESHOLD);
    }

    /* --------------- Effect On Protocol Tests --------------- */

    function test_UpdateProtocolMetrics_EffectOnBorrowRate() public {
        // Setup protocol with supply and borrow
        _setupProtocolWithSupplyAndBorrow();

        // Get initial borrow rate for STABLE tier
        uint256 initialBorrowRate = LendefiInstance.getBorrowRate(ILendefiAssets.CollateralTier.STABLE);

        // Update base borrow rate (double it)
        vm.prank(address(timelockInstance));
        LendefiInstance.updateProtocolMetrics(
            DEFAULT_BASE_PROFIT_TARGET,
            DEFAULT_BASE_BORROW_RATE * 2,
            DEFAULT_TARGET_REWARD,
            DEFAULT_REWARD_INTERVAL,
            DEFAULT_REWARDABLE_SUPPLY,
            DEFAULT_LIQUIDATOR_THRESHOLD
        );

        // Get new borrow rate
        uint256 newBorrowRate = LendefiInstance.getBorrowRate(ILendefiAssets.CollateralTier.STABLE);

        // Borrow rate should be higher after increase to base
        assertGt(newBorrowRate, initialBorrowRate, "Borrow rate should increase when base borrow rate increases");
    }

    function test_UpdateProtocolMetrics_EffectOnSupplyRate() public {
        // Setup protocol with supply and borrow
        _setupProtocolWithSupplyAndBorrow();

        // Generate protocol profit by minting additional USDC directly to the contract
        usdcInstance.mint(address(LendefiInstance), 5_000e6); // Add 5,000 USDC as profit

        // Get initial supply rate
        uint256 initialSupplyRate = LendefiInstance.getSupplyRate();

        // Update profit target (double it)
        vm.prank(address(timelockInstance));
        LendefiInstance.updateProtocolMetrics(
            DEFAULT_BASE_PROFIT_TARGET * 2,
            DEFAULT_BASE_BORROW_RATE,
            DEFAULT_TARGET_REWARD,
            DEFAULT_REWARD_INTERVAL,
            DEFAULT_REWARDABLE_SUPPLY,
            DEFAULT_LIQUIDATOR_THRESHOLD
        );

        // Get new supply rate
        uint256 newSupplyRate = LendefiInstance.getSupplyRate();

        // Supply rate should change when profit target changes
        assertNotEq(initialSupplyRate, newSupplyRate, "Supply rate should change when profit target changes");
    }

    /* --------------- Helper Functions --------------- */

    function _setupProtocolWithSupplyAndBorrow() internal {
        // Mint USDC to alice and supply liquidity
        usdcInstance.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 100_000e6);
        LendefiInstance.supplyLiquidity(100_000e6);
        vm.stopPrank();

        // Set up a mock price oracle for WETH
        wethInstance = new WETH9();
        MockPriceOracle wethOracle = new MockPriceOracle();
        wethOracle.setPrice(2500e8);
        wethOracle.setTimestamp(block.timestamp);
        wethOracle.setRoundId(1);
        wethOracle.setAnsweredInRound(1);

        // Configure WETH as CROSS_A tier asset
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracle),
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // max supply
            ILendefiAssets.CollateralTier.CROSS_A,
            0 // no isolation debt cap
        );
        vm.stopPrank();

        // Bob supplies collateral and borrows
        vm.deal(bob, 10 ether);
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.createPosition(address(wethInstance), false);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, 0);
        LendefiInstance.borrow(0, 10_000e6); // Borrow 10k USDC
        vm.stopPrank();
    }
}
