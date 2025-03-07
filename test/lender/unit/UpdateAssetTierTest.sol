// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {ILendefiAssets} from "../../../contracts/interfaces/ILendefiAssets.sol";
import {Lendefi} from "../../../contracts/lender/Lendefi.sol";
import {console2} from "forge-std/console2.sol";
import {MockPriceOracle} from "../../../contracts/mock/MockPriceOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract UpdateAssetTierTest is BasicDeploy {
    // Events
    event AssetTierUpdated(address indexed asset, ILendefiAssets.CollateralTier tier);

    MockPriceOracle internal wethOracle;
    MockPriceOracle internal usdcOracle;

    function setUp() public {
        // Use the complete deployment function that includes Oracle module
        deployCompleteWithOracle();

        // TGE setup
        vm.prank(guardian);
        tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));

        // Deploy WETH if not already deployed
        if (address(wethInstance) == address(0)) {
            wethInstance = new WETH9();
        }

        // Set up mock oracles - use MockPriceOracle for more control over test values
        wethOracle = new MockPriceOracle();
        wethOracle.setPrice(2500e8); // $2500 per ETH
        wethOracle.setTimestamp(block.timestamp);
        wethOracle.setRoundId(1);
        wethOracle.setAnsweredInRound(1);

        usdcOracle = new MockPriceOracle();
        usdcOracle.setPrice(1e8); // $1 per USDC
        usdcOracle.setTimestamp(block.timestamp);
        usdcOracle.setRoundId(1);
        usdcOracle.setAnsweredInRound(1);

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(wethInstance), address(wethOracle), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracle));

        oracleInstance.addOracle(address(usdcInstance), address(usdcOracle), 8);
        oracleInstance.setPrimaryOracle(address(usdcInstance), address(usdcOracle));

        // Add WETH as CROSS_A initially
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracle),
            8, // oracle decimals
            18, // asset decimals
            1, // active
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether, // max supply
            ILendefiAssets.CollateralTier.CROSS_A,
            0 // no isolation debt cap
        );

        // Add USDC as STABLE initially
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            address(usdcOracle),
            8, // oracle decimals
            6, // asset decimals
            1, // active
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            10_000_000e6, // max supply
            ILendefiAssets.CollateralTier.STABLE,
            0 // no isolation debt cap
        );

        vm.stopPrank();
    }

    function test_UpdateAssetTier_AccessControl() public {
        // Regular user should not be able to update asset tier
        vm.startPrank(alice);

        // Using OpenZeppelin v5.0 AccessControl error format
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, keccak256("MANAGER_ROLE")
            )
        );

        // Call to assetsInstance instead of LendefiInstance
        assetsInstance.updateAssetTier(address(wethInstance), ILendefiAssets.CollateralTier.ISOLATED);
        vm.stopPrank();

        // Manager should be able to update asset tier
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetTier(address(wethInstance), ILendefiAssets.CollateralTier.ISOLATED);

        // Verify tier was updated
        ILendefiAssets.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(ILendefiAssets.CollateralTier.ISOLATED));
    }

    function testRevert_UpdateAssetTier_RequireAssetListed() public {
        address unlisted = address(0x123); // Random unlisted address

        vm.startPrank(address(timelockInstance));

        // Using custom error format in LendefiAssets
        vm.expectRevert(abi.encodeWithSelector(ILendefiAssets.AssetNotListed.selector, unlisted));
        assetsInstance.updateAssetTier(unlisted, ILendefiAssets.CollateralTier.ISOLATED);
        vm.stopPrank();
    }

    function test_UpdateAssetTier_StateChange_AllTiers() public {
        // Test updating to each possible tier
        vm.startPrank(address(timelockInstance));

        // Update to ISOLATED
        assetsInstance.updateAssetTier(address(wethInstance), ILendefiAssets.CollateralTier.ISOLATED);
        ILendefiAssets.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(ILendefiAssets.CollateralTier.ISOLATED));

        // Update to CROSS_A
        assetsInstance.updateAssetTier(address(wethInstance), ILendefiAssets.CollateralTier.CROSS_A);
        asset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(ILendefiAssets.CollateralTier.CROSS_A));

        // Update to CROSS_B
        assetsInstance.updateAssetTier(address(wethInstance), ILendefiAssets.CollateralTier.CROSS_B);
        asset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(ILendefiAssets.CollateralTier.CROSS_B));

        // Update to STABLE
        assetsInstance.updateAssetTier(address(wethInstance), ILendefiAssets.CollateralTier.STABLE);
        asset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(ILendefiAssets.CollateralTier.STABLE));

        vm.stopPrank();
    }

    function test_UpdateAssetTier_MultipleAssets() public {
        vm.startPrank(address(timelockInstance));

        // Update WETH to ISOLATED
        assetsInstance.updateAssetTier(address(wethInstance), ILendefiAssets.CollateralTier.ISOLATED);
        ILendefiAssets.Asset memory wethAsset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(wethAsset.tier), uint256(ILendefiAssets.CollateralTier.ISOLATED));

        // Update USDC to CROSS_B
        assetsInstance.updateAssetTier(address(usdcInstance), ILendefiAssets.CollateralTier.CROSS_B);
        ILendefiAssets.Asset memory usdcAsset = assetsInstance.getAssetInfo(address(usdcInstance));
        assertEq(uint256(usdcAsset.tier), uint256(ILendefiAssets.CollateralTier.CROSS_B));

        // Ensure updates are independent
        wethAsset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(wethAsset.tier), uint256(ILendefiAssets.CollateralTier.ISOLATED));

        vm.stopPrank();
    }

    function test_UpdateAssetTier_EventEmission() public {
        // The second parameter needs to be a uint8 representation of the enum
        vm.expectEmit(true, true, false, false);
        emit AssetTierUpdated(address(wethInstance), ILendefiAssets.CollateralTier.ISOLATED);

        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetTier(address(wethInstance), ILendefiAssets.CollateralTier.ISOLATED);
    }

    function test_UpdateAssetTier_NoChangeWhenSameTier() public {
        vm.startPrank(address(timelockInstance));

        // Get initial tier
        ILendefiAssets.Asset memory initialAsset = assetsInstance.getAssetInfo(address(wethInstance));
        ILendefiAssets.CollateralTier initialTier = initialAsset.tier;

        // The second parameter is also indexed in the contract
        vm.expectEmit(true, true, false, false);
        emit AssetTierUpdated(address(wethInstance), initialTier);

        // Update to same tier
        assetsInstance.updateAssetTier(address(wethInstance), initialTier);

        // Verify tier is unchanged
        ILendefiAssets.Asset memory updatedAsset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(updatedAsset.tier), uint256(initialTier));

        vm.stopPrank();
    }
}
