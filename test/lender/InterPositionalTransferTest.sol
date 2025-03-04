// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";

contract InterPositionalTransferTest is BasicDeploy {
    // Event to verify
    event InterPositionalTransfer(
        address indexed user,
        uint256 indexed fromPositionId,
        uint256 indexed toPositionId,
        address asset,
        uint256 amount
    );

    MockRWA internal rwaToken;
    MockRWA internal stableToken;
    WETHPriceConsumerV3 internal wethOracleInstance;
    RWAPriceConsumerV3 internal rwaOracleInstance;
    RWAPriceConsumerV3 internal stableOracleInstance;

    function setUp() public {
        deployCompleteWithOracle();

        // Deploy test tokens
        wethInstance = new WETH9();
        rwaToken = new MockRWA("RWA Token", "RWA");
        stableToken = new MockRWA("USDT", "USDT");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        wethOracleInstance.setPrice(2000e8); // $2000 per ETH

        rwaOracleInstance = new RWAPriceConsumerV3();
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token

        stableOracleInstance = new RWAPriceConsumerV3();
        stableOracleInstance.setPrice(1e8); // $1 per USDT

        // Configure oracles
        vm.startPrank(address(timelockInstance));

        oracleInstance.addOracle(address(wethInstance), address(wethOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(wethInstance), address(wethOracleInstance));

        oracleInstance.addOracle(address(rwaToken), address(rwaOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(rwaToken), address(rwaOracleInstance));

        oracleInstance.addOracle(address(stableToken), address(stableOracleInstance), 8);
        oracleInstance.setPrimaryOracle(address(stableToken), address(stableOracleInstance));

        // Configure assets
        LendefiInstance.updateAssetConfig(
            address(wethInstance),
            address(wethOracleInstance),
            8,
            18,
            1,
            800, // 80% borrow threshold
            850, // 85% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.CROSS_A,
            0
        );

        LendefiInstance.updateAssetConfig(
            address(rwaToken),
            address(rwaOracleInstance),
            8,
            18,
            1,
            650, // 65% borrow threshold
            750, // 75% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.ISOLATED,
            100_000e6 // Isolation debt cap
        );

        LendefiInstance.updateAssetConfig(
            address(stableToken),
            address(stableOracleInstance),
            8,
            18,
            1,
            900, // 90% borrow threshold
            950, // 95% liquidation threshold
            1_000_000 ether,
            IPROTOCOL.CollateralTier.STABLE,
            0
        );

        vm.stopPrank();

        // Add liquidity to protocol
        usdcInstance.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(LendefiInstance), 1_000_000e6);
        LendefiInstance.supplyLiquidity(1_000_000e6);
        vm.stopPrank();
    }

    // Helper functions
    function _createPosition(address user, address asset, bool isIsolated) internal returns (uint256) {
        vm.startPrank(user);
        LendefiInstance.createPosition(asset, isIsolated);
        uint256 positionId = LendefiInstance.getUserPositionsCount(user) - 1;
        vm.stopPrank();
        return positionId;
    }

    function _mintAndSupply(address user, address asset, uint256 positionId, uint256 amount) internal {
        if (asset == address(wethInstance)) {
            vm.deal(user, amount);
            vm.startPrank(user);
            wethInstance.deposit{value: amount}();
            wethInstance.approve(address(LendefiInstance), amount);
        } else {
            MockRWA(asset).mint(user, amount);
            vm.startPrank(user);
            MockRWA(asset).approve(address(LendefiInstance), amount);
        }

        LendefiInstance.supplyCollateral(asset, amount, positionId);
        vm.stopPrank();
    }

    // Test 1: Basic transfer between two cross-collateral positions
    function test_CrossToCrossTransfer() public {
        // Create two cross-collateral positions
        uint256 fromPositionId = _createPosition(bob, address(wethInstance), false);
        uint256 toPositionId = _createPosition(bob, address(wethInstance), false);

        // Supply collateral to source position
        _mintAndSupply(bob, address(wethInstance), fromPositionId, 10 ether);

        // Perform transfer
        vm.startPrank(bob);
        vm.expectEmit(true, true, true, true);
        emit InterPositionalTransfer(bob, fromPositionId, toPositionId, address(wethInstance), 5 ether);

        LendefiInstance.interpositionalTransfer(fromPositionId, toPositionId, address(wethInstance), 5 ether);
        vm.stopPrank();

        // Verify balances
        uint256 sourceBalance = LendefiInstance.getUserCollateralAmount(bob, fromPositionId, address(wethInstance));
        uint256 targetBalance = LendefiInstance.getUserCollateralAmount(bob, toPositionId, address(wethInstance));

        assertEq(sourceBalance, 5 ether, "Source balance incorrect");
        assertEq(targetBalance, 5 ether, "Target balance incorrect");
    }

    // Test 2: Isolation mode prevents transfers
    function test_IsolatedPositionsBlockTransfers() public {
        // Create isolated position and cross-collateral position
        uint256 isolatedPositionId = _createPosition(bob, address(rwaToken), true);
        uint256 crossPositionId = _createPosition(bob, address(wethInstance), false);

        // Supply collateral to both
        _mintAndSupply(bob, address(rwaToken), isolatedPositionId, 10 ether);
        _mintAndSupply(bob, address(wethInstance), crossPositionId, 10 ether);

        // Attempt transfer from isolated position - should fail
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.IsolationModeForbidden.selector));

        LendefiInstance.interpositionalTransfer(isolatedPositionId, crossPositionId, address(rwaToken), 5 ether);
        vm.stopPrank();

        // Attempt transfer to isolated position - should also fail
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.IsolationModeForbidden.selector));

        LendefiInstance.interpositionalTransfer(crossPositionId, isolatedPositionId, address(wethInstance), 5 ether);
        vm.stopPrank();
    }

    // Test 3: Insufficient balance check
    function test_InsufficientBalance() public {
        // Create two cross-collateral positions
        uint256 fromPositionId = _createPosition(bob, address(wethInstance), false);
        uint256 toPositionId = _createPosition(bob, address(wethInstance), false);

        // Supply a small amount of collateral
        _mintAndSupply(bob, address(wethInstance), fromPositionId, 1 ether);

        // Try to transfer more than available
        vm.startPrank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPROTOCOL.InsufficientCollateralBalance.selector,
                bob,
                fromPositionId,
                address(wethInstance),
                2 ether,
                1 ether
            )
        );

        LendefiInstance.interpositionalTransfer(fromPositionId, toPositionId, address(wethInstance), 2 ether);
        vm.stopPrank();
    }

    // Test 6: Asset removal when fully transferred
    function test_AssetRemovalWhenFullyTransferred() public {
        // Create two cross-collateral positions
        uint256 fromPositionId = _createPosition(bob, address(wethInstance), false);
        uint256 toPositionId = _createPosition(bob, address(wethInstance), false);

        // Supply collateral to source position
        _mintAndSupply(bob, address(wethInstance), fromPositionId, 5 ether);
        _mintAndSupply(bob, address(stableToken), fromPositionId, 1000 ether);

        // Transfer all of the WETH
        vm.prank(bob);
        LendefiInstance.interpositionalTransfer(fromPositionId, toPositionId, address(wethInstance), 5 ether);

        // Check that WETH is no longer in source position's assets list
        address[] memory sourceAssets = LendefiInstance.getPositionCollateralAssets(bob, fromPositionId);
        bool containsWeth = false;

        for (uint256 i = 0; i < sourceAssets.length; i++) {
            if (sourceAssets[i] == address(wethInstance)) {
                containsWeth = true;
                break;
            }
        }

        assertEq(containsWeth, false, "WETH should be removed from source position assets");
        assertEq(sourceAssets.length, 1, "Source should have only stable token left");
        assertEq(sourceAssets[0], address(stableToken), "Stable token should remain in source position");
    }

    // Test 7: Transfer with zero amount is allowed
    function test_ZeroTransferAllowed() public {
        // Create two cross-collateral positions
        uint256 fromPositionId = _createPosition(bob, address(wethInstance), false);
        uint256 toPositionId = _createPosition(bob, address(wethInstance), false);

        // Supply collateral to source position
        _mintAndSupply(bob, address(wethInstance), fromPositionId, 5 ether);

        // Transfer zero amount
        vm.prank(bob);
        LendefiInstance.interpositionalTransfer(fromPositionId, toPositionId, address(wethInstance), 0);

        // Check that balances are unchanged
        uint256 sourceBalance = LendefiInstance.getUserCollateralAmount(bob, fromPositionId, address(wethInstance));
        uint256 targetBalance = LendefiInstance.getUserCollateralAmount(bob, toPositionId, address(wethInstance));

        assertEq(sourceBalance, 5 ether, "Source balance should be unchanged");
        assertEq(targetBalance, 0, "Target balance should be zero");
    }

    // Test 8: Transfer when asset isn't listed in protocol
    function test_UnlistedAssetTransfer() public {
        // Create new token that isn't registered
        MockRWA unlistedToken = new MockRWA("Unlisted", "UNLT");

        // Create two cross-collateral positions
        uint256 fromPositionId = _createPosition(bob, address(wethInstance), false);
        uint256 toPositionId = _createPosition(bob, address(wethInstance), false);

        // Try to transfer unlisted asset
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.AssetNotListed.selector, address(unlistedToken)));

        LendefiInstance.interpositionalTransfer(fromPositionId, toPositionId, address(unlistedToken), 1 ether);
        vm.stopPrank();
    }

    function test_MaintainsCollateralizationCheck() public {
        // Create two cross-collateral positions
        uint256 fromPositionId = _createPosition(bob, address(wethInstance), false);
        uint256 toPositionId = _createPosition(bob, address(wethInstance), false);

        // Supply collateral and borrow against it
        _mintAndSupply(bob, address(wethInstance), fromPositionId, 10 ether); // $20,000 worth

        vm.startPrank(bob);
        LendefiInstance.borrow(fromPositionId, 12000e6); // $12,000 (80% of collateral value)

        // Try to transfer most of collateral - would make position undercollateralized
        vm.expectRevert(); // Just check that it reverts

        LendefiInstance.interpositionalTransfer(fromPositionId, toPositionId, address(wethInstance), 7.5 ether);

        // Transfer a smaller amount that maintains collateralization
        LendefiInstance.interpositionalTransfer(fromPositionId, toPositionId, address(wethInstance), 1 ether);
        vm.stopPrank();

        // Verify balances
        uint256 sourceBalance = LendefiInstance.getUserCollateralAmount(bob, fromPositionId, address(wethInstance));
        uint256 targetBalance = LendefiInstance.getUserCollateralAmount(bob, toPositionId, address(wethInstance));

        assertEq(sourceBalance, 9 ether, "Source balance incorrect");
        assertEq(targetBalance, 1 ether, "Target balance incorrect");
    }

    function test_AssetLimitCheck() public {
        // Create two cross-collateral positions
        uint256 fromPositionId = _createPosition(bob, address(wethInstance), false);
        uint256 toPositionId = _createPosition(bob, address(wethInstance), false);

        // Supply WETH to both positions - this is important!
        _mintAndSupply(bob, address(wethInstance), fromPositionId, 10 ether);
        _mintAndSupply(bob, address(wethInstance), toPositionId, 1 ether); // WETH counts as 1st asset in target

        // Add 19 MORE assets to target position to reach limit of 20 total
        for (uint256 i = 0; i < 19; i++) {
            MockRWA token = new MockRWA(string(abi.encodePacked("Token", i)), string(abi.encodePacked("TKN", i)));

            // Register the asset in protocol
            RWAPriceConsumerV3 oracle_ = new RWAPriceConsumerV3();
            oracle_.setPrice(100e8);

            vm.startPrank(address(timelockInstance));
            oracleInstance.addOracle(address(token), address(oracle_), 8);
            oracleInstance.setPrimaryOracle(address(token), address(oracle_));

            LendefiInstance.updateAssetConfig(
                address(token),
                address(oracle_),
                8,
                18,
                1,
                800,
                850,
                1_000_000 ether,
                IPROTOCOL.CollateralTier.STABLE,
                0
            );
            vm.stopPrank();

            // Add to target position
            _mintAndSupply(bob, address(token), toPositionId, 1 ether);
        }

        // Verify target position has exactly 20 assets now
        address[] memory targetAssets = LendefiInstance.getPositionCollateralAssets(bob, toPositionId);
        assertEq(targetAssets.length, 20, "Target position should have exactly 20 assets before testing the limit");

        // Create a new 21st asset
        MockRWA extraToken = new MockRWA("Extra", "XTRA");

        // Register it
        RWAPriceConsumerV3 oracle = new RWAPriceConsumerV3();
        oracle.setPrice(100e8);

        vm.startPrank(address(timelockInstance));
        oracleInstance.addOracle(address(extraToken), address(oracle), 8);
        oracleInstance.setPrimaryOracle(address(extraToken), address(oracle));

        LendefiInstance.updateAssetConfig(
            address(extraToken),
            address(oracle),
            8,
            18,
            1,
            800,
            850,
            1_000_000 ether,
            IPROTOCOL.CollateralTier.STABLE,
            0
        );
        vm.stopPrank();

        // Add to source position
        _mintAndSupply(bob, address(extraToken), fromPositionId, 1 ether);

        // Now try to transfer it, which would exceed the 20 asset limit
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.TooManyAssets.selector, bob, toPositionId));

        LendefiInstance.interpositionalTransfer(fromPositionId, toPositionId, address(extraToken), 0.5 ether);
    }
}
