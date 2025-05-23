// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {RWAPriceConsumerV3} from "../../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";

contract ExchangeTest is BasicDeploy {
    // Events to verify
    event Exchange(address indexed user, uint256 amount, uint256 value);
    event SupplyLiquidity(address indexed user, uint256 amount);
    event Reward(address indexed user, uint256 amount);

    MockRWA internal rwaToken;
    RWAPriceConsumerV3 internal rwaOracleInstance;
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

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token

        // Setup roles
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
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
                maxSupplyThreshold: 1_000_000 ether, // Supply limit
                isolationDebtCap: 0, // No isolation debt cap for cross assets
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

        // Configure RWA token as ISOLATED tier
        assetsInstance.updateAssetConfig(
            address(rwaToken),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 650, // 65% borrow threshold
                liquidationThreshold: 750, // 75% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether, // Supply limit
                isolationDebtCap: 100_000e6, // Isolation debt cap of 100,000 USDC
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.ISOLATED,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(rwaOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

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

    // Helper function to generate protocol profit
    function _generateProfit(uint256 amount) internal {
        usdcInstance.mint(address(LendefiInstance), amount);
    }

    // Test 1: Basic exchange functionality
    function test_BasicExchange() public {
        uint256 supplyAmount = 10_000e6;
        uint256 exchangeAmount = 5_000e6;

        // First supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Capture initial state
        uint256 initialAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 initialAliceTokens = yieldTokenInstance.balanceOf(alice);
        uint256 initialProtocolUsdcBalance = usdcInstance.balanceOf(address(LendefiInstance));
        uint256 initialtotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();
        uint256 initialTotalSupply = yieldTokenInstance.totalSupply();

        // Calculate expected values
        uint256 expectedtotalSuppliedLiquidity =
            initialtotalSuppliedLiquidity - (exchangeAmount * initialtotalSuppliedLiquidity) / initialTotalSupply;
        uint256 expectedUsdcReceived = (exchangeAmount * initialProtocolUsdcBalance) / initialTotalSupply;

        vm.startPrank(alice);

        // Expect Exchange event
        vm.expectEmit(true, false, false, true);
        emit Exchange(alice, exchangeAmount, expectedUsdcReceived);

        // Exchange tokens
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();

        // Verify state changes
        uint256 finalAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 finalAliceTokens = yieldTokenInstance.balanceOf(alice);
        uint256 finalProtocolUsdcBalance = usdcInstance.balanceOf(address(LendefiInstance));
        uint256 finaltotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();

        assertEq(
            finalAliceTokens, initialAliceTokens - exchangeAmount, "Token balance should decrease by exchanged amount"
        );
        assertEq(finalAliceUsdcBalance, initialAliceUsdcBalance + expectedUsdcReceived, "USDC balance should increase");
        assertEq(
            finalProtocolUsdcBalance, initialProtocolUsdcBalance - expectedUsdcReceived, "Protocol USDC should decrease"
        );
        assertApproxEqAbs(
            finaltotalSuppliedLiquidity, expectedtotalSuppliedLiquidity, 1, "Total base should decrease proportionally"
        );
    }

    // Test 2: Exchange with insufficient balance
    function test_ExchangeInsufficientBalance() public {
        uint256 supplyAmount = 5_000e6;
        uint256 exchangeAmount = 10_000e6; // More than supplied

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        vm.startPrank(alice);
        // Attempt to exchange more than balance
        // UPDATED: Expect arithmetic underflow panic error instead of custom error code
        vm.expectRevert(stdError.arithmeticError); // Arithmetic underflow or overflow (0x11)
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();
    }

    // Test 3: Exchange entire balance
    function test_ExchangeEntireBalance() public {
        uint256 supplyAmount = 10_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Capture initial state
        uint256 initialAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 initialAliceTokens = yieldTokenInstance.balanceOf(alice);
        uint256 initialProtocolUsdcBalance = usdcInstance.balanceOf(address(LendefiInstance));

        vm.startPrank(alice);
        // Exchange entire balance
        LendefiInstance.exchange(initialAliceTokens);
        vm.stopPrank();

        // Verify state changes
        uint256 finalAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 finalAliceTokens = yieldTokenInstance.balanceOf(alice);

        assertEq(finalAliceTokens, 0, "Token balance should be zero after exchanging entire balance");
        assertTrue(finalAliceUsdcBalance > initialAliceUsdcBalance, "USDC balance should increase");
        assertTrue(
            usdcInstance.balanceOf(address(LendefiInstance)) < initialProtocolUsdcBalance,
            "Protocol USDC should decrease"
        );
    }

    // Test 4: Exchange with fees (when protocol has profit)
    function test_ExchangeWithFees() public {
        uint256 supplyAmount = 10_000e6;
        uint256 profitAmount = 1_000e6; // 10% profit
        uint256 exchangeAmount = 5_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Generate profit for the protocol
        _generateProfit(profitAmount);

        // Capture initial state
        uint256 initialTreasuryTokens = yieldTokenInstance.balanceOf(address(treasuryInstance));

        vm.startPrank(alice);
        // Exchange tokens
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();

        // Verify fee was charged
        uint256 finalTreasuryTokens = yieldTokenInstance.balanceOf(address(treasuryInstance));
        assertTrue(finalTreasuryTokens > initialTreasuryTokens, "Treasury should receive fee tokens");
    }

    // Test 5: Exchange without fees (when protocol doesn't have enough profit)
    function test_ExchangeWithoutFees() public {
        uint256 supplyAmount = 10_000e6;
        uint256 exchangeAmount = 5_000e6;

        // Supply liquidity (no profit generated)
        _supplyLiquidity(alice, supplyAmount);

        // Capture initial state
        uint256 initialTreasuryTokens = yieldTokenInstance.balanceOf(address(treasuryInstance));

        vm.startPrank(alice);
        // Exchange tokens
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();

        // Verify no fee was charged
        uint256 finalTreasuryTokens = yieldTokenInstance.balanceOf(address(treasuryInstance));
        assertEq(finalTreasuryTokens, initialTreasuryTokens, "Treasury should not receive fee tokens");
    }

    // Test 6: Exchange when paused
    function test_ExchangeWhenPaused() public {
        uint256 supplyAmount = 10_000e6;
        uint256 exchangeAmount = 5_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Pause protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        vm.startPrank(alice);
        // Attempt to exchange when paused - Keep OZ error since it's from Pausable
        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();
    }

    // Test 7: Exchange with zero amount
    // Update from test_ExchangeZeroAmount to testRevert_ExchangeZeroAmount
    function testRevert_ExchangeZeroAmount() public {
        uint256 supplyAmount = 10_000e6;
        uint256 exchangeAmount = 0;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        vm.startPrank(alice);
        // Exchange zero tokens should now revert with "ZA" error
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.ZeroAmount.selector));
        LendefiInstance.exchange(exchangeAmount);
        vm.stopPrank();

        // No need for assertions because the call will revert
        // (Still checking state remains unchanged after revert)
        uint256 aliceTokens = yieldTokenInstance.balanceOf(alice);
        assertEq(aliceTokens, supplyAmount, "Token balance should remain unchanged");
    }

    // Test 8: Multiple exchanges from same user
    function test_MultipleExchanges() public {
        uint256 supplyAmount = 10_000e6;
        uint256 firstExchange = 3_000e6;
        uint256 secondExchange = 2_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // First exchange
        vm.startPrank(alice);
        LendefiInstance.exchange(firstExchange);
        uint256 tokensAfterFirst = yieldTokenInstance.balanceOf(alice);

        // Second exchange
        LendefiInstance.exchange(secondExchange);
        uint256 tokensAfterSecond = yieldTokenInstance.balanceOf(alice);
        vm.stopPrank();

        // Verify tokens decreased correctly
        assertEq(tokensAfterFirst, supplyAmount - firstExchange, "Token balance after first exchange is incorrect");
        assertEq(
            tokensAfterSecond,
            supplyAmount - firstExchange - secondExchange,
            "Token balance after second exchange is incorrect"
        );
    }

    // Test 9: Multiple users exchanging
    function test_MultipleUsersExchanging() public {
        uint256 aliceSupply = 10_000e6;
        uint256 bobSupply = 20_000e6;
        uint256 aliceExchange = 5_000e6;
        uint256 bobExchange = 10_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, aliceSupply);
        _supplyLiquidity(bob, bobSupply);

        // Capture initial state
        uint256 initialAliceTokens = yieldTokenInstance.balanceOf(alice);
        uint256 initialBobTokens = yieldTokenInstance.balanceOf(bob);
        uint256 initialtotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();

        // Alice exchanges
        vm.prank(alice);
        LendefiInstance.exchange(aliceExchange);

        // Bob exchanges
        vm.prank(bob);
        LendefiInstance.exchange(bobExchange);

        // Verify state changes
        uint256 finalAliceTokens = yieldTokenInstance.balanceOf(alice);
        uint256 finalBobTokens = yieldTokenInstance.balanceOf(bob);
        uint256 finaltotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();

        assertEq(
            finalAliceTokens, initialAliceTokens - aliceExchange, "Alice's token balance should decrease correctly"
        );
        assertEq(finalBobTokens, initialBobTokens - bobExchange, "Bob's token balance should decrease correctly");
        assertTrue(
            finaltotalSuppliedLiquidity < initialtotalSuppliedLiquidity, "Total base should decrease after exchanges"
        );
    }

    // Test 10: Exchange with large amounts
    function test_ExchangeLargeAmount() public {
        uint256 largeSupply = 1_000_000_000e6; // 1 billion USDC

        // Supply large amount
        _supplyLiquidity(alice, largeSupply);

        vm.startPrank(alice);
        // Exchange large amount
        LendefiInstance.exchange(largeSupply);
        vm.stopPrank();

        // Verify state
        uint256 aliceTokens = yieldTokenInstance.balanceOf(alice);
        assertEq(aliceTokens, 0, "Alice should have zero tokens after exchange");
        assertApproxEqAbs(
            usdcInstance.balanceOf(alice),
            largeSupply,
            100,
            "Alice should receive approximately the supplied amount back"
        );
    }

    // Test 11: End-to-end exchange with real interest
    function test_ExchangeWithRealInterest() public {
        uint256 supplyAmount = 100_000e6;
        uint256 collateralAmount = 50 ether;
        uint256 borrowAmount = 50_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Setup collateral and borrow to generate interest
        vm.deal(bob, collateralAmount);
        vm.startPrank(bob);
        wethInstance.deposit{value: collateralAmount}();
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.createPosition(address(wethInstance), false);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, 0);
        LendefiInstance.borrow(0, borrowAmount);
        vm.stopPrank();

        // Fast forward time to accrue interest
        vm.warp(block.timestamp + 730 days);
        // Repay loan with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(bob, 0);
        usdcInstance.mint(bob, debtWithInterest * 2); // Give enough to repay
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), debtWithInterest);
        LendefiInstance.repay(0, debtWithInterest);
        vm.stopPrank();

        // Verify loan is repaid
        assertEq(LendefiInstance.totalBorrow(), 0, "Total borrow should be zero");

        // Get expected exchange value using supply rate
        vm.startPrank(alice);
        uint256 aliceTokens = yieldTokenInstance.balanceOf(alice);

        // Exchange tokens
        uint256 supplyRate = LendefiInstance.getSupplyRate();
        LendefiInstance.exchange(aliceTokens);
        vm.stopPrank();

        uint256 balanceAfter = usdcInstance.balanceOf(alice);
        uint256 expBal = 100_000e6 + (100_000e6 * supplyRate) / 1e6;
        assertEq(balanceAfter / 1e6, expBal / 1e6);
    }

    // Test 12: Exchange slightly more than balance should use exact balance
    function test_ExchangeExactBalance() public {
        uint256 supplyAmount = 10_000e6;

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount);

        // Capture initial state
        uint256 initialAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 initialtotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();
        uint256 initialAliceTokens = yieldTokenInstance.balanceOf(alice);

        vm.startPrank(alice);
        // This should work, using alice's exact balance
        LendefiInstance.exchange(supplyAmount); // Using exact amount
        vm.stopPrank();

        // Verify state changes
        uint256 finalAliceUsdcBalance = usdcInstance.balanceOf(alice);
        uint256 finalAliceTokens = yieldTokenInstance.balanceOf(alice);
        uint256 finaltotalSuppliedLiquidity = LendefiInstance.totalSuppliedLiquidity();

        assertEq(finalAliceTokens, 0, "Token balance should be zero");
        assertTrue(finalAliceUsdcBalance > initialAliceUsdcBalance, "USDC balance should increase");
        assertTrue(finaltotalSuppliedLiquidity < initialtotalSuppliedLiquidity, "Total base should decrease");

        // Verify entire balance was used
        assertEq(initialAliceTokens, supplyAmount, "Initial balance should match supply");
    }

    // Fuzz Test 13: Exchange random amounts
    function testFuzz_ExchangeRandomAmount(uint256 amount) public {
        // Bound to reasonable values
        uint256 supplyAmount = 100_000e6;
        amount = bound(amount, 1e6, supplyAmount); // 1 to full supply amount

        // Supply liquidity first
        _supplyLiquidity(alice, supplyAmount);

        vm.startPrank(alice);
        // Exchange random amount
        LendefiInstance.exchange(amount);
        vm.stopPrank();

        // Verify basic state
        uint256 aliceTokens = yieldTokenInstance.balanceOf(alice);
        assertEq(aliceTokens, supplyAmount - amount, "Token balance should decrease by exchanged amount");
    }

    // Fuzz Test 14: Multiple users with random exchange amounts
    function testFuzz_MultipleUsersRandomExchanges(uint256 amount1, uint256 amount2) public {
        // Bound to reasonable values
        uint256 supplyAmount1 = 100_000e6;
        uint256 supplyAmount2 = 200_000e6;
        amount1 = bound(amount1, 1e6, supplyAmount1);
        amount2 = bound(amount2, 1e6, supplyAmount2);

        // Supply liquidity
        _supplyLiquidity(alice, supplyAmount1);
        _supplyLiquidity(bob, supplyAmount2);

        // Alice exchanges
        vm.prank(alice);
        LendefiInstance.exchange(amount1);

        // Bob exchanges
        vm.prank(bob);
        LendefiInstance.exchange(amount2);

        // Verify balances
        assertEq(yieldTokenInstance.balanceOf(alice), supplyAmount1 - amount1, "Alice's token balance incorrect");
        assertEq(yieldTokenInstance.balanceOf(bob), supplyAmount2 - amount2, "Bob's token balance incorrect");
    }
}
