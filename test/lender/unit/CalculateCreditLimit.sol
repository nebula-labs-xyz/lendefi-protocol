// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {RWAPriceConsumerV3} from "../../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";
import {MockRWA} from "../../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";

contract CalculateCreditLimitTest is BasicDeploy {
    MockRWA internal rwaToken;
    MockRWA internal stableToken;

    RWAPriceConsumerV3 internal rwaassetsInstance;
    WETHPriceConsumerV3 internal wethassetsInstance;
    StablePriceConsumerV3 internal stableassetsInstance;

    function setUp() public {
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();
        rwaToken = new MockRWA("Ondo Finance", "ONDO");
        stableToken = new MockRWA("USD Coin", "USDC");

        // Deploy oracles
        wethassetsInstance = new WETHPriceConsumerV3();
        rwaassetsInstance = new RWAPriceConsumerV3();
        stableassetsInstance = new StablePriceConsumerV3();

        // Set prices
        wethassetsInstance.setPrice(2500e8); // $2500 per ETH
        rwaassetsInstance.setPrice(1000e8); // $1000 per RWA token
        stableassetsInstance.setPrice(1e8); // $1 per stable token

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
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0, // no isolation debt cap
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethassetsInstance), active: 1}),
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
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 100_000e6, // Isolation debt cap of 100,000 USDC
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.ISOLATED,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(rwaassetsInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure stable token as STABLE tier
        assetsInstance.updateAssetConfig(
            address(stableToken),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 900, // 90% borrow threshold
                liquidationThreshold: 950, // 95% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(stableassetsInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        vm.stopPrank();
    }

    // Helper function to create positions
    function _createPosition(address user, address asset, bool isIsolated) internal returns (uint256) {
        vm.prank(user);
        LendefiInstance.createPosition(asset, isIsolated);
        return LendefiInstance.getUserPositionsCount(user) - 1;
    }

    // Helper function to mint and supply collateral
    function _mintAndSupplyCollateral(address user, address asset, uint256 amount, uint256 positionId) internal {
        // Mint tokens to user
        if (asset == address(wethInstance)) {
            vm.deal(user, amount);
            vm.prank(user);
            wethInstance.deposit{value: amount}();
        } else if (asset == address(rwaToken)) {
            rwaToken.mint(user, amount);
        } else if (asset == address(stableToken)) {
            stableToken.mint(user, amount);
        }

        // Supply collateral
        vm.startPrank(user);
        IERC20(asset).approve(address(LendefiInstance), amount);
        LendefiInstance.supplyCollateral(asset, amount, positionId);
        vm.stopPrank();
    }

    // Test 1: Invalid position ID reverts - UPDATED to use error code
    function test_InvalidPositionIdReverts() public {
        uint256 invalidPositionId = 999;

        // Updated to use string error code
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector));
        LendefiInstance.calculateCreditLimit(alice, invalidPositionId);
    }

    // Test 2: Calculate credit limit for isolated position
    function test_IsolatedPositionCreditLimit() public {
        // Create isolated position
        uint256 positionId = _createPosition(alice, address(rwaToken), true);

        // Supply collateral
        uint256 collateralAmount = 10 ether;
        _mintAndSupplyCollateral(alice, address(rwaToken), collateralAmount, positionId);

        // Calculate expected credit limit manually - USE USDC PRECISION (1e6)
        uint256 rwaPrice = 1000e8; // $1000
        uint256 borrowThreshold = 650; // 65%
        uint256 expectedCreditLimit = (collateralAmount * rwaPrice * borrowThreshold * 1e6) / 1e18 / 1000 / 1e8;

        // Get credit limit from contract
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        // Compare
        assertEq(creditLimit, expectedCreditLimit, "Credit limit for isolated position is incorrect");
    }

    // Test 3: Calculate credit limit for cross-collateral position
    function test_CrossCollateralPositionCreditLimit() public {
        // Create cross-collateral position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply collateral
        uint256 collateralAmount = 10 ether;
        _mintAndSupplyCollateral(alice, address(wethInstance), collateralAmount, positionId);

        // Calculate expected credit limit manually - USE USDC PRECISION (1e6)
        uint256 wethPrice = 2500e8; // $2500
        uint256 borrowThreshold = 800; // 80%
        uint256 expectedCreditLimit = (collateralAmount * wethPrice * borrowThreshold * 1e6) / 1e18 / 1000 / 1e8;

        // Get credit limit from contract
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        // Compare
        assertEq(creditLimit, expectedCreditLimit, "Credit limit for cross-collateral position is incorrect");
    }

    // Test 4: Position with no collateral (should return 0)
    function test_NoCollateralPositionCreditLimit() public {
        // Create position without supplying collateral
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Get credit limit from contract
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        // Should be zero
        assertEq(creditLimit, 0, "Credit limit with no collateral should be zero");
    }

    // Test 5: Position with multiple assets
    function test_MultiAssetPositionCreditLimit() public {
        // Create cross-collateral position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply multiple collateral types
        uint256 wethAmount = 10 ether;
        uint256 stableAmount = 1000 ether;

        _mintAndSupplyCollateral(alice, address(wethInstance), wethAmount, positionId);
        _mintAndSupplyCollateral(alice, address(stableToken), stableAmount, positionId);

        // Calculate expected credit limit manually
        uint256 wethPrice = 2500e8; // $2500
        uint256 wethBorrowThreshold = 800; // 80%
        uint256 stablePrice = 1e8; // $1
        uint256 stableBorrowThreshold = 900; // 90%

        uint256 wethContribution = (wethAmount * wethPrice * wethBorrowThreshold * 1e6) / 1e18 / 1000 / 1e8;
        uint256 stableContribution = (stableAmount * stablePrice * stableBorrowThreshold * 1e6) / 1e18 / 1000 / 1e8;
        uint256 expectedCreditLimit = wethContribution + stableContribution;

        // Get credit limit from contract
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        // Compare
        assertEq(creditLimit, expectedCreditLimit, "Credit limit for multi-asset position is incorrect");
    }

    // Test 6: Credit limit changes when oracle price changes
    function test_CreditLimitChangesWithOraclePrice() public {
        // Create isolated position
        uint256 positionId = _createPosition(alice, address(rwaToken), true);

        // Supply collateral
        uint256 collateralAmount = 10 ether;
        _mintAndSupplyCollateral(alice, address(rwaToken), collateralAmount, positionId);

        // Get initial credit limit
        uint256 initialCreditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        // Change oracle price (double it)
        rwaassetsInstance.setPrice(2000e8); // $2000 per RWA token

        // Get new credit limit
        uint256 newCreditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        // Should be double the initial limit
        assertEq(newCreditLimit, initialCreditLimit * 2, "Credit limit should double when price doubles");
    }

    // Test 7: Credit limit with zero price should revert - UPDATED: to use oracle error code
    function test_CreditLimitWithZeroPrice() public {
        // Create isolated position
        uint256 positionId = _createPosition(alice, address(rwaToken), true);

        // Supply collateral
        uint256 collateralAmount = 10 ether;
        _mintAndSupplyCollateral(alice, address(rwaToken), collateralAmount, positionId);

        // Set oracle price to zero
        rwaassetsInstance.setPrice(0);

        // Should revert with price error code
        vm.expectRevert();
        LendefiInstance.calculateCreditLimit(alice, positionId);
    }

    // Test 8: Credit limit across multiple positions for same user
    function test_MultiplePositionsCreditLimit() public {
        // Create positions
        uint256 position1 = _createPosition(alice, address(wethInstance), false);
        uint256 position2 = _createPosition(alice, address(rwaToken), true);

        // Supply collateral to both
        _mintAndSupplyCollateral(alice, address(wethInstance), 5 ether, position1);
        _mintAndSupplyCollateral(alice, address(rwaToken), 10 ether, position2);

        // Calculate expected credit limits
        uint256 wethPrice = 2500e8;
        uint256 wethBorrowThreshold = 800;
        uint256 rwaPrice = 1000e8;
        uint256 rwaBorrowThreshold = 650;

        uint256 expectedLimit1 = (5 ether * wethPrice * wethBorrowThreshold * 1e6) / 1e18 / 1000 / 1e8;
        uint256 expectedLimit2 = (10 ether * rwaPrice * rwaBorrowThreshold * 1e6) / 1e18 / 1000 / 1e8;

        // Get credit limits from contract
        uint256 limit1 = LendefiInstance.calculateCreditLimit(alice, position1);
        uint256 limit2 = LendefiInstance.calculateCreditLimit(alice, position2);

        // Compare
        assertEq(limit1, expectedLimit1, "Credit limit for position 1 is incorrect");
        assertEq(limit2, expectedLimit2, "Credit limit for position 2 is incorrect");
    }

    // Test 9: Verify borrowing up to credit limit works
    function test_BorrowingUpToCreditLimit() public {
        // First, supply some liquidity to the protocol
        usdcInstance.mint(bob, 100_000e6);
        vm.startPrank(bob);
        usdcInstance.approve(address(LendefiInstance), 100_000e6);
        LendefiInstance.supplyLiquidity(100_000e6);
        vm.stopPrank();

        // Create position for alice
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply collateral
        uint256 collateralAmount = 10 ether;
        _mintAndSupplyCollateral(alice, address(wethInstance), collateralAmount, positionId);

        // Get credit limit
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        // Try to borrow exactly at credit limit
        vm.startPrank(alice);
        LendefiInstance.borrow(positionId, creditLimit);
        vm.stopPrank();

        // Verify borrow succeeded
        uint256 aliceUsdcBalance = usdcInstance.balanceOf(alice);
        assertEq(aliceUsdcBalance, creditLimit, "Alice should have borrowed up to credit limit");

        // Try to borrow 1 more USDC - should revert with CLM (credit limit maximum)
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.CreditLimitExceeded.selector));
        LendefiInstance.borrow(positionId, 1);
        vm.stopPrank();
    }

    // Test 10: Fuzz test with different collateral amounts
    function testFuzz_CreditLimitScaling(uint256 collateralAmount) public {
        // Bound to reasonable values
        collateralAmount = bound(collateralAmount, 0.1 ether, 1000 ether);

        // Create isolated position
        uint256 positionId = _createPosition(alice, address(rwaToken), true);

        // Supply collateral
        _mintAndSupplyCollateral(alice, address(rwaToken), collateralAmount, positionId);

        // Calculate expected credit limit
        uint256 rwaPrice = 1000e8; // $1000
        uint256 borrowThreshold = 650; // 65%
        uint256 expectedCreditLimit = (collateralAmount * rwaPrice * borrowThreshold * 1e6) / 1e18 / 1000 / 1e8;

        // Get credit limit from contract
        uint256 creditLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        // Compare
        assertEq(creditLimit, expectedCreditLimit, "Credit limit should scale linearly with collateral amount");
    }

    // Test 11: Credit limit of multiple users
    function test_MultipleUsersCreditLimit() public {
        // Create positions for different users
        uint256 alicePos = _createPosition(alice, address(wethInstance), false);
        uint256 bobPos = _createPosition(bob, address(wethInstance), false);

        // Supply same amount of collateral
        uint256 collateralAmount = 10 ether;
        _mintAndSupplyCollateral(alice, address(wethInstance), collateralAmount, alicePos);
        _mintAndSupplyCollateral(bob, address(wethInstance), collateralAmount, bobPos);

        // Get credit limits
        uint256 aliceLimit = LendefiInstance.calculateCreditLimit(alice, alicePos);
        uint256 bobLimit = LendefiInstance.calculateCreditLimit(bob, bobPos);

        // Should be equal
        assertEq(aliceLimit, bobLimit, "Credit limits should be equal for same collateral");
    }

    // Test 12: Credit limit after partial collateral withdrawal
    function test_CreditLimitAfterPartialWithdrawal() public {
        // First, create position
        uint256 positionId = _createPosition(alice, address(wethInstance), false);

        // Supply collateral
        uint256 initialCollateral = 10 ether;
        _mintAndSupplyCollateral(alice, address(wethInstance), initialCollateral, positionId);

        // Get initial credit limit
        uint256 initialLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        // Withdraw half the collateral
        vm.prank(alice);
        LendefiInstance.withdrawCollateral(address(wethInstance), initialCollateral / 2, positionId);

        // Get new credit limit
        uint256 newLimit = LendefiInstance.calculateCreditLimit(alice, positionId);

        // Should be half of the initial limit
        assertEq(newLimit, initialLimit / 2, "Credit limit should be halved after withdrawing half the collateral");
    }
}
