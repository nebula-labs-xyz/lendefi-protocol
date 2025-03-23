// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";
import {TokenMock} from "../../../contracts/mock/TokenMock.sol";

contract GetAssetDetailsTest is BasicDeploy {
    // Protocol instance

    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    WETHPriceConsumerV3 internal linkOracleInstance;
    WETHPriceConsumerV3 internal uniOracleInstance;
    // Mock tokens for different tiers
    TokenMock internal linkInstance; // For ISOLATED tier
    TokenMock internal uniInstance; // For CROSS_B tier

    // Constants
    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    uint256 constant ETH_PRICE = 2500e8; // $2500 per ETH
    uint256 constant LINK_PRICE = 15e8; // $15 per LINK
    uint256 constant UNI_PRICE = 8e8; // $8 per UNI

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();
        linkInstance = new TokenMock("Chainlink", "LINK");
        uniInstance = new TokenMock("Uniswap", "UNI");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Create a custom oracle for Link and UNI
        linkOracleInstance = new WETHPriceConsumerV3();
        uniOracleInstance = new WETHPriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(int256(ETH_PRICE)); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable
        linkOracleInstance.setPrice(int256(LINK_PRICE)); // $15 per LINK
        uniOracleInstance.setPrice(int256(UNI_PRICE)); // $8 per UNI

        // Setup roles
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets(linkOracleInstance, uniOracleInstance);
        _addLiquidity(INITIAL_LIQUIDITY);
    }

    function _setupAssets(WETHPriceConsumerV3 linkOracle, WETHPriceConsumerV3 uniOracle) internal {
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
                isolationDebtCap: 10_000e6, // Isolation debt cap
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

        // Configure USDC as STABLE tier
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6, // USDC has 6 decimals
                borrowThreshold: 900, // 90% borrow threshold
                liquidationThreshold: 950, // 95% liquidation threshold
                maxSupplyThreshold: 1_000_000e6, // Supply limit (note the e6 for USDC)
                isolationDebtCap: 0,
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(stableOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure LINK as ISOLATED tier
        assetsInstance.updateAssetConfig(
            address(linkInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18, // LINK has 18 decimals
                borrowThreshold: 700, // 70% borrow threshold
                liquidationThreshold: 750, // 75% liquidation threshold
                maxSupplyThreshold: 100_000 ether, // Supply limit
                isolationDebtCap: 5_000e6, // Isolation debt cap
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.ISOLATED,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(linkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure UNI as CROSS_B tier
        assetsInstance.updateAssetConfig(
            address(uniInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18, // UNI has 18 decimals
                borrowThreshold: 750, // 75% borrow threshold
                liquidationThreshold: 800, // 80% liquidation threshold
                maxSupplyThreshold: 200_000 ether, // Supply limit
                isolationDebtCap: 0,
                assetMinimumOracles: 1, // Need at least 1 oracle
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_B,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(uniOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        vm.stopPrank();
    }

    function _addLiquidity(uint256 amount) internal {
        usdcInstance.mint(gnosisSafe, amount);
        vm.startPrank(gnosisSafe);
        usdcInstance.approve(address(LendefiInstance), amount);
        LendefiInstance.supplyLiquidity(amount);
        vm.stopPrank();
    }

    function _addCollateralSupply(address token, uint256 amount, address user, bool isIsolated) internal {
        // Create a position
        vm.startPrank(user);

        // Create position - set isolation mode based on parameter
        LendefiInstance.createPosition(token, isIsolated);
        uint256 positionId = LendefiInstance.getUserPositionsCount(user) - 1;

        // Add collateral
        if (token == address(wethInstance)) {
            vm.deal(user, amount);
            wethInstance.deposit{value: amount}();
            wethInstance.approve(address(LendefiInstance), amount);
        } else if (token == address(linkInstance)) {
            linkInstance.mint(user, amount);
            linkInstance.approve(address(LendefiInstance), amount);
        } else if (token == address(uniInstance)) {
            uniInstance.mint(user, amount);
            uniInstance.approve(address(LendefiInstance), amount);
        } else {
            usdcInstance.mint(user, amount);
            usdcInstance.approve(address(LendefiInstance), amount);
        }

        LendefiInstance.supplyCollateral(token, amount, positionId);
        vm.stopPrank();
    }

    function test_GetAssetDetails_Basic() public {
        // Test basic details for WETH
        // UPDATED: Use assetsModule for getAssetDetails - adjusted return values
        (uint256 price, uint256 totalSupplied, uint256 maxSupply, IASSETS.CollateralTier tier) =
            assetsInstance.getAssetDetails(address(wethInstance));

        // Log values for debugging
        console2.log("WETH Price:", price);
        console2.log("WETH Total Supplied:", totalSupplied);
        console2.log("WETH Max Supply:", maxSupply);
        console2.log("WETH Tier:", uint256(tier));

        // Verify returned values
        assertEq(price, 2500e6, "WETH price should match oracle price");
        assertEq(totalSupplied, 0, "WETH total supplied should be 0");
        assertEq(maxSupply, 1_000_000 ether, "WETH max supply incorrect");

        // Get rates directly for the tier
        uint256 expectedBorrowRate = LendefiInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_A);
        uint256 expectedLiquidationFee = assetsInstance.getLiquidationFee(IASSETS.CollateralTier.CROSS_A);

        // Get the values from the contract for comparison
        uint256 borrowRate = LendefiInstance.getBorrowRate(tier);
        uint256 liquidationFee = assetsInstance.getLiquidationFee(tier);

        assertEq(borrowRate, expectedBorrowRate, "WETH borrow rate should match expected rate");
        assertEq(liquidationFee, expectedLiquidationFee, "WETH liquidation fee should match expected fee");
        assertEq(uint256(tier), uint256(IASSETS.CollateralTier.CROSS_A), "WETH tier should be CROSS_A");
    }

    function test_GetAssetDetails_AllTiers() public {
        // Test that each asset returns the correct tier
        (,,, IASSETS.CollateralTier wethTier) = assetsInstance.getAssetDetails(address(wethInstance));
        (,,, IASSETS.CollateralTier usdcTier) = assetsInstance.getAssetDetails(address(usdcInstance));
        (,,, IASSETS.CollateralTier linkTier) = assetsInstance.getAssetDetails(address(linkInstance));
        (,,, IASSETS.CollateralTier uniTier) = assetsInstance.getAssetDetails(address(uniInstance));

        // Get liquidation fees directly from assetsInstance
        uint256 wethLiquidationFee = assetsInstance.getLiquidationFee(wethTier);
        uint256 usdcLiquidationFee = assetsInstance.getLiquidationFee(usdcTier);
        uint256 linkLiquidationFee = assetsInstance.getLiquidationFee(linkTier);
        uint256 uniLiquidationFee = assetsInstance.getLiquidationFee(uniTier);

        // Expected liquidation fees
        uint256 expectedWethLiquidationFee = assetsInstance.getLiquidationFee(IASSETS.CollateralTier.CROSS_A);
        uint256 expectedUsdcLiquidationFee = assetsInstance.getLiquidationFee(IASSETS.CollateralTier.STABLE);
        uint256 expectedLinkLiquidationFee = assetsInstance.getLiquidationFee(IASSETS.CollateralTier.ISOLATED);
        uint256 expectedUniLiquidationFee = assetsInstance.getLiquidationFee(IASSETS.CollateralTier.CROSS_B);

        // Verify tiers
        assertEq(uint256(wethTier), uint256(IASSETS.CollateralTier.CROSS_A), "WETH tier should be CROSS_A");
        assertEq(uint256(usdcTier), uint256(IASSETS.CollateralTier.STABLE), "USDC tier should be STABLE");
        assertEq(uint256(linkTier), uint256(IASSETS.CollateralTier.ISOLATED), "LINK tier should be ISOLATED");
        assertEq(uint256(uniTier), uint256(IASSETS.CollateralTier.CROSS_B), "UNI tier should be CROSS_B");

        // Verify liquidation fees match the tier
        assertEq(wethLiquidationFee, expectedWethLiquidationFee, "WETH liquidation fee incorrect");
        assertEq(usdcLiquidationFee, expectedUsdcLiquidationFee, "USDC liquidation fee incorrect");
        assertEq(linkLiquidationFee, expectedLinkLiquidationFee, "LINK liquidation fee incorrect");
        assertEq(uniLiquidationFee, expectedUniLiquidationFee, "UNI liquidation fee incorrect");
    }

    function test_GetAssetDetails_WithCollateralSupplied() public {
        // FIX: Use isolated mode for LINK since it's required
        _addCollateralSupply(address(wethInstance), 10 ether, bob, false); // WETH can be non-isolated
        _addCollateralSupply(address(linkInstance), 100 ether, alice, true); // LINK requires isolation mode

        // Get asset details
        (, uint256 wethSupplied,,) = assetsInstance.getAssetDetails(address(wethInstance));
        (, uint256 linkSupplied,,) = assetsInstance.getAssetDetails(address(linkInstance));

        // Verify supplied amounts
        assertEq(wethSupplied, 10 ether, "WETH supplied amount incorrect");
        assertEq(linkSupplied, 100 ether, "LINK supplied amount incorrect");
    }

    function test_GetAssetDetails_AfterPriceChange() public {
        // Get initial details
        (, uint256 initialSupplied, uint256 initialMaxSupply,) = assetsInstance.getAssetDetails(address(wethInstance));

        // Get initial borrow rate for comparison
        uint256 initialBorrowRate = LendefiInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_A);

        // Change ETH price to $3000
        wethOracleInstance.setPrice(int256(3000e8));

        // Get updated details
        (uint256 newPrice, uint256 newSupplied, uint256 newMaxSupply,) =
            assetsInstance.getAssetDetails(address(wethInstance));

        // Get new borrow rate for comparison
        uint256 newBorrowRate = LendefiInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_A);

        // Verify price changed but other values remain the same
        assertEq(newPrice, 3000e6, "Price should update to new oracle value");
        assertEq(newSupplied, initialSupplied, "Supplied amount shouldn't change with price");
        assertEq(newMaxSupply, initialMaxSupply, "Max supply shouldn't change with price");

        // Borrow rate might change if utilization is affected by price
        if (initialBorrowRate != newBorrowRate) {
            console2.log("Note: Borrow rate changed from", initialBorrowRate, "to", newBorrowRate);
        }
    }

    function test_GetAssetDetails_AfterTierUpdate() public {
        // Get initial details for WETH (CROSS_A tier)
        (,, uint256 maxSupply, IASSETS.CollateralTier initialTier) =
            assetsInstance.getAssetDetails(address(wethInstance));

        // Get expected rates based on what's in the contract
        // uint256 expectedInitialBorrowRate = LendefiInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_A);
        // uint256 expectedInitialLiquidationFee =
        //     assetsInstance.getLiquidationFee(IASSETS.CollateralTier.CROSS_A);

        // UPDATED: Update WETH to CROSS_B tier using assetsInstance
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetTier(address(wethInstance), IASSETS.CollateralTier.CROSS_B);

        // Get updated details
        (,, uint256 newMaxSupply, IASSETS.CollateralTier newTier) =
            assetsInstance.getAssetDetails(address(wethInstance));

        // Get expected new rates
        uint256 expectedNewBorrowRate = LendefiInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_B);
        uint256 expectedNewLiquidationFee = assetsInstance.getLiquidationFee(IASSETS.CollateralTier.CROSS_B);

        // Get actual rates after tier update
        uint256 newBorrowRate = LendefiInstance.getBorrowRate(newTier);
        uint256 newLiquidationFee = assetsInstance.getLiquidationFee(newTier);

        // Verify tier changed but max supply didn't
        assertEq(uint256(initialTier), uint256(IASSETS.CollateralTier.CROSS_A), "Initial tier should be CROSS_A");
        assertEq(uint256(newTier), uint256(IASSETS.CollateralTier.CROSS_B), "New tier should be CROSS_B");
        assertEq(newMaxSupply, maxSupply, "Max supply should remain unchanged after tier update");

        // Verify rates updated
        assertEq(newBorrowRate, expectedNewBorrowRate, "New borrow rate should match CROSS_B");
        assertEq(newLiquidationFee, expectedNewLiquidationFee, "New liquidation fee should match CROSS_B");
    }

    function test_GetAssetDetails_MaxSupply() public {
        // Get current max supply
        (,, uint256 initialMaxSupply,) = assetsInstance.getAssetDetails(address(wethInstance));
        uint256 newMaxSupply = 500_000 ether;

        // UPDATED: Update max supply threshold using assetsInstance
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800, // 80% borrow threshold
                liquidationThreshold: 850, // 85% liquidation threshold
                maxSupplyThreshold: newMaxSupply, // Supply limit
                isolationDebtCap: 10_000e6, // Isolation debt cap
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
        vm.stopPrank();

        // Verify max supply updated
        (,, uint256 updatedMaxSupply,) = assetsInstance.getAssetDetails(address(wethInstance));
        assertEq(initialMaxSupply, 1_000_000 ether, "Initial max supply incorrect");
        assertEq(updatedMaxSupply, newMaxSupply, "Updated max supply incorrect");
    }
}
