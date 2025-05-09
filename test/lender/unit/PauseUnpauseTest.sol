// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IFlashLoanReceiver} from "../../../contracts/interfaces/IFlashLoanReceiver.sol";
import {RWAPriceConsumerV3} from "../../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {IERC20, SafeERC20 as TH} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract PauseUnpauseTest is BasicDeploy {
    // Events to verify
    event Paused(address account);
    event Unpaused(address account);

    MockRWA internal rwaToken;
    RWAPriceConsumerV3 internal rwaOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;
    MockFlashLoanReceiver internal flashLoanReceiver;

    // Test variables
    uint256 internal positionId;
    uint256 internal collateralAmount = 10 ether;
    uint256 internal borrowAmount = 1000e6; // 1000 USDC

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle)
        wethInstance = new WETH9();
        rwaToken = new MockRWA("Ondo Finance", "ONDO");
        // Deploy flash loan receiver
        flashLoanReceiver = new MockFlashLoanReceiver();
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
        _setupTestPosition();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier
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
                decimals: 18, // Asset decimals
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
        // Provide liquidity to the protocol
        usdcInstance.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    function _setupTestPosition() internal {
        // Create a position for testing functions when paused
        vm.startPrank(bob);
        LendefiInstance.createPosition(address(wethInstance), false);
        positionId = 0;

        // Supply collateral
        vm.deal(bob, collateralAmount);
        wethInstance.deposit{value: collateralAmount}();
        wethInstance.approve(address(LendefiInstance), collateralAmount);
        LendefiInstance.supplyCollateral(address(wethInstance), collateralAmount, positionId);

        // Borrow
        LendefiInstance.borrow(positionId, borrowAmount);
        vm.stopPrank();
    }

    /* ------------------------------- */
    /* Permission Tests                */
    /* ------------------------------- */

    // Test 1: Pauser can pause
    function test_PauserCanPause() public {
        // Expect Paused event
        vm.expectEmit(true, false, false, false);
        emit Paused(gnosisSafe);
        vm.prank(gnosisSafe);
        LendefiInstance.pause();
        // Verify paused state
        assertTrue(LendefiInstance.paused(), "Contract should be paused");
    }

    // Test 2: Pauser can unpause
    function test_PauserCanUnpause() public {
        // First pause
        vm.startPrank(gnosisSafe);
        LendefiInstance.pause();
        assertTrue(LendefiInstance.paused(), "Contract should be paused");

        // Expect Unpaused event
        vm.expectEmit(true, false, false, false);
        emit Unpaused(gnosisSafe);

        LendefiInstance.unpause();
        vm.stopPrank();

        // Verify unpaused state
        assertFalse(LendefiInstance.paused(), "Contract should be unpaused");
    }

    // Test 3: Non-guardian cannot pause
    function test_NonGuardianCannotPause() public {
        vm.startPrank(bob);

        // Expect access control error
        bytes memory expectedError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, PAUSER_ROLE);
        vm.expectRevert(expectedError);

        LendefiInstance.pause();
        vm.stopPrank();

        // Verify not paused
        assertFalse(LendefiInstance.paused(), "Contract should remain unpaused");
    }

    // Test 4: Non-guardian cannot unpause
    function test_NonGuardianCannotUnpause() public {
        // First pause
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        vm.startPrank(bob);

        // Expect access control error
        bytes memory expectedError =
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", bob, PAUSER_ROLE);
        vm.expectRevert(expectedError);

        LendefiInstance.unpause();
        vm.stopPrank();

        // Verify still paused
        assertTrue(LendefiInstance.paused(), "Contract should remain paused");
    }

    // Test 5: Cannot pause when already paused
    function test_CannotPauseWhenAlreadyPaused() public {
        vm.startPrank(gnosisSafe);
        LendefiInstance.pause();

        // Expect error for already paused
        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);

        LendefiInstance.pause();
        vm.stopPrank();
    }

    // Test 6: Cannot unpause when already unpaused
    function test_CannotUnpauseWhenAlreadyUnpaused() public {
        vm.startPrank(gnosisSafe);

        // Expect error for already unpaused
        bytes memory expectedError = abi.encodeWithSignature("ExpectedPause()");
        vm.expectRevert(expectedError);

        LendefiInstance.unpause();
        vm.stopPrank();
    }

    /* ------------------------------- */
    /* Functionality Tests             */
    /* ------------------------------- */

    // Test 7: supplyCollateral fails when paused
    function test_SupplyCollateralFailsWhenPaused() public {
        // Pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        // Try to supply collateral
        vm.startPrank(bob);
        vm.deal(bob, 1 ether);
        wethInstance.deposit{value: 1 ether}();
        wethInstance.approve(address(LendefiInstance), 1 ether);

        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);

        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, positionId);
        vm.stopPrank();
    }

    // Test 8: withdrawCollateral fails when paused
    function test_WithdrawCollateralFailsWhenPaused() public {
        // Pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        // Try to withdraw collateral
        vm.startPrank(bob);

        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);

        LendefiInstance.withdrawCollateral(address(wethInstance), 1 ether, positionId);
        vm.stopPrank();
    }

    // Test 9: createPosition fails when paused
    function test_CreatePositionFailsWhenPaused() public {
        // Pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        // Try to create a position
        vm.startPrank(bob);

        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);

        LendefiInstance.createPosition(address(wethInstance), false);
        vm.stopPrank();
    }

    // Test 10: borrow fails when paused
    function test_BorrowFailsWhenPaused() public {
        // Pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        // Try to borrow
        vm.startPrank(bob);

        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);

        LendefiInstance.borrow(positionId, 100e6);
        vm.stopPrank();
    }

    // Test 11: repay fails when paused
    function test_RepayFailsWhenPaused() public {
        // Pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        // Try to repay
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), 100e6);

        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);

        LendefiInstance.repay(positionId, 100e6);
        vm.stopPrank();
    }

    // Test 12: exitPosition fails when paused
    function test_ExitPositionFailsWhenPaused() public {
        // Pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        // Try to exit position
        vm.startPrank(bob);

        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);

        LendefiInstance.exitPosition(positionId);
        vm.stopPrank();
    }

    // Test 13: liquidate fails when paused
    function test_LiquidateFailsWhenPaused() public {
        // First give charlie enough gov tokens
        vm.prank(address(timelockInstance));
        treasuryInstance.release(address(tokenInstance), charlie, 50_000 ether);

        // Mint USDC for liquidation
        usdcInstance.mint(charlie, 10_000e6);

        // Pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        // Try to liquidate
        vm.startPrank(charlie);
        usdcInstance.approve(address(LendefiInstance), 10_000e6);

        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);

        LendefiInstance.liquidate(bob, positionId);
        vm.stopPrank();
    }

    // Test 14: flashLoan fails when paused
    function test_FlashLoanFailsWhenPaused() public {
        // Pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        // Try to use flash loan
        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");
        vm.expectRevert(expectedError);

        LendefiInstance.flashLoan(address(flashLoanReceiver), 1000e6, "");
    }

    // Test 16: functionality works after unpause
    function test_FunctionalityRestoredAfterUnpause() public {
        // Pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        // Now unpause
        vm.prank(gnosisSafe);
        LendefiInstance.unpause();

        // Try operations after unpausing
        vm.startPrank(bob);

        // Create new position should work
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 newPositionId = 1;

        // Supply collateral should work
        vm.deal(bob, 1 ether);
        wethInstance.deposit{value: 1 ether}();
        wethInstance.approve(address(LendefiInstance), 1 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, newPositionId);

        // Borrow should work
        LendefiInstance.borrow(newPositionId, 100e6);

        vm.stopPrank();

        // Verify operations were successful
        assertEq(LendefiInstance.getUserPositionsCount(bob), 2, "Should have 2 positions");
        assertEq(
            LendefiInstance.getCollateralAmount(bob, newPositionId, address(wethInstance)),
            1 ether,
            "Collateral should be 1 ether"
        );

        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, newPositionId);
        assertEq(position.debtAmount, 100e6, "Debt should be 100 USDC");
    }

    // Test 17: pause blocks all pausable functions, unpause enables all
    function test_ComprehensivePauseUnpauseEffects() public {
        // Add USDC for repayment
        usdcInstance.mint(bob, 1000e6);

        // First verify all functions work before pausing
        vm.startPrank(bob);

        // Create position
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 newPositionId = 1;

        // Supply collateral
        vm.deal(bob, 1 ether);
        wethInstance.deposit{value: 1 ether}();
        wethInstance.approve(address(LendefiInstance), 1 ether);
        LendefiInstance.supplyCollateral(address(wethInstance), 1 ether, newPositionId);

        // Borrow
        LendefiInstance.borrow(newPositionId, 100e6);

        // Repay
        usdcInstance.approve(address(LendefiInstance), 50e6);
        LendefiInstance.repay(newPositionId, 50e6);
        vm.stopPrank();

        // Now pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        // Try each function - all should fail
        vm.startPrank(bob);
        bytes memory expectedError = abi.encodeWithSignature("EnforcedPause()");

        vm.expectRevert(expectedError);
        LendefiInstance.createPosition(address(wethInstance), false);

        vm.expectRevert(expectedError);
        LendefiInstance.supplyCollateral(address(wethInstance), 0.1 ether, newPositionId);

        vm.expectRevert(expectedError);
        LendefiInstance.withdrawCollateral(address(wethInstance), 0.1 ether, newPositionId);

        vm.expectRevert(expectedError);
        LendefiInstance.borrow(newPositionId, 10e6);

        vm.expectRevert(expectedError);
        LendefiInstance.repay(newPositionId, 10e6);

        vm.expectRevert(expectedError);
        LendefiInstance.exitPosition(newPositionId);
        vm.stopPrank();

        // Unpause
        vm.prank(gnosisSafe);
        LendefiInstance.unpause();

        // Now all functions should work again
        vm.startPrank(bob);

        // Just test a couple to verify
        // Withdraw some collateral
        LendefiInstance.withdrawCollateral(address(wethInstance), 0.1 ether, newPositionId);

        // Repay more debt
        usdcInstance.approve(address(LendefiInstance), 10e6);
        LendefiInstance.repay(newPositionId, 10e6);
        vm.stopPrank();

        // Verify operations worked
        assertEq(
            LendefiInstance.getCollateralAmount(bob, newPositionId, address(wethInstance)),
            0.9 ether,
            "Collateral should be 0.9 ether after withdrawal"
        );

        IPROTOCOL.UserPosition memory position = LendefiInstance.getUserPosition(bob, newPositionId);
        assertEq(position.debtAmount, 40e6, "Debt should be 40 USDC after additional repayment");
    }

    // Test 19: View functions work when paused
    function test_ViewFunctionsWorkWhenPaused() public {
        // Pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();

        // Try various view functions
        LendefiInstance.getUserPositionsCount(bob);
        LendefiInstance.getUserPosition(bob, positionId);
        LendefiInstance.calculateDebtWithInterest(bob, positionId);
        LendefiInstance.getCollateralAmount(bob, positionId, address(wethInstance));

        // Verify a specific view function works correctly
        uint256 debt = LendefiInstance.calculateDebtWithInterest(bob, positionId);
        assertGe(debt, borrowAmount, "Debt calculation should work and include interest");
    }

    // Test 20: Admin functions work when paused
    function test_AdminFunctionsWorkWhenPaused() public {
        // Try admin functions
        vm.prank(address(timelockInstance));
        // Update asset config should work
        assetsInstance.updateAssetConfig(
            address(rwaToken),
            IASSETS.Asset({
                active: 1,
                decimals: 18, // Asset decimals
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
        // Pause the protocol
        vm.prank(gnosisSafe);
        LendefiInstance.pause();
        // Update flash loan fee using the new config approach
        // First get the current config
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();

        // Store original value for comparison
        uint256 originalFee = config.flashLoanFee;

        // Update the flash loan fee in the config
        config.flashLoanFee = 10; // Change from current value to 10

        // Apply the updated config
        vm.prank(address(timelockInstance));
        LendefiInstance.loadProtocolConfig(config);

        // Verify changes were applied
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(rwaToken));
        assertEq(asset.borrowThreshold, 650, "borrowThreshold should be updated to 600");
        assertEq(asset.liquidationThreshold, 750, "liquidationThreshold should be updated to 700");

        // Verify flash loan fee update using the new config approach
        IPROTOCOL.ProtocolConfig memory updatedConfig = LendefiInstance.getConfig();
        assertEq(updatedConfig.flashLoanFee, 10, "flashLoanFee should be updated to 10");
        assertNotEq(updatedConfig.flashLoanFee, originalFee, "flashLoanFee should be different from original");
    }
}

// Mock Flash Loan Receiver for testing pause/unpause with flash loans

contract MockFlashLoanReceiver is IFlashLoanReceiver {
    using TH for IERC20;

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address, /* initiator */
        bytes calldata /* params */
    ) external override returns (bool) {
        IERC20(token).safeTransfer(msg.sender, amount + fee);
        return true;
    }

    function fundReceiver(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }
}
