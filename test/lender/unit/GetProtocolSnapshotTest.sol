// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {LendefiView} from "../../../contracts/lender/LendefiView.sol";
import {MockRWA} from "../../../contracts/mock/MockRWA.sol";
import {RWAPriceConsumerV3} from "../../../contracts/mock/RWAOracle.sol";

contract GetProtocolSnapshotTest is BasicDeploy {
    MockRWA internal testToken;
    RWAPriceConsumerV3 internal testOracle;
    LendefiView internal viewInstance;

    // Test parameters for liquidity and borrowing
    uint256 constant SUPPLY_AMOUNT = 1_000_000e6; // 1M USDC
    uint256 constant BORROW_AMOUNT = 500_000e6; // 500K USDC

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy test token and oracle
        // Note: usdcInstance is already deployed by deployCompleteWithOracle()
        testToken = new MockRWA("Test Token", "TEST");
        testOracle = new RWAPriceConsumerV3();
        testOracle.setPrice(1000e8); // $1000 per token

        // Configure asset for testing - Changed from LendefiInstance to assetsInstance
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            address(testOracle),
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // borrow threshold (80%)
            850, // liquidation threshold (85%)
            10_000_000 ether, // max supply
            1_000_000e6, // isolation debt cap
            IASSETS.CollateralTier.CROSS_A, // Changed from IPROTOCOL to IASSETS
            IASSETS.OracleType.CHAINLINK
        );

        // Setup flash loan fee using the new config approach
        vm.startPrank(address(timelockInstance));
        // Register the test token with Oracle module

        assetsInstance.setPrimaryOracle(address(testToken), address(testOracle));

        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();
        config.flashLoanFee = 10; // 0.1% fee
        LendefiInstance.loadProtocolConfig(config);
        vm.stopPrank();

        // Deploy LendefiView
        viewInstance = new LendefiView(
            address(LendefiInstance), address(usdcInstance), address(yieldTokenInstance), address(ecoInstance)
        );
    }

    // Test 1: Snapshot reflects initial state - Update to use config
    function test_SnapshotReflectsInitialState() public {
        // Get initial protocol snapshot
        LendefiView.ProtocolSnapshot memory snapshot = viewInstance.getProtocolSnapshot();
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // Verify initial values
        assertEq(snapshot.utilization, 0, "Initial utilization should be 0");
        assertEq(snapshot.totalBorrow, 0, "Initial totalBorrow should be 0");
        assertEq(snapshot.totalSuppliedLiquidity, 0, "Initial totalSuppliedLiquidity should be 0");

        // Check config parameters match expectations
        assertEq(snapshot.flashLoanFee, config.flashLoanFee, "Flash loan fee mismatch");
        assertEq(snapshot.targetReward, config.rewardAmount, "targetReward mismatch");
        assertEq(snapshot.rewardInterval, config.rewardInterval, "rewardInterval mismatch");
        assertEq(snapshot.rewardableSupply, config.rewardableSupply, "rewardableSupply mismatch");
        assertEq(snapshot.baseProfitTarget, config.profitTargetRate, "baseProfitTarget mismatch");
        assertEq(snapshot.liquidatorThreshold, config.liquidatorThreshold, "liquidatorThreshold mismatch");
        assertEq(snapshot.borrowRate, config.borrowRate, "baseBorrowRate mismatch");
    }

    // Test 2: Snapshot reflects liquidity changes
    function test_SnapshotReflectsLiquidity() public {
        // Supply liquidity from Alice
        usdcInstance.mint(alice, SUPPLY_AMOUNT);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT);
        vm.stopPrank();

        // Get updated snapshot - Changed to use viewInstance
        LendefiView.ProtocolSnapshot memory snapshot = viewInstance.getProtocolSnapshot();

        // Verify liquidity is reflected
        assertEq(snapshot.totalSuppliedLiquidity, SUPPLY_AMOUNT, "totalSuppliedLiquidity should match supplied amount");
        assertEq(snapshot.utilization, 0, "Utilization should still be 0 with no borrowing");
    }

    // Test 3: Snapshot reflects borrowing
    function test_SnapshotReflectsBorrowing() public {
        // Supply liquidity first
        usdcInstance.mint(alice, SUPPLY_AMOUNT);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT);
        vm.stopPrank();

        // Setup borrowing
        uint256 collateralAmount = 1000 ether; // $1M worth at $1000 per token
        testToken.mint(bob, collateralAmount);

        // Make sure the oracle price is set correctly and recent
        testOracle.setPrice(1000e8); // $1000 per token

        vm.startPrank(bob);
        testToken.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.createPosition(address(testToken), false);
        LendefiInstance.supplyCollateral(address(testToken), collateralAmount, 0);

        // Try a more conservative borrow amount first
        uint256 adjustedBorrowAmount = 400_000e6; // 50% LTV rather than 80%
        LendefiInstance.borrow(0, adjustedBorrowAmount);
        vm.stopPrank();

        // Get updated snapshot - Changed to use viewInstance
        LendefiView.ProtocolSnapshot memory snapshot = viewInstance.getProtocolSnapshot();

        // Verify borrowing is reflected
        assertEq(snapshot.totalBorrow, adjustedBorrowAmount, "totalBorrow should match borrowed amount");
    }

    // Test 4: Snapshot reflects interest accrual
    function test_SnapshotReflectsTotalBorrow() public {
        // Supply liquidity first
        usdcInstance.mint(alice, SUPPLY_AMOUNT);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT);
        vm.stopPrank();

        // Setup borrowing with more conservative amount
        uint256 collateralAmount = 1000 ether; // $1M worth at $1000 per token
        uint256 borrowAmount = 400_000e6; // More conservative borrow

        testToken.mint(bob, collateralAmount);
        testOracle.setPrice(1000e8); // Ensure price is set

        vm.startPrank(bob);
        testToken.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.createPosition(address(testToken), false);
        LendefiInstance.supplyCollateral(address(testToken), collateralAmount, 0);
        LendefiInstance.borrow(0, borrowAmount);
        vm.stopPrank();

        // Get snapshot before time warp
        LendefiView.ProtocolSnapshot memory snapshotBefore = viewInstance.getProtocolSnapshot();

        // Fast forward time for interest to accrue
        vm.warp(block.timestamp + 365 days);

        // Calculate what the debt with interest is now
        uint256 debtWithInterest = LendefiInstance.calculateDebtWithInterest(bob, 0);
        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, 0);
        uint256 interestAccrued = debtWithInterest - position.debtAmount;

        console2.log("Initial debt:", borrowAmount);
        console2.log("Current debt with interest:", debtWithInterest);
        console2.log("Interest accrued:", interestAccrued);
        console2.log("Position debt amount:", position.debtAmount);

        // Verify interest is accruing properly
        assertGt(debtWithInterest, borrowAmount, "Interest should accrue over time");

        // Make a small repayment to realize interest (repay 10% of debt)
        uint256 repayAmount = debtWithInterest / 10;
        usdcInstance.mint(bob, repayAmount); // Mint the tokens needed

        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), repayAmount);
        LendefiInstance.repay(0, repayAmount);
        vm.stopPrank();

        // Now get updated snapshot after repayment
        LendefiView.ProtocolSnapshot memory snapshotAfter = viewInstance.getProtocolSnapshot();

        console2.log("Total borrow before:", snapshotBefore.totalBorrow);
        console2.log("Total borrow after:", snapshotAfter.totalBorrow);
        console2.log("Repay amount:", repayAmount);

        // In Lendefi's implementation, when you repay, the payment first goes to interest
        // and only then to principal. Since totalBorrow only reflects principal, we should see:
        // totalBorrow decreased by (repayAmount - interestAccrued), if repayAmount > interestAccrued
        // totalBorrow unchanged, if repayAmount <= interestAccrued

        if (repayAmount > interestAccrued) {
            uint256 expectedTotalBorrowAfterRepay = borrowAmount - (repayAmount - interestAccrued);
            assertEq(
                snapshotAfter.totalBorrow,
                expectedTotalBorrowAfterRepay,
                "totalBorrow should decrease by repayment minus interest"
            );
        } else {
            assertEq(
                snapshotAfter.totalBorrow,
                borrowAmount,
                "totalBorrow should remain unchanged when payment only covers interest"
            );
        }
    }

    // Test 5: Snapshot reflects repayments
    function test_SnapshotReflectsRepayment() public {
        // Supply liquidity first
        usdcInstance.mint(alice, SUPPLY_AMOUNT);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT);
        vm.stopPrank();

        // Setup borrowing
        uint256 collateralAmount = 1000 ether; // $1M worth at $1000 per token
        testToken.mint(bob, collateralAmount);

        vm.startPrank(bob);
        testToken.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.createPosition(address(testToken), false);
        LendefiInstance.supplyCollateral(address(testToken), collateralAmount, 0);
        LendefiInstance.borrow(0, BORROW_AMOUNT);

        // Get snapshot after borrowing - Changed to use viewInstance
        LendefiView.ProtocolSnapshot memory snapshotBeforeRepay = viewInstance.getProtocolSnapshot();

        // Repay half the loan
        usdcInstance.approve(address(LendefiInstance), BORROW_AMOUNT / 2);
        LendefiInstance.repay(0, BORROW_AMOUNT / 2);
        vm.stopPrank();

        // Get updated snapshot - Changed to use viewInstance
        LendefiView.ProtocolSnapshot memory snapshotAfterRepay = viewInstance.getProtocolSnapshot();

        // Verify repayment is reflected
        assertLt(
            snapshotAfterRepay.totalBorrow,
            snapshotBeforeRepay.totalBorrow,
            "totalBorrow should decrease after repayment"
        );
        assertLt(
            snapshotAfterRepay.utilization,
            snapshotBeforeRepay.utilization,
            "Utilization should decrease after repayment"
        );
    }

    // Test 6: Snapshot reflects flash loans
    function test_SnapshotReflectsFlashLoan() public {
        // Supply liquidity first
        usdcInstance.mint(alice, SUPPLY_AMOUNT);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT);
        vm.stopPrank();

        // Get snapshot before flash loan - Changed to use viewInstance
        LendefiView.ProtocolSnapshot memory snapshotBefore = viewInstance.getProtocolSnapshot();

        // Deploy flash loan receiver contract
        FlashLoanReceiver flashLoanReceiver = new FlashLoanReceiver(address(LendefiInstance), address(usdcInstance));

        // Calculate fee and provide enough tokens to cover it
        uint256 flashLoanAmount = 100_000e6;
        uint256 fee = (flashLoanAmount * 10) / 10000; // 0.1% fee

        // Mint fee amount plus a buffer
        usdcInstance.mint(address(flashLoanReceiver), fee + 1e6);

        // Execute flash loan through the receiver's function
        flashLoanReceiver.executeFlashLoan(flashLoanAmount);

        // Get updated snapshot - Changed to use viewInstance
        LendefiView.ProtocolSnapshot memory snapshotAfter = viewInstance.getProtocolSnapshot();

        // Flash loans should contribute to revenue, so totalSuppliedLiquidity might increase slightly
        assertGe(
            snapshotAfter.totalSuppliedLiquidity,
            snapshotBefore.totalSuppliedLiquidity,
            "totalSuppliedLiquidity should not decrease after flash loan"
        );
    }

    // Test 7: Snapshot reflects parameter updates
    function test_SnapshotReflectsParameterUpdates() public {
        // Define new parameter values
        uint256 newFlashLoanFee = 20; // 0.2%
        uint256 newBaseProfitTarget = 0.02e6; // 2%
        uint256 newRewardInterval = 90 days;
        uint256 newRewardableSupply = 200_000e6;
        uint256 newTargetReward = 2_000e18;
        uint256 newLiquidatorThreshold = 200e18;
        uint256 newBorrowRate = 0.08e6; // 8%

        vm.startPrank(address(timelockInstance));

        // Get current config
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // Update all parameters
        config.flashLoanFee = newFlashLoanFee;
        config.profitTargetRate = newBaseProfitTarget;
        config.rewardInterval = newRewardInterval;
        config.rewardableSupply = newRewardableSupply;
        config.rewardAmount = newTargetReward;
        config.liquidatorThreshold = newLiquidatorThreshold;
        config.borrowRate = newBorrowRate;

        // Update config with all new parameters
        LendefiInstance.loadProtocolConfig(config);

        vm.stopPrank();

        // Get updated snapshot
        LendefiView.ProtocolSnapshot memory updatedSnapshot = viewInstance.getProtocolSnapshot();

        // Verify parameter updates are reflected
        assertEq(updatedSnapshot.flashLoanFee, newFlashLoanFee, "Flash loan fee update not reflected");
        assertEq(updatedSnapshot.baseProfitTarget, newBaseProfitTarget, "Base profit target update not reflected");
        assertEq(updatedSnapshot.rewardInterval, newRewardInterval, "Reward interval update not reflected");
        assertEq(updatedSnapshot.rewardableSupply, newRewardableSupply, "Rewardable supply update not reflected");
        assertEq(updatedSnapshot.targetReward, newTargetReward, "Target reward update not reflected");
        assertEq(
            updatedSnapshot.liquidatorThreshold, newLiquidatorThreshold, "Liquidator threshold update not reflected"
        );
        assertEq(updatedSnapshot.borrowRate, newBorrowRate, "Base borrow rate update not reflected");
    }

    // Test 8: Snapshot reflects multiple user activities
    function test_SnapshotReflectsMultipleUserActivities() public {
        // Multiple users supply liquidity
        usdcInstance.mint(alice, SUPPLY_AMOUNT);
        usdcInstance.mint(bob, SUPPLY_AMOUNT / 2);

        vm.prank(alice);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT);
        vm.prank(alice);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT);

        vm.prank(bob);
        usdcInstance.approve(address(LendefiInstance), SUPPLY_AMOUNT / 2);
        vm.prank(bob);
        LendefiInstance.supplyLiquidity(SUPPLY_AMOUNT / 2);

        // Setup collateral for multiple borrowers
        uint256 collateralAmount = 1000 ether;
        testToken.mint(charlie, collateralAmount);
        testToken.mint(managerAdmin, collateralAmount / 2);

        // Charlie borrows
        vm.startPrank(charlie);
        testToken.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.createPosition(address(testToken), false);
        LendefiInstance.supplyCollateral(address(testToken), collateralAmount, 0);
        LendefiInstance.borrow(0, BORROW_AMOUNT / 2);
        vm.stopPrank();

        // managerAdmin borrows
        vm.startPrank(managerAdmin);
        testToken.approve(address(LendefiInstance), collateralAmount / 2);
        LendefiInstance.createPosition(address(testToken), false);
        LendefiInstance.supplyCollateral(address(testToken), collateralAmount / 2, 0);
        LendefiInstance.borrow(0, BORROW_AMOUNT / 4);
        vm.stopPrank();

        // Get snapshot after all activities - Changed to use viewInstance
        LendefiView.ProtocolSnapshot memory snapshot = viewInstance.getProtocolSnapshot();

        // Expected values
        uint256 expectedTotalSuppliedLiquidity = SUPPLY_AMOUNT + (SUPPLY_AMOUNT / 2);
        uint256 expectedTotalBorrow = (BORROW_AMOUNT / 2) + (BORROW_AMOUNT / 4);
        uint256 expectedUtilization = (expectedTotalBorrow * 1e6) / expectedTotalSuppliedLiquidity;

        // Verify snapshot reflects all activities
        assertEq(
            snapshot.totalSuppliedLiquidity,
            expectedTotalSuppliedLiquidity,
            "totalSuppliedLiquidity should reflect all liquidity supplies"
        );
        assertEq(snapshot.totalBorrow, expectedTotalBorrow, "totalBorrow should reflect all borrowing");
        assertEq(snapshot.utilization, expectedUtilization, "Utilization should reflect the combined borrow ratio");
    }
}

// Helper contract for flash loan tests
contract FlashLoanReceiver {
    Lendefi public lender;
    IERC20 public token;

    constructor(address _lender, address _token) {
        lender = Lendefi(_lender);
        token = IERC20(_token);
    }

    // AAVE-style flash loan callback (what Lendefi is actually calling)
    function executeOperation(
        address, /*asset*/
        uint256 amount,
        uint256 fee,
        address, /* initiator */
        bytes calldata /* params */
    ) external returns (bool) {
        // IMPORTANT: Actually transfer the tokens back, not just approve
        token.transfer(address(lender), amount + fee);
        return true; // Return true to indicate success
    }

    // Initiate flash loan
    function executeFlashLoan(uint256 amount) external {
        lender.flashLoan(address(this), amount, new bytes(0));
    }
}
