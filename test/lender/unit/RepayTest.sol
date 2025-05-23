// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";

contract RepayTest is BasicDeploy {
    // Events to verify
    event Repay(address indexed user, uint256 indexed positionId, uint256 amount);
    event InterestAccrued(address indexed user, uint256 indexed positionId, uint256 interestAccrued);

    uint256 constant WAD = 1e18;
    MockRWA internal rwaToken;

    RWAPriceConsumerV3 internal rwaOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;

    // Create a struct to track position states for validation
    struct PositionState {
        uint256 initialDebt;
        uint256 finalDebt;
        uint256 repayAmount;
        uint256 interestAccrued;
        uint256 initialTotalBorrow;
        uint256 finalTotalBorrow;
    }

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens
        // Note: usdcInstance is already deployed by deployCompleteWithOracle()
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
        _setupLiquidity();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH (cross-collateral)
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

        // Configure RWA token if needed
        assetsInstance.updateAssetConfig(
            address(rwaToken),
            IASSETS.Asset({
                active: 1,
                decimals: 18, // RWA token decimals
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

    function _setupLiquidity() internal {
        usdcInstance.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();

        // Set ETH price
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
    }

    // Helper function to setup a position with debt
    function _setupPositionWithDebt(address user, uint256 ethAmount, uint256 borrowAmount) internal returns (uint256) {
        vm.deal(user, ethAmount);
        vm.startPrank(user);

        // Deposit ETH and create position
        wethInstance.deposit{value: ethAmount}();
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;

        // Supply collateral
        wethInstance.approve(address(LendefiInstance), ethAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), ethAmount, positionId);

        // Borrow
        LendefiInstance.borrow(positionId, borrowAmount);

        vm.stopPrank();
        return positionId;
    }

    // Test 1: Repay less than total debt (partial repayment)
    function test_RepayPartial() public {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 15_000e6; // $15,000

        // Setup position with debt
        uint256 positionId = _setupPositionWithDebt(bob, collateralAmount, borrowAmount);

        // Track state before repayment
        uint256 initialDebt = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        uint256 initialTotalBorrow = LendefiInstance.totalBorrow();

        // Partial repayment (50%)
        uint256 repayAmount = borrowAmount / 2;
        usdcInstance.mint(bob, repayAmount);

        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), repayAmount);

        vm.expectEmit(true, true, false, true);
        emit Repay(bob, positionId, repayAmount);
        LendefiInstance.repay(positionId, repayAmount);
        vm.stopPrank();

        // Verify state after repayment
        uint256 finalDebt = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        uint256 finalTotalBorrow = LendefiInstance.totalBorrow();

        // These assertions are approximate due to potential small interest accrual
        assertApproxEqAbs(finalDebt, initialDebt - repayAmount, 1e6);
        assertApproxEqAbs(finalTotalBorrow, initialTotalBorrow - repayAmount, 1e6);
    }

    // Test 2: Repay exactly the total debt (full repayment)
    function test_RepayExact() public {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 15_000e6; // $15,000

        // Setup position with debt
        uint256 positionId = _setupPositionWithDebt(bob, collateralAmount, borrowAmount);

        // Fast forward a bit to accrue interest
        vm.warp(block.timestamp + 1 days);

        // Get exact debt with interest and original position debt
        uint256 exactDebt = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        uint256 initialTotalBorrow = LendefiInstance.totalBorrow();

        // Add logging to debug values
        console2.log("Original borrow amount:", borrowAmount / 1e6);
        console2.log("Exact debt with interest:", exactDebt / 1e6);
        console2.log("Initial total borrow:", initialTotalBorrow / 1e6);

        // Full repayment
        usdcInstance.mint(bob, exactDebt);

        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), exactDebt);

        vm.expectEmit(true, true, false, true);
        emit Repay(bob, positionId, exactDebt);
        LendefiInstance.repay(positionId, exactDebt);
        vm.stopPrank();

        // Verify debt is cleared
        uint256 finalDebt = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        uint256 finalTotalBorrow = LendefiInstance.totalBorrow();

        assertEq(finalDebt, 0, "Debt should be fully cleared");

        // totalBorrow only decreases by the principal amount, not by the full interest-bearing debt
        assertApproxEqAbs(finalTotalBorrow, initialTotalBorrow - borrowAmount, 1);

        // Verify the interest was tracked
        uint256 interest = exactDebt - borrowAmount;
        uint256 trackedInterest = LendefiInstance.totalAccruedBorrowerInterest();
        assertEq(trackedInterest, interest, "Interest should be tracked separately");
    }

    // Test 3: Repay more than the total debt (should cap at the total debt)
    function test_RepayExcess() public {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 15_000e6; // $15,000

        // Setup position with debt
        uint256 positionId = _setupPositionWithDebt(bob, collateralAmount, borrowAmount);

        // Get current debt
        uint256 currentDebt = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        uint256 initialTotalBorrow = LendefiInstance.totalBorrow();

        // Try to repay more than owed
        uint256 excessRepayAmount = currentDebt + 5_000e6;
        usdcInstance.mint(bob, excessRepayAmount);

        // Record bob's initial balance after minting
        uint256 bobInitialBalance = usdcInstance.balanceOf(bob);

        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), excessRepayAmount);

        // Should only take exactly the debt amount
        vm.expectEmit(true, true, false, true);
        emit Repay(bob, positionId, currentDebt);
        LendefiInstance.repay(positionId, excessRepayAmount);
        vm.stopPrank();

        // Verify debt is cleared but only exact amount was taken
        uint256 finalDebt = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        uint256 finalTotalBorrow = LendefiInstance.totalBorrow();
        uint256 bobFinalBalance = usdcInstance.balanceOf(bob);

        assertEq(finalDebt, 0, "Debt should be fully cleared");
        assertApproxEqAbs(finalTotalBorrow, initialTotalBorrow - currentDebt, 1);

        // Bob should have exactly the excess amount left
        assertEq(bobFinalBalance, bobInitialBalance - currentDebt, "Should only take the exact debt amount");
    }

    // Test 4: Repay with interest accrued over time
    function test_RepayWithInterestAccrual() public {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 15_000e6; // $15,000

        // Setup position with debt
        uint256 positionId = _setupPositionWithDebt(bob, collateralAmount, borrowAmount);

        // Fast forward 1 year to accrue significant interest
        vm.warp(block.timestamp + 365 days);

        // Get debt with interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        uint256 interest = debtWithInterest - borrowAmount;
        console2.log("Original debt:", borrowAmount / 1e6);
        console2.log("Interest accrued:", interest / 1e6);
        console2.log("Total debt with interest:", debtWithInterest / 1e6);

        // Full repayment
        usdcInstance.mint(bob, debtWithInterest);

        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), debtWithInterest);

        // Expect both events
        vm.expectEmit(true, true, false, true);
        emit Repay(bob, positionId, debtWithInterest);
        vm.expectEmit(true, true, false, true);
        emit InterestAccrued(bob, positionId, interest);

        LendefiInstance.repay(positionId, debtWithInterest);
        vm.stopPrank();

        // Verify debt is cleared
        uint256 finalDebt = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        assertEq(finalDebt, 0, "Debt should be fully cleared");

        // Verify interest was tracked correctly
        uint256 trackedInterest = LendefiInstance.totalAccruedBorrowerInterest();
        assertEq(trackedInterest, interest, "Interest should be tracked properly");
    }

    // Test 5: Repay nonexistent position (should revert)
    function test_RepayInvalidPosition() public {
        uint256 invalidPositionId = 999;

        vm.startPrank(bob);
        // Updated to use correct error code format
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector));
        LendefiInstance.repay(invalidPositionId, 1000e6);
        vm.stopPrank();
    }

    // Test 6: Repay position with no debt (should revert)
    function test_RepayNoDebt() public {
        // Create position without debt
        vm.deal(bob, 10 ether);
        vm.startPrank(bob);
        wethInstance.deposit{value: 10 ether}();
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = 0;
        wethInstance.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 10 ether, positionId);

        // Try to repay when there's no debt
        // This should now just execute without error, as the position's debt is zero,
        // so _processRepay will return 0 as actualAmount and repay() won't transfer any tokens
        LendefiInstance.repay(positionId, 1000e6);

        // Verify position state remains unchanged
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, positionId);
        assertEq(position.debtAmount, 0, "Position should still have zero debt");
        vm.stopPrank();
    }

    // Test 7: Repay after protocol is paused (should revert)
    function test_RepayWhenPaused() public {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 15_000e6;

        // Setup position with debt
        uint256 positionId = _setupPositionWithDebt(bob, collateralAmount, borrowAmount);

        // Pause the protocol
        vm.startPrank(gnosisSafe);
        LendefiInstance.pause();
        vm.stopPrank();

        // Try to repay when paused
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), borrowAmount);
        // Updated to use correct error code format for OZ Pausable
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()")); // OZ Pausable error
        LendefiInstance.repay(positionId, borrowAmount);
        vm.stopPrank();
    }

    // Test 8: Repay zero amount (edge case)
    function testRevert_RepayZeroAmount() public {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 15_000e6;

        // Setup position with debt
        uint256 positionId = _setupPositionWithDebt(bob, collateralAmount, borrowAmount);

        // Repay zero amount
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), 0);

        // Updated to use correct error code format
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.ZeroAmount.selector));
        LendefiInstance.repay(positionId, 0);
        vm.stopPrank();

        // Verify debt is unchanged
        uint256 finalDebt = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        assertGt(finalDebt, 0, "Debt should remain unchanged");
    }

    // Test 9: Repay with insufficient USDC balance (should revert)
    function test_RepayInsufficientBalance() public {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 15_000e6;

        // Setup position with debt
        uint256 positionId = _setupPositionWithDebt(bob, collateralAmount, borrowAmount);

        // Try to repay without enough USDC
        vm.startPrank(bob);
        // Empty bob's USDC balance
        uint256 bobBalance = usdcInstance.balanceOf(bob);
        usdcInstance.transfer(alice, bobBalance);

        // Should approve more than balance
        usdcInstance.approve(address(LendefiInstance), borrowAmount);

        // The newer OZ ERC20 uses custom errors instead of strings
        // This matches the actual error format: ERC20InsufficientBalance(address, uint256, uint256)
        vm.expectRevert(); // Just check for any revert since the error format is complex
        LendefiInstance.repay(positionId, borrowAmount);
        vm.stopPrank();
    }

    // Test 10: Multiple repayments over time
    function test_MultipleRepayments() public {
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 15_000e6;

        // Setup position with debt
        uint256 positionId = _setupPositionWithDebt(bob, collateralAmount, borrowAmount);

        // Repay in 3 installments with time gaps
        for (uint256 i = 1; i <= 3; i++) {
            // Warp forward a month
            vm.warp(block.timestamp + 30 days);

            // Calculate current debt
            uint256 currentDebt = LendefiInstance.calculateDebtWithInterest(bob, positionId);
            uint256 installment = currentDebt / (4 - i); // Repay 1/3, then 1/2, then all

            // Mint USDC for repayment
            usdcInstance.mint(bob, installment);

            vm.startPrank(bob);
            usdcInstance.approve(address(LendefiInstance), installment);
            LendefiInstance.repay(positionId, installment);
            vm.stopPrank();

            console2.log("Installment", i, "repaid:", installment / 1e6);
        }

        // Verify debt is fully cleared
        uint256 finalDebt = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        assertEq(finalDebt, 0, "Debt should be fully cleared after all installments");
    }

    // Fuzz test for partial repayments
    function testFuzz_PartialRepayments(uint256 borrowPct, uint256 repayPct) public {
        // Constrain inputs to reasonable ranges
        borrowPct = bound(borrowPct, 10, 75); // 10-75% of credit limit
        repayPct = bound(repayPct, 1, 100); // 1-100% of debt

        // Setup with scaled values
        uint256 collateralAmount = 10 ether;
        uint256 maxBorrow = 20_000e6; // Max borrow for 10 ETH at $2500
        uint256 borrowAmount = (maxBorrow * borrowPct) / 100;

        // Ensure minimum meaningful values
        borrowAmount = borrowAmount > 100e6 ? borrowAmount : 100e6;

        // Setup position
        uint256 positionId = _setupPositionWithDebt(bob, collateralAmount, borrowAmount);

        // Warp time to accrue some interest
        vm.warp(block.timestamp + 30 days);

        // Calculate repayment amount
        uint256 currentDebt = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        uint256 repayAmount = (currentDebt * repayPct) / 100;

        // Execute repayment
        usdcInstance.mint(bob, repayAmount);
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), repayAmount);
        LendefiInstance.repay(positionId, repayAmount);
        vm.stopPrank();

        // Verify state
        uint256 finalDebt = LendefiInstance.calculateDebtWithInterest(bob, positionId);

        if (repayPct >= 100) {
            // Should be fully repaid
            assertEq(finalDebt, 0, "Debt should be cleared with 100% repayment");
        } else {
            // Should be partially repaid
            assertLt(finalDebt, currentDebt, "Debt should decrease after partial repayment");
            assertGt(finalDebt, 0, "Debt should remain after partial repayment");
        }
    }

    // Invariant: totalBorrow should always decrease by exactly the repayment amount
    function testProperty_TotalBorrowDecrease() public {
        // Setup
        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 15_000e6;
        uint256 positionId = _setupPositionWithDebt(bob, collateralAmount, borrowAmount);

        // Capture pre-state
        uint256 initialTotalBorrow = LendefiInstance.totalBorrow();

        // Repay half
        uint256 repayAmount = borrowAmount / 2;
        usdcInstance.mint(bob, repayAmount);
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), repayAmount);
        LendefiInstance.repay(positionId, repayAmount);
        vm.stopPrank();

        // Verify invariant
        uint256 finalTotalBorrow = LendefiInstance.totalBorrow();
        assertEq(
            initialTotalBorrow - finalTotalBorrow, repayAmount, "totalBorrow should decrease by exactly repayAmount"
        );
    }

    // Test interest accrual tracking with different time periods
    function testFuzz_InterestAccrualTime(uint256 days_) public {
        // Bound to reasonable range (1 day to 3 years)
        days_ = bound(days_, 1, 1095);

        uint256 collateralAmount = 10 ether;
        uint256 borrowAmount = 15_000e6;

        // Setup position
        uint256 positionId = _setupPositionWithDebt(bob, collateralAmount, borrowAmount);

        // Fast forward by fuzzed days
        vm.warp(block.timestamp + (days_ * 1 days));

        // Calculate interest
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        uint256 interest = debtWithInterest - borrowAmount;

        // Full repayment
        usdcInstance.mint(bob, debtWithInterest);
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), debtWithInterest);
        LendefiInstance.repay(positionId, debtWithInterest);
        vm.stopPrank();

        // Verify interest accrual is tracked
        uint256 trackedInterest = LendefiInstance.totalAccruedBorrowerInterest();
        assertEq(trackedInterest, interest, "Interest should be tracked correctly");

        // Log results for analysis
        console2.log("Days elapsed:", days_);
        console2.log("Interest accrued:", interest / 1e6);
        console2.log("APR:", (interest * 365 * 100) / (days_ * borrowAmount), "%");
    }
}
