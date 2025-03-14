// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";

contract GetAssetInfoTest is BasicDeploy {
    // Oracle instances
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    WETHPriceConsumerV3 internal linkOracleInstance;
    WETHPriceConsumerV3 internal uniOracleInstance;

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        vm.warp(block.timestamp + 90 days);

        // Deploy WETH (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable

        // Setup roles
        vm.prank(guardian);
        ecoInstance.grantRole(REWARDER_ROLE, address(LendefiInstance));

        _setupAssets();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // UPDATED: Configure WETH as CROSS_A tier - Use assetsInstance
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            1, // Active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // Supply limit
            0,
            IASSETS.CollateralTier.CROSS_A,
            IASSETS.OracleType.CHAINLINK
        );

        // UPDATED: Configure USDC as STABLE tier - Use assetsInstance
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            address(stableOracleInstance),
            8, // Oracle decimals
            6, // USDC decimals
            1, // Active
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000e6, // Supply limit
            0,
            IASSETS.CollateralTier.STABLE,
            IASSETS.OracleType.CHAINLINK
        );

        assetsInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        assetsInstance.setPrimaryOracle(address(usdcInstance), address(stableOracleInstance));
        vm.stopPrank();
    }

    function test_GetAssetInfo_WETH() public {
        // UPDATED: Use assetsInstance for getAssetInfo
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));

        assertEq(asset.active, 1, "WETH should be active");
        assertEq(asset.oracleUSD, address(wethOracleInstance), "Oracle address mismatch");
        assertEq(asset.oracleDecimals, 8, "Oracle decimals mismatch");
        assertEq(asset.decimals, 18, "Asset decimals mismatch");
        assertEq(asset.borrowThreshold, 800, "Borrow threshold mismatch");
        assertEq(asset.liquidationThreshold, 850, "Liquidation threshold mismatch");
        assertEq(asset.maxSupplyThreshold, 1_000_000 ether, "Supply limit mismatch");
        // UPDATED: Use IASSETS.CollateralTier instead of IPROTOCOL.CollateralTier
        assertEq(uint8(asset.tier), uint8(IASSETS.CollateralTier.CROSS_A), "Tier mismatch");
        assertEq(asset.isolationDebtCap, 0, "Isolation debt cap should be 0 for non-isolated assets");
    }

    function test_GetAssetInfo_USDC() public {
        // UPDATED: Use assetsInstance for getAssetInfo
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(usdcInstance));

        assertEq(asset.active, 1, "USDC should be active");
        assertEq(asset.oracleUSD, address(stableOracleInstance), "Oracle address mismatch");
        assertEq(asset.oracleDecimals, 8, "Oracle decimals mismatch");
        assertEq(asset.decimals, 6, "Asset decimals mismatch");
        assertEq(asset.borrowThreshold, 900, "Borrow threshold mismatch");
        assertEq(asset.liquidationThreshold, 950, "Liquidation threshold mismatch");
        assertEq(asset.maxSupplyThreshold, 1_000_000e6, "Supply limit mismatch");
        // UPDATED: Use IASSETS.CollateralTier instead of IPROTOCOL.CollateralTier
        assertEq(uint8(asset.tier), uint8(IASSETS.CollateralTier.STABLE), "Tier mismatch");
        assertEq(asset.isolationDebtCap, 0, "Isolation debt cap should be 0 for STABLE assets");
    }

    function test_GetAssetInfo_Unlisted() public {
        // Using an address that's not configured as an asset
        address randomAddress = address(0x123);

        // UPDATED: Use assetsInstance and expect revert for unlisted asset
        vm.expectRevert(abi.encodeWithSelector(IASSETS.AssetNotListed.selector, randomAddress));
        assetsInstance.getAssetInfo(randomAddress);
    }

    function test_GetAssetInfo_AfterUpdate() public {
        vm.startPrank(address(timelockInstance));

        // UPDATED: Update WETH configuration using assetsInstance
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8, // Oracle decimals
            18, // Asset decimals
            0, // Set to inactive
            750, // Change borrow threshold
            800, // Change liquidation threshold
            500_000 ether, // Lower supply limit
            1_000_000e6, // Add isolation debt cap
            IASSETS.CollateralTier.CROSS_B, // Change tier
            IASSETS.OracleType.CHAINLINK
        );

        vm.stopPrank();

        // UPDATED: Use assetsInstance for getAssetInfo
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));

        assertEq(asset.active, 0, "WETH should be inactive after update");
        assertEq(asset.borrowThreshold, 750, "Borrow threshold should be updated");
        assertEq(asset.liquidationThreshold, 800, "Liquidation threshold should be updated");
        assertEq(asset.maxSupplyThreshold, 500_000 ether, "Supply limit should be updated");
        // UPDATED: Use IASSETS.CollateralTier instead of IPROTOCOL.CollateralTier
        assertEq(uint8(asset.tier), uint8(IASSETS.CollateralTier.CROSS_B), "Tier should be updated");
        assertEq(asset.isolationDebtCap, 1_000_000e6, "Isolation debt cap should be updated");
    }
}
