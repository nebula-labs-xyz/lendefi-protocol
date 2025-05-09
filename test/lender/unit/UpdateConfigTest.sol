// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {MockPriceOracle} from "../../../contracts/mock/MockPriceOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IFlashLoanReceiver} from "../../../contracts/interfaces/IFlashLoanReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20 as TH} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract UpdateProtocolConfigTest is BasicDeploy {
    // Default values from initialize()
    uint256 constant DEFAULT_BASE_PROFIT_TARGET = 0.01e6; // 1%
    uint256 constant DEFAULT_BASE_BORROW_RATE = 0.06e6; // 6%
    uint256 constant DEFAULT_TARGET_REWARD = 2_000 ether;
    uint256 constant DEFAULT_REWARD_INTERVAL = 180 days;
    uint256 constant DEFAULT_REWARDABLE_SUPPLY = 100_000 * 1e6;
    uint256 constant DEFAULT_LIQUIDATOR_THRESHOLD = 20_000 ether;
    uint256 constant DEFAULT_FLASH_LOAN_FEE = 9; // 9 basis points (0.09%)

    // New values for testing
    uint256 constant NEW_BASE_PROFIT_TARGET = 0.02e6; // 2%
    uint256 constant NEW_BASE_BORROW_RATE = 0.08e6; // 8%
    uint256 constant NEW_TARGET_REWARD = 3_000 ether;
    uint256 constant NEW_REWARD_INTERVAL = 365 days;
    uint256 constant NEW_REWARDABLE_SUPPLY = 150_000 * 1e6;
    uint256 constant NEW_LIQUIDATOR_THRESHOLD = 30_000 ether;
    uint256 constant NEW_FLASH_LOAN_FEE = 15; // 15 basis points (0.15%)

    // Minimum values for testing
    uint256 constant MIN_BASE_PROFIT_TARGET = 0.0025e6; // 0.25%
    uint256 constant MIN_BASE_BORROW_RATE = 0.01e6; // 1%
    uint256 constant MIN_REWARD_INTERVAL = 90 days;
    uint256 constant MIN_REWARDABLE_SUPPLY = 20_000 * 1e6;
    uint256 constant MIN_LIQUIDATOR_THRESHOLD = 10 ether;
    uint256 constant MIN_FLASH_LOAN_FEE = 1; // 1 basis point (0.01%)

    // Maximum values for testing
    uint256 constant MAX_FLASH_LOAN_FEE = 100; // 100 basis points (1%)
    uint256 constant MAX_REWARD_AMOUNT = 10_000 ether;

    function setUp() public {
        // Use the updated deployment function that includes Oracle setup
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
    }

    /* --------------- Access Control Tests --------------- */

    function testRevert_LoadProtocolConfig_AccessControl() public {
        // Create a valid config
        IPROTOCOL.ProtocolConfig memory config = _createValidConfig();

        // Regular user should not be able to update
        vm.startPrank(alice);

        // OZ AccessControl v5 error format
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, MANAGER_ROLE)
        );

        LendefiInstance.loadProtocolConfig(config);
        vm.stopPrank();

        // Manager should be able to update
        vm.prank(address(timelockInstance));
        LendefiInstance.loadProtocolConfig(config);
    }

    /* --------------- State Change Tests --------------- */

    function test_LoadProtocolConfig_StateChange() public {
        // Verify initial values
        IPROTOCOL.ProtocolConfig memory initialConfig = LendefiInstance.getConfig();
        assertEq(initialConfig.profitTargetRate, DEFAULT_BASE_PROFIT_TARGET);
        assertEq(initialConfig.borrowRate, DEFAULT_BASE_BORROW_RATE);
        assertEq(initialConfig.rewardAmount, DEFAULT_TARGET_REWARD);
        assertEq(initialConfig.rewardInterval, DEFAULT_REWARD_INTERVAL);
        assertEq(initialConfig.rewardableSupply, DEFAULT_REWARDABLE_SUPPLY);
        assertEq(initialConfig.liquidatorThreshold, DEFAULT_LIQUIDATOR_THRESHOLD);
        assertEq(initialConfig.flashLoanFee, DEFAULT_FLASH_LOAN_FEE);

        // Create a new config with updated values
        IPROTOCOL.ProtocolConfig memory newConfig = IPROTOCOL.ProtocolConfig({
            profitTargetRate: NEW_BASE_PROFIT_TARGET,
            borrowRate: NEW_BASE_BORROW_RATE,
            rewardAmount: NEW_TARGET_REWARD,
            rewardInterval: NEW_REWARD_INTERVAL,
            rewardableSupply: NEW_REWARDABLE_SUPPLY,
            liquidatorThreshold: NEW_LIQUIDATOR_THRESHOLD,
            flashLoanFee: NEW_FLASH_LOAN_FEE
        });

        // Update values
        vm.prank(address(timelockInstance));
        LendefiInstance.loadProtocolConfig(newConfig);

        // Verify updated values
        IPROTOCOL.ProtocolConfig memory updatedConfig = LendefiInstance.getConfig();
        assertEq(updatedConfig.profitTargetRate, NEW_BASE_PROFIT_TARGET);
        assertEq(updatedConfig.borrowRate, NEW_BASE_BORROW_RATE);
        assertEq(updatedConfig.rewardAmount, NEW_TARGET_REWARD);
        assertEq(updatedConfig.rewardInterval, NEW_REWARD_INTERVAL);
        assertEq(updatedConfig.rewardableSupply, NEW_REWARDABLE_SUPPLY);
        assertEq(updatedConfig.liquidatorThreshold, NEW_LIQUIDATOR_THRESHOLD);
        assertEq(updatedConfig.flashLoanFee, NEW_FLASH_LOAN_FEE);
    }

    /* --------------- Minimum Value Tests --------------- */

    function testRevert_LoadProtocolConfig_ProfitTargetTooLow() public {
        IPROTOCOL.ProtocolConfig memory config = _createValidConfig();
        config.profitTargetRate = MIN_BASE_PROFIT_TARGET - 1; // Too low

        vm.prank(address(timelockInstance));

        // Use custom error format
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidProfitTarget.selector));

        LendefiInstance.loadProtocolConfig(config);
    }

    function testRevert_LoadProtocolConfig_BorrowRateTooLow() public {
        IPROTOCOL.ProtocolConfig memory config = _createValidConfig();
        config.borrowRate = MIN_BASE_BORROW_RATE - 1; // Too low

        vm.prank(address(timelockInstance));

        // Use custom error format
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidBorrowRate.selector));

        LendefiInstance.loadProtocolConfig(config);
    }

    function testRevert_LoadProtocolConfig_RewardAmountTooHigh() public {
        IPROTOCOL.ProtocolConfig memory config = _createValidConfig();
        config.rewardAmount = MAX_REWARD_AMOUNT + 1; // Too high

        vm.prank(address(timelockInstance));

        // Use custom error format
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidRewardAmount.selector));

        LendefiInstance.loadProtocolConfig(config);
    }

    function testRevert_LoadProtocolConfig_RewardIntervalTooShort() public {
        IPROTOCOL.ProtocolConfig memory config = _createValidConfig();
        config.rewardInterval = MIN_REWARD_INTERVAL - 1; // Too short

        vm.prank(address(timelockInstance));

        // Use custom error format
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidInterval.selector));

        LendefiInstance.loadProtocolConfig(config);
    }

    function testRevert_LoadProtocolConfig_RewardableSupplyTooLow() public {
        IPROTOCOL.ProtocolConfig memory config = _createValidConfig();
        config.rewardableSupply = MIN_REWARDABLE_SUPPLY - 1; // Too low

        vm.prank(address(timelockInstance));

        // Use custom error format
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidSupplyAmount.selector));

        LendefiInstance.loadProtocolConfig(config);
    }

    function testRevert_LoadProtocolConfig_LiquidatorThresholdTooLow() public {
        IPROTOCOL.ProtocolConfig memory config = _createValidConfig();
        config.liquidatorThreshold = MIN_LIQUIDATOR_THRESHOLD - 1; // Too low

        vm.prank(address(timelockInstance));

        // Use custom error format
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidLiquidatorThreshold.selector));

        LendefiInstance.loadProtocolConfig(config);
    }

    function testRevert_LoadProtocolConfig_FlashLoanFeeTooHigh() public {
        IPROTOCOL.ProtocolConfig memory config = _createValidConfig();
        config.flashLoanFee = MAX_FLASH_LOAN_FEE + 1; // Too high

        vm.prank(address(timelockInstance));

        // Use custom error format
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidFee.selector));

        LendefiInstance.loadProtocolConfig(config);
    }

    function testRevert_LoadProtocolConfig_FlashLoanFeeTooLow() public {
        IPROTOCOL.ProtocolConfig memory config = _createValidConfig();
        config.flashLoanFee = 0; // Too low (min is 1)

        vm.prank(address(timelockInstance));

        // Use custom error format
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidFee.selector));

        LendefiInstance.loadProtocolConfig(config);
    }

    function test_LoadProtocolConfig_MinimumValues() public {
        // Should succeed with minimum valid values
        IPROTOCOL.ProtocolConfig memory config = IPROTOCOL.ProtocolConfig({
            profitTargetRate: MIN_BASE_PROFIT_TARGET,
            borrowRate: MIN_BASE_BORROW_RATE,
            rewardAmount: 1 ether, // No minimum
            rewardInterval: MIN_REWARD_INTERVAL,
            rewardableSupply: MIN_REWARDABLE_SUPPLY,
            liquidatorThreshold: MIN_LIQUIDATOR_THRESHOLD,
            flashLoanFee: MIN_FLASH_LOAN_FEE
        });

        vm.prank(address(timelockInstance));
        LendefiInstance.loadProtocolConfig(config);

        // Verify state changes
        IPROTOCOL.ProtocolConfig memory updatedConfig = LendefiInstance.getConfig();
        assertEq(updatedConfig.profitTargetRate, MIN_BASE_PROFIT_TARGET);
        assertEq(updatedConfig.borrowRate, MIN_BASE_BORROW_RATE);
        assertEq(updatedConfig.rewardInterval, MIN_REWARD_INTERVAL);
        assertEq(updatedConfig.rewardableSupply, MIN_REWARDABLE_SUPPLY);
        assertEq(updatedConfig.liquidatorThreshold, MIN_LIQUIDATOR_THRESHOLD);
        assertEq(updatedConfig.flashLoanFee, MIN_FLASH_LOAN_FEE);
    }

    /* --------------- Effect On Protocol Tests --------------- */

    function test_UpdateConfig_EffectOnBorrowRate() public {
        // Setup protocol with supply and borrow
        _setupProtocolWithSupplyAndBorrow();

        // Get initial borrow rate for STABLE tier
        uint256 initialBorrowRate = LendefiInstance.getBorrowRate(IASSETS.CollateralTier.STABLE);

        // Update base borrow rate (double it)
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();
        config.borrowRate = config.borrowRate * 2;

        vm.prank(address(timelockInstance));
        LendefiInstance.loadProtocolConfig(config);

        // Get new borrow rate
        uint256 newBorrowRate = LendefiInstance.getBorrowRate(IASSETS.CollateralTier.STABLE);

        // Borrow rate should be higher after increase to base
        assertGt(newBorrowRate, initialBorrowRate, "Borrow rate should increase when base borrow rate increases");
    }

    function test_UpdateConfig_EffectOnSupplyRate() public {
        // Setup protocol with supply and borrow
        _setupProtocolWithSupplyAndBorrow();

        // Generate protocol profit by minting additional USDC directly to the contract
        usdcInstance.mint(address(LendefiInstance), 5_000e6); // Add 5,000 USDC as profit

        // Get initial supply rate
        uint256 initialSupplyRate = LendefiInstance.getSupplyRate();

        // Update profit target (double it)
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();
        config.profitTargetRate = config.profitTargetRate * 2;

        vm.prank(address(timelockInstance));
        LendefiInstance.loadProtocolConfig(config);

        // Get new supply rate
        uint256 newSupplyRate = LendefiInstance.getSupplyRate();

        // Supply rate should change when profit target changes
        assertNotEq(initialSupplyRate, newSupplyRate, "Supply rate should change when profit target changes");
    }

    function test_UpdateConfig_EffectOnFlashLoanFee() public {
        // Setup protocol with liquidity
        usdcInstance.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 100_000e6);
        LendefiInstance.supplyLiquidity(100_000e6);
        vm.stopPrank();

        // Deploy a flash loan receiver
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver();

        // Update flash loan fee
        IPROTOCOL.ProtocolConfig memory config = LendefiInstance.getConfig();
        config.flashLoanFee = 20; // 0.2%

        vm.prank(address(timelockInstance));
        LendefiInstance.loadProtocolConfig(config);

        // Calculate expected fee
        uint256 flashLoanAmount = 10_000e6;
        uint256 expectedFee = (flashLoanAmount * 20) / 10000; // 0.2% fee

        // Fund the receiver to repay loan + fee
        usdcInstance.mint(address(this), expectedFee);
        usdcInstance.approve(address(receiver), expectedFee);
        receiver.fundReceiver(address(usdcInstance), expectedFee);

        // Execute flash loan
        LendefiInstance.flashLoan(address(receiver), flashLoanAmount, "");

        // Verify fee collection
        assertEq(LendefiInstance.totalFlashLoanFees(), expectedFee, "Flash loan fee should be calculated correctly");
    }

    /* --------------- Helper Functions --------------- */

    function _createValidConfig() internal pure returns (IPROTOCOL.ProtocolConfig memory) {
        return IPROTOCOL.ProtocolConfig({
            profitTargetRate: NEW_BASE_PROFIT_TARGET,
            borrowRate: NEW_BASE_BORROW_RATE,
            rewardAmount: NEW_TARGET_REWARD,
            rewardInterval: NEW_REWARD_INTERVAL,
            rewardableSupply: NEW_REWARDABLE_SUPPLY,
            liquidatorThreshold: NEW_LIQUIDATOR_THRESHOLD,
            flashLoanFee: NEW_FLASH_LOAN_FEE
        });
    }

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
            IASSETS.Asset({
                active: 1,
                decimals: 18, // Asset decimals
                borrowThreshold: 800, // 80% borrow threshold
                liquidationThreshold: 850, // 85% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether, // Supply limit
                isolationDebtCap: 0, // No isolation debt cap
                assetMinimumOracles: 1, // Need at least 1 oracle
                porFeed: address(0),
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

// Mock Flash Loan Receiver for testing
contract MockFlashLoanReceiver is IFlashLoanReceiver {
    using TH for IERC20;

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address, // initiator
        bytes calldata // params
    ) external override returns (bool) {
        // Always succeed for test purposes
        IERC20 tokenInstance = IERC20(token);
        TH.safeTransfer(tokenInstance, msg.sender, amount + fee);
        return true;
    }

    function fundReceiver(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }
}
