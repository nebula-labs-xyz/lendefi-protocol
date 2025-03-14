// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";

contract ClaimRewardTest is BasicDeploy {
    // Events to verify
    event Reward(address indexed user, uint256 amount);
    event SupplyLiquidity(address indexed user, uint256 amount);

    // Protocol default values (from Lendefi.sol initialize)
    uint256 public defaultRewardInterval; // 180 days
    uint256 public defaultRewardableSupply; // 100,000 USDC
    uint256 public defaultTargetReward; // 2,000 tokens

    function setUp() public {
        // Deploy the full protocol with default settings
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Setup rewarder role
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        // Cache the default protocol parameters for testing
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();
        defaultRewardInterval = config.rewardInterval; // 180 days
        defaultRewardableSupply = config.rewardableSupply; // 100,000 USDC (with 6 decimals)
        defaultTargetReward = config.rewardAmount; // 2,000 ether (with 18 decimals)

        // Sanity check our cached values
        require(defaultRewardInterval == 180 days, "Expected 180 days reward interval");
        require(defaultRewardableSupply == 100_000e6, "Expected 100,000 USDC rewardable supply");
        require(defaultTargetReward == 2_000 ether, "Expected 2,000 tokens target reward");
    }

    // Helper function to supply liquidity
    function _supplyLiquidity(address user, uint256 amount) internal {
        usdcInstance.mint(user, amount);
        vm.startPrank(user);
        usdcInstance.approve(address(LendefiInstance), amount);
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();
    }

    // Test 1: Basic reward claiming functionality
    function test_BasicRewardClaim() public {
        uint256 supplyAmount = defaultRewardableSupply;

        // Supply sufficient liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Fast forward past the reward interval
        vm.warp(block.timestamp + defaultRewardInterval + 1 days);

        // Verify Alice is eligible
        bool eligible = LendefiInstance.isRewardable(alice);
        assertTrue(eligible, "Alice should be eligible for rewards");

        // Expect Reward event with correct user
        vm.expectEmit(true, false, false, false);
        emit Reward(alice, 0); // Just check the address match

        // Claim reward
        vm.prank(alice);
        uint256 claimedAmount = LendefiInstance.claimReward();

        // Verify reward was received
        assertEq(tokenInstance.balanceOf(alice), claimedAmount, "Claimed amount should match received tokens");
        assertTrue(claimedAmount > 0, "Should receive positive reward amount");

        // Verify no longer eligible after claiming (timer reset)
        assertFalse(LendefiInstance.isRewardable(alice), "Should no longer be eligible after claiming");
    }

    // Test 2: Claiming with insufficient time elapsed
    function test_InsufficientTimeElapsed() public {
        uint256 supplyAmount = defaultRewardableSupply;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Fast forward but not enough to be eligible
        vm.warp(block.timestamp + 30 days); // Much less than required 180 days

        // Verify Alice is not eligible due to time
        assertFalse(LendefiInstance.isRewardable(alice), "Alice should not be eligible yet");

        // Attempt to claim reward
        vm.prank(alice);
        uint256 claimedAmount = LendefiInstance.claimReward();

        // Verify no reward was received
        assertEq(claimedAmount, 0, "Should receive zero reward when not eligible");
        assertEq(tokenInstance.balanceOf(alice), 0, "Should have no tokens when claim fails");
    }

    // Test 3: Claiming with insufficient supply
    function test_InsufficientSupply() public {
        uint256 supplyAmount = defaultRewardableSupply / 2; // Half of required amount

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Fast forward past the reward interval
        vm.warp(block.timestamp + defaultRewardInterval + 1 days);

        // Verify Alice is not eligible due to supply
        assertFalse(LendefiInstance.isRewardable(alice), "Alice should not be eligible with insufficient supply");

        // Attempt to claim reward
        vm.prank(alice);
        uint256 claimedAmount = LendefiInstance.claimReward();

        // Verify no reward was received
        assertEq(claimedAmount, 0, "Should receive zero reward when not eligible");
        assertEq(tokenInstance.balanceOf(alice), 0, "Should have no tokens when claim fails");
    }

    // Test 4: Multiple users claiming rewards
    function test_MultipleUsersClaiming() public {
        uint256 aliceSupply = defaultRewardableSupply;
        uint256 bobSupply = defaultRewardableSupply * 2; // Double Alice's supply

        // Supply liquidity
        _supplyLiquidity(alice, aliceSupply);
        _supplyLiquidity(bob, bobSupply);

        // Fast forward past the reward interval
        vm.warp(block.timestamp + defaultRewardInterval + 1 days);

        // Claim rewards
        vm.prank(alice);
        uint256 aliceReward = LendefiInstance.claimReward();

        vm.prank(bob);
        uint256 bobReward = LendefiInstance.claimReward();

        // Verify rewards were received
        assertTrue(aliceReward > 0, "Alice should receive rewards");
        assertTrue(bobReward > 0, "Bob should receive rewards");

        // Whether Bob receives more than Alice depends on the reward calculation
        // For a simple test we just verify both got rewards
    }

    // Test 5: Maximum reward cap
    function test_MaximumRewardCap() public {
        uint256 supplyAmount = defaultRewardableSupply;

        // Set up max reward cap
        vm.prank(address(timelockInstance));
        ecoInstance.updateMaxReward(500 ether); // 500 tokens max (lower than default 2000)

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Fast forward a very long time (much more than interval)
        vm.warp(block.timestamp + defaultRewardInterval * 3); // 3x interval

        // Claim reward
        vm.prank(alice);
        uint256 claimedAmount = LendefiInstance.claimReward();

        // Verify reward was capped
        assertEq(claimedAmount, 500 ether, "Reward should be capped at maximum");
    }

    // Test 6: Claiming rewards after partial withdrawal
    function test_ClaimAfterPartialWithdrawal() public {
        uint256 supplyAmount = defaultRewardableSupply * 2; // Double minimum to ensure still eligible after withdrawal
        uint256 withdrawRatio = 30; // Withdraw 30%

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Calculate tokens to withdraw (approximately 30%)
        uint256 aliceTokenBalance = yieldTokenInstance.balanceOf(alice);
        uint256 tokensToWithdraw = (aliceTokenBalance * withdrawRatio) / 100;

        // Withdraw part of the liquidity
        vm.startPrank(alice);
        LendefiInstance.exchange(tokensToWithdraw);
        vm.stopPrank();

        // Fast forward past the reward interval
        vm.warp(block.timestamp + defaultRewardInterval + 1 days);

        // Check if still eligible
        bool eligible = LendefiInstance.isRewardable(alice);
        assertTrue(eligible, "Should still be eligible after partial withdrawal");

        // Claim reward
        vm.prank(alice);
        uint256 claimedAmount = LendefiInstance.claimReward();

        // Verify reward was received
        assertTrue(claimedAmount > 0, "Should receive rewards after partial withdrawal");
    }

    // Test 7: Multiple claims over time// Test 7: Multiple claims over time
    function test_MultipleClaimsOverTime() public {
        uint256 supplyAmount = defaultRewardableSupply * 2;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // First claim cycle - after exactly one interval
        vm.warp(block.timestamp + defaultRewardInterval);
        vm.prank(alice);
        uint256 firstReward = LendefiInstance.claimReward();
        assertTrue(firstReward > 0, "Should receive first reward");

        // Store time after first claim
        uint256 firstClaimTime = block.timestamp;

        // Second claim cycle - after exactly one more interval from first claim
        vm.warp(firstClaimTime + defaultRewardInterval);
        vm.prank(alice);
        uint256 secondReward = LendefiInstance.claimReward();
        assertTrue(secondReward > 0, "Should receive second reward");

        // Now the rewards should be much closer
        assertApproxEqRel(firstReward, secondReward, 0.1e18, "Rewards should be similar for equal intervals");
    }

    // Test 8: Rewards when protocol is paused
    function test_RewardsWhenPaused() public {
        uint256 supplyAmount = defaultRewardableSupply;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Fast forward past the reward interval
        vm.warp(block.timestamp + defaultRewardInterval + 1 days);

        // Pause the protocol
        vm.prank(guardian);
        LendefiInstance.pause();

        // Attempt to claim reward
        vm.prank(alice);
        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);
        LendefiInstance.claimReward();

        // Unpause and try again
        vm.prank(guardian);
        LendefiInstance.unpause();

        vm.prank(alice);
        uint256 claimedAmount = LendefiInstance.claimReward();
        assertTrue(claimedAmount > 0, "Should receive reward after unpausing");
    }

    // Test 9: Zero supply edge case
    function test_ZeroSupplyEdgeCase() public {
        // No liquidity supplied

        // Fast forward past the reward interval
        vm.warp(block.timestamp + defaultRewardInterval + 1 days);

        // Check eligibility with zero supply - should return false not revert
        assertFalse(LendefiInstance.isRewardable(alice), "Should not be eligible with zero supply");

        // Attempt to claim reward
        vm.prank(alice);
        uint256 claimedAmount = LendefiInstance.claimReward();
        assertEq(claimedAmount, 0, "Should receive zero reward with no supply");
    }

    // Test 10: Reward calculation accuracy
    function test_RewardCalculationAccuracy() public {
        uint256 supplyAmount = defaultRewardableSupply;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Fast forward exactly one reward interval
        vm.warp(block.timestamp + defaultRewardInterval);

        // Verify eligible
        assertTrue(LendefiInstance.isRewardable(alice), "Should be eligible after exact interval");

        // Claim reward
        vm.prank(alice);
        uint256 claimedAmount = LendefiInstance.claimReward();

        // Reward should be approximately the target amount
        assertApproxEqAbs(
            claimedAmount, defaultTargetReward, 0.01 ether, "Reward should be approximately the target amount"
        );
    }

    // Fuzz Test 1: Different supply amounts (with valid bounds)
    function testFuzz_DifferentSupplyAmounts(uint256 supplyAmount) public {
        // Bound to reasonable values (above minimum threshold, below max supply)
        supplyAmount = bound(supplyAmount, defaultRewardableSupply, 10 * defaultRewardableSupply);

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Fast forward past the reward interval
        vm.warp(block.timestamp + defaultRewardInterval + 1 days);

        // Claim reward
        vm.prank(alice);
        uint256 claimedAmount = LendefiInstance.claimReward();

        // Basic validations
        assertTrue(claimedAmount > 0, "Should receive rewards with sufficient supply");
    }

    // Fuzz Test 2: Different time periods (with valid bounds)
    function testFuzz_DifferentTimePeriods(uint256 timeElapsed) public {
        // Bound to reasonable values (above minimum interval but not extreme)
        timeElapsed = bound(timeElapsed, defaultRewardInterval, 2 * defaultRewardInterval);

        uint256 supplyAmount = defaultRewardableSupply * 2;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Fast forward by fuzzed time
        vm.warp(block.timestamp + timeElapsed);

        // Claim reward
        vm.prank(alice);
        uint256 claimedAmount = LendefiInstance.claimReward();

        // Reward should be positive
        assertTrue(claimedAmount > 0, "Should receive non-zero reward");
    }
}
