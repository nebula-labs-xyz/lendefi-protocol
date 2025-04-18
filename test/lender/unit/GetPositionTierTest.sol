// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {MockWBTC} from "../../../contracts/mock/MockWBTC.sol";
import {MockRWA} from "../../../contracts/mock/MockRWA.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";
import {RWAPriceConsumerV3} from "../../../contracts/mock/RWAOracle.sol";

contract GetPositionTierTest is BasicDeploy {
    // Token instances
    MockWBTC internal wbtcToken; // CROSS_A tier
    MockRWA internal rwaToken; // CROSS_B tier

    // Oracle instances
    WETHPriceConsumerV3 internal wbtcOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    RWAPriceConsumerV3 internal rwaOracleInstance;

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();
        wbtcToken = new MockWBTC();
        rwaToken = new MockRWA("Ondo Coin", "ONDO");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        wbtcOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        wbtcOracleInstance.setPrice(60000e8); // $60,000 per BTC
        stableOracleInstance.setPrice(1e8); // $1 per stable
        rwaOracleInstance.setPrice(100e8); // $100 per RWA token

        // Setup roles
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
        _setupLiquidity();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure USDC as STABLE tier (0)
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6, // USDC decimals
                borrowThreshold: 900, // 90% borrow threshold
                liquidationThreshold: 950, // 95% liquidation threshold
                maxSupplyThreshold: 1_000_000e6, // Supply limit
                isolationDebtCap: 0,
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE, // 0
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(stableOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure WETH as CROSS_A tier (1)
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18, // Asset decimals
                borrowThreshold: 800, // 80% borrow threshold
                liquidationThreshold: 850, // 85% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether, // Supply limit
                isolationDebtCap: 0,
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A, // 1
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure WBTC as CROSS_A tier (1)
        assetsInstance.updateAssetConfig(
            address(wbtcToken),
            IASSETS.Asset({
                active: 1,
                decimals: 8, // WBTC decimals
                borrowThreshold: 800, // 80% borrow threshold
                liquidationThreshold: 850, // 85% liquidation threshold
                maxSupplyThreshold: 1_000 * 1e8, // Supply limit
                isolationDebtCap: 0,
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A, // 1
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wbtcOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure RWA as CROSS_B tier (2)
        assetsInstance.updateAssetConfig(
            address(rwaToken),
            IASSETS.Asset({
                active: 1,
                decimals: 18, // Asset decimals
                borrowThreshold: 700, // 70% borrow threshold
                liquidationThreshold: 750, // 75% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether, // Supply limit
                isolationDebtCap: 0,
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_B, // 2
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(rwaOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure a token for ISOLATED tier (3)
        MockWBTC isolatedToken = new MockWBTC();
        assetsInstance.updateAssetConfig(
            address(isolatedToken),
            IASSETS.Asset({
                active: 1,
                decimals: 8, // Asset decimals
                borrowThreshold: 600, // 60% borrow threshold
                liquidationThreshold: 650, // 65% liquidation threshold
                maxSupplyThreshold: 1_000 * 1e8, // Supply limit
                isolationDebtCap: 1_000_000e6, // Isolation debt cap
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.ISOLATED, // 3
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wbtcOracleInstance), active: 1}),
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
        // Add liquidity to the protocol
        usdcInstance.mint(guardian, 1_000_000e6);
        vm.startPrank(guardian);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    // Helper to create a position and supply collateral
    function _createAndSupply(address asset, uint256 amount, bool isIsolated) internal returns (uint256) {
        vm.startPrank(alice);
        LendefiInstance.createPosition(asset, isIsolated);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;

        // Mint and supply the tokens
        if (asset == address(wethInstance)) {
            vm.deal(alice, amount);
            wethInstance.deposit{value: amount}();
        } else if (asset == address(wbtcToken)) {
            wbtcToken.mint(alice, amount);
        } else if (asset == address(rwaToken)) {
            rwaToken.mint(alice, amount);
        } else if (asset == address(usdcInstance)) {
            usdcInstance.mint(alice, amount);
        }

        IERC20(asset).approve(address(LendefiInstance), amount);
        LendefiInstance.supplyCollateral(asset, amount, positionId);
        vm.stopPrank();

        return positionId;
    }

    // Test 1: Position with only STABLE tier asset
    function test_GetHighestTier_StableOnly() public {
        uint256 positionId = _createAndSupply(address(usdcInstance), 10_000e6, false);

        // UPDATED: Use getPositionTier instead of getHighestTier
        IASSETS.CollateralTier highestTier = LendefiInstance.getPositionTier(alice, positionId);
        console2.log("Highest tier with STABLE only:", uint256(highestTier));

        assertEq(uint256(highestTier), uint256(IASSETS.CollateralTier.STABLE), "Highest tier should be STABLE (0)");
    }

    // Test 2: Position with only CROSS_A tier asset
    function test_GetHighestTier_CrossAOnly() public {
        uint256 positionId = _createAndSupply(address(wethInstance), 5 ether, false);

        // UPDATED: Use getPositionTier instead of getHighestTier
        IASSETS.CollateralTier highestTier = LendefiInstance.getPositionTier(alice, positionId);
        console2.log("Highest tier with CROSS_A only:", uint256(highestTier));

        assertEq(uint256(highestTier), uint256(IASSETS.CollateralTier.CROSS_A), "Highest tier should be CROSS_A (1)");
    }

    // Test 3: Position with only CROSS_B tier asset
    function test_GetHighestTier_CrossBOnly() public {
        uint256 positionId = _createAndSupply(address(rwaToken), 10 ether, false);

        // UPDATED: Use getPositionTier instead of getHighestTier
        IASSETS.CollateralTier highestTier = LendefiInstance.getPositionTier(alice, positionId);
        console2.log("Highest tier with CROSS_B only:", uint256(highestTier));

        assertEq(uint256(highestTier), uint256(IASSETS.CollateralTier.CROSS_B), "Highest tier should be CROSS_B (2)");
    }

    // Test 4: Position with STABLE and CROSS_A
    function test_GetHighestTier_StableAndCrossA() public {
        uint256 positionId = _createAndSupply(address(wethInstance), 5 ether, false);

        // Add STABLE asset to the position
        vm.startPrank(alice);
        usdcInstance.mint(alice, 10_000e6);
        usdcInstance.approve(address(LendefiInstance), 10_000e6);
        LendefiInstance.supplyCollateral(address(usdcInstance), 10_000e6, positionId);
        vm.stopPrank();

        // UPDATED: Use getPositionTier instead of getHighestTier
        IASSETS.CollateralTier highestTier = LendefiInstance.getPositionTier(alice, positionId);
        console2.log("Highest tier with STABLE and CROSS_A:", uint256(highestTier));

        // Based on the Lendefi contract's getPositionTier function behavior,
        // it will return the numerically highest tier, which is CROSS_A (1) since it's greater than STABLE (0)
        assertEq(uint256(highestTier), uint256(IASSETS.CollateralTier.CROSS_A), "Highest tier should be CROSS_A (1)");
    }

    // Test 5: Position with CROSS_A and CROSS_B
    function test_GetHighestTier_CrossAAndCrossB() public {
        uint256 positionId = _createAndSupply(address(wethInstance), 5 ether, false);

        // Add CROSS_B asset to the position
        vm.startPrank(alice);
        rwaToken.mint(alice, 10 ether);
        rwaToken.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(rwaToken), 10 ether, positionId);
        vm.stopPrank();

        // UPDATED: Use getPositionTier instead of getHighestTier
        IASSETS.CollateralTier highestTier = LendefiInstance.getPositionTier(alice, positionId);
        console2.log("Highest tier with CROSS_A and CROSS_B:", uint256(highestTier));

        // Based on the Lendefi contract's getPositionTier function behavior,
        // it will return the numerically highest tier, which is CROSS_B (2) since it's greater than CROSS_A (1)
        assertEq(uint256(highestTier), uint256(IASSETS.CollateralTier.CROSS_B), "Highest tier should be CROSS_B (2)");
    }

    // Test 6: Position with multiple assets from all tiers
    function test_GetHighestTier_AllTiers() public {
        uint256 positionId = _createAndSupply(address(wethInstance), 5 ether, false);

        // Add other assets to the position
        vm.startPrank(alice);

        // Add STABLE asset
        usdcInstance.mint(alice, 10_000e6);
        usdcInstance.approve(address(LendefiInstance), 10_000e6);
        LendefiInstance.supplyCollateral(address(usdcInstance), 10_000e6, positionId);

        // Add CROSS_B asset
        rwaToken.mint(alice, 10 ether);
        rwaToken.approve(address(LendefiInstance), 10 ether);
        LendefiInstance.supplyCollateral(address(rwaToken), 10 ether, positionId);

        vm.stopPrank();

        // UPDATED: Use getPositionTier instead of getHighestTier
        IASSETS.CollateralTier highestTier = LendefiInstance.getPositionTier(alice, positionId);
        console2.log("Highest tier with all tiers:", uint256(highestTier));

        // Based on the Lendefi contract's getPositionTier function behavior,
        // it will return the numerically highest tier among all assets, which is CROSS_B (2)
        assertEq(uint256(highestTier), uint256(IASSETS.CollateralTier.CROSS_B), "Highest tier should be CROSS_B (2)");
    }

    // Test 7: Position with no collateral
    function test_GetHighestTier_NoCollateral() public {
        vm.startPrank(alice);
        LendefiInstance.createPosition(address(wethInstance), false);
        uint256 positionId = LendefiInstance.getUserPositionsCount(alice) - 1;
        vm.stopPrank();

        IASSETS.CollateralTier highestTier = LendefiInstance.getPositionTier(alice, positionId);
        console2.log("Highest tier with no collateral:", uint256(highestTier));

        // With no collateral, it should return the default value, which is STABLE (0)
        assertEq(
            uint256(highestTier),
            uint256(IASSETS.CollateralTier.STABLE),
            "Highest tier with no collateral should be STABLE (0)"
        );
    }

    // Test 8: Try to get highest tier for an invalid position
    function test_GetHighestTier_InvalidPosition() public {
        // Try to access an invalid position
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.InvalidPosition.selector));
        LendefiInstance.getPositionTier(alice, 0);
    }

    // Test 9: Documentation check - print all tier values
    function test_TierValues() public pure {
        console2.log("STABLE tier value:", uint256(IASSETS.CollateralTier.STABLE));
        console2.log("CROSS_A tier value:", uint256(IASSETS.CollateralTier.CROSS_A));
        console2.log("CROSS_B tier value:", uint256(IASSETS.CollateralTier.CROSS_B));
        console2.log("ISOLATED tier value:", uint256(IASSETS.CollateralTier.ISOLATED));
    }
}
