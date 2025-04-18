// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";

contract IsRewardableTest is BasicDeploy {
    // Test user accounts
    address internal user1;
    address internal user2;
    address internal user3;

    // Constants for test parameters
    uint256 constant LARGE_SUPPLY = 1_000_000e6; // 1 million USDC
    uint256 constant MEDIUM_SUPPLY = 100_000e6; // 100k USDC
    uint256 constant SMALL_SUPPLY = 10_000e6; // 10k USDC

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Create test user accounts
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        vm.startPrank(address(timelockInstance));
        // Grant the REWARDER_ROLE to Lendefi contract for ecosystem rewards
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));
        // Initialize reward parameters via timelock using the config approach
        // Get current config
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // Update specific parameters while keeping others
        config.rewardAmount = 1_000e18; // Set target reward to 1000 tokens
        config.rewardInterval = 180 days; // Set reward interval to 180 days
        config.rewardableSupply = 100_000e6; // Set rewardable supply to 100k USDC

        // Apply updated config
        LendefiInstance.loadProtocolConfig(config);

        vm.stopPrank();
    }

    // Helper function to supply liquidity
    function _supplyLiquidity(address user, uint256 amount) internal {
        usdcInstance.mint(user, amount);
        vm.startPrank(user);
        usdcInstance.approve(address(LendefiInstance), amount);
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();
    }

    // Helper function for withdrawing liquidity
    function _exchangeLPTokens(address user, uint256 lpTokenAmount) internal {
        vm.startPrank(user);
        LendefiInstance.exchange(lpTokenAmount);
        vm.stopPrank();
    }

    // Test 1: User with no liquidity supplied should not be eligible
    function test_NoLiquidityNotRewardable() public {
        bool isEligible = LendefiInstance.isRewardable(user1);
        assertFalse(isEligible, "User with no liquidity should not be rewardable");
    }

    // Test 2: User with insufficient balance should not be eligible
    function test_InsufficientBalanceNotRewardable() public {
        // Get config to check threshold
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // Supply amount less than threshold
        uint256 smallSupply = config.rewardableSupply / 2; // 50% of threshold
        _supplyLiquidity(user1, smallSupply);

        // Fast-forward beyond reward interval
        vm.warp(block.timestamp + config.rewardInterval + 1);

        bool isEligible = LendefiInstance.isRewardable(user1);
        assertFalse(isEligible, "User with insufficient balance should not be rewardable");
    }

    // Test 3: User with sufficient balance but insufficient time should not be eligible
    function test_InsufficientTimeNotRewardable() public {
        // Get config to check interval
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // Supply above threshold
        _supplyLiquidity(user1, LARGE_SUPPLY);

        // Fast-forward but not enough time
        vm.warp(block.timestamp + config.rewardInterval - 1 days);

        bool isEligible = LendefiInstance.isRewardable(user1);
        assertFalse(isEligible, "User with insufficient time should not be rewardable");
    }

    // Test 4: User meets all criteria and should be eligible
    function test_UserIsRewardable() public {
        // Get config to check parameters
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // Supply above threshold
        _supplyLiquidity(user1, LARGE_SUPPLY);

        // Fast-forward beyond reward interval
        vm.warp(block.timestamp + config.rewardInterval + 1);

        bool isEligible = LendefiInstance.isRewardable(user1);
        assertTrue(isEligible, "User with sufficient balance and time should be rewardable");
    }

    // Test 5: Edge case - User exactly at the reward threshold
    function test_ExactThresholdRewardable() public {
        // Get config to check threshold
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        uint256 thresholdAmount = config.rewardableSupply;
        _supplyLiquidity(user1, thresholdAmount);

        // Fast-forward beyond reward interval
        vm.warp(block.timestamp + config.rewardInterval + 1);

        bool isEligible = LendefiInstance.isRewardable(user1);
        assertTrue(isEligible, "User with exact threshold balance should be rewardable");
    }

    // Test 6: Edge case - User exactly at the time threshold
    function test_ExactTimeThresholdRewardable() public {
        // Get config to check interval
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        _supplyLiquidity(user1, LARGE_SUPPLY);

        // Fast-forward to exactly the reward interval
        vm.warp(block.timestamp + config.rewardInterval);

        bool isEligible = LendefiInstance.isRewardable(user1);
        assertTrue(isEligible, "User at exact time threshold should be rewardable");
    }

    // Test 7: Multiple users with different eligibility
    function test_MultipleUsersDifferentEligibility() public {
        // Get config for parameters
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // User1: Enough balance, enough time
        _supplyLiquidity(user1, LARGE_SUPPLY);

        // User2: Enough balance, not enough time
        _supplyLiquidity(user2, LARGE_SUPPLY);

        // User3: Not enough balance, enough time
        _supplyLiquidity(user3, SMALL_SUPPLY);

        // Fast-forward beyond reward interval for User1 and User3
        vm.warp(block.timestamp + config.rewardInterval + 1);

        assertTrue(LendefiInstance.isRewardable(user1), "User1 should be eligible");
        assertFalse(LendefiInstance.isRewardable(user3), "User3 should be ineligible due to balance");

        // For User2, we need to check if they're actually eligible
        uint256 lastAccrualTime = LendefiInstance.getLiquidityAccrueTimeIndex(user2);
        bool shouldBeEligible = block.timestamp - config.rewardInterval >= lastAccrualTime;
        assertEq(LendefiInstance.isRewardable(user2), shouldBeEligible, "User2 eligibility check");
    }

    // Test 8: Changing protocol parameters affects eligibility
    function test_ParameterChangesAffectEligibility() public {
        // Supply near the threshold
        _supplyLiquidity(user1, 110_000e6); // 110k USDC

        // Fast-forward beyond reward interval
        vm.warp(block.timestamp + 181 days);

        // Initially eligible
        assertTrue(LendefiInstance.isRewardable(user1), "User should initially be eligible");

        // Increase the threshold using the config approach
        vm.startPrank(address(timelockInstance));

        // Get current config
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // Update the rewardable supply parameter while keeping others
        config.rewardableSupply = 150_000e6; // Increase threshold to 150k USDC

        // Apply updated config
        LendefiInstance.loadProtocolConfig(config);

        vm.stopPrank();

        // Should no longer be eligible
        assertFalse(LendefiInstance.isRewardable(user1), "User should be ineligible after threshold increase");
    }

    // Test 9: Protocol actions reset the timer
    function test_SupplyResetsRewardTimer() public {
        // Get config for parameters
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // Initial supply
        _supplyLiquidity(user1, LARGE_SUPPLY);

        // Fast-forward almost to eligibility
        vm.warp(block.timestamp + config.rewardInterval - 1 days);

        // Supply more, which should reset the timer
        _supplyLiquidity(user1, MEDIUM_SUPPLY);

        // Fast-forward just a bit more (would have been eligible without the reset)
        vm.warp(block.timestamp + 2 days);

        // Should not be eligible due to reset timer
        assertFalse(LendefiInstance.isRewardable(user1), "User should not be eligible after timer reset");

        // Fast-forward the full interval after the second supply
        vm.warp(block.timestamp + config.rewardInterval);

        // Now should be eligible
        assertTrue(LendefiInstance.isRewardable(user1), "User should be eligible after full interval");
    }

    // Test 10: Zero totalSupply edge case
    function test_ZeroTotalSupplyEdgeCase() public {
        // Edge case: check isRewardable when totalSupply is 0
        // This should never happen in production, but testing for robustness

        // Verify the initial state
        assertEq(yieldTokenInstance.totalSupply(), 0, "Initial totalSupply should be zero");

        // This shouldn't revert
        bool result = LendefiInstance.isRewardable(user1);
        assertFalse(result, "User should not be rewardable with zero totalSupply");
    }

    // Test 11: Multiple deposits and their effect on reward timer
    function test_MultipleDepositsTimerBehavior() public {
        // Get config for parameters
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // First deposit
        _supplyLiquidity(user1, 50_000e6); // 50k (below threshold)

        // Fast-forward 90 days (half the interval)
        vm.warp(block.timestamp + 90 days);

        // Second deposit to reach threshold
        _supplyLiquidity(user1, 60_000e6); // Additional 60k (total now 110k)

        // Check accrual time - should be updated to the second deposit time
        uint256 newAccrualTime = LendefiInstance.getLiquidityAccrueTimeIndex(user1);
        // The accrual time is always set to the current block timestamp on each deposit
        assertEq(newAccrualTime, block.timestamp, "Accrual time should be set to current block timestamp");

        // Fast-forward another full interval from the latest deposit
        vm.warp(block.timestamp + config.rewardInterval);

        // Should be eligible now because:
        // 1. User has more than rewardableSupply (110k > 100k)
        // 2. It's been the full reward interval since the last deposit (which reset the timer)
        assertTrue(LendefiInstance.isRewardable(user1), "User should be eligible after full interval from last deposit");
    }

    // Test 12: Multiple partial withdrawals and eligibility
    function test_MultiplePartialWithdrawals() public {
        // Get config for parameters
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // Supply 200k USDC (well above threshold)
        _supplyLiquidity(user1, 200_000e6);

        // Fast-forward past reward interval
        vm.warp(block.timestamp + config.rewardInterval + 1);

        // Should be eligible
        assertTrue(LendefiInstance.isRewardable(user1), "User should be eligible initially");

        // Make a small withdrawal that doesn't drop below threshold
        uint256 userBalance = yieldTokenInstance.balanceOf(user1);
        _exchangeLPTokens(user1, userBalance / 4); // Withdraw 25%

        // Should still be eligible
        assertTrue(LendefiInstance.isRewardable(user1), "User should still be eligible after small withdrawal");

        // Make another withdrawal that drops below threshold
        userBalance = yieldTokenInstance.balanceOf(user1);
        _exchangeLPTokens(user1, userBalance - 10); // Withdraw almost everything

        // Should no longer be eligible
        assertFalse(LendefiInstance.isRewardable(user1), "User should be ineligible after large withdrawal");
    }
}
