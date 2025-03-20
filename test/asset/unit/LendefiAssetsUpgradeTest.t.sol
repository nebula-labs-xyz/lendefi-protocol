// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {LendefiAssets} from "../../../contracts/lender/LendefiAssets.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";

/**
 * @title LendefiAssetsUpgradeTest
 * @notice Tests for the timelocked upgrade functionality in LendefiAssets
 */
contract LendefiAssetsUpgradeTest is BasicDeploy {
    // Custom errors from the contract - importing directly to avoid shadowing
    error ZeroAddressNotAllowed();
    error UpgradeTimelockActive(uint256 timeRemaining);
    error UpgradeNotScheduled();
    error ImplementationMismatch(address scheduledImpl, address attemptedImpl);

    // Events to check
    event UpgradeScheduled(
        address indexed scheduler, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );
    event UpgradeCancelled(address indexed canceller, address indexed implementation);

    function setUp() public {
        // Deploy assets module and associated contracts
        deployComplete();
        _deployAssetsModule();

        // Ensure we have the necessary roles for testing
        // vm.startPrank(address(timelockInstance));
        // assetsInstance.grantRole(UPGRADER_ROLE, gnosisSafe);
        // vm.stopPrank();
    }

    function test_ScheduleUpgrade() public {
        // Deploy a new implementation
        LendefiAssets newImplementation = new LendefiAssets();

        // Get current time for event verification
        uint64 currentTime = uint64(block.timestamp);
        uint64 effectiveTime = currentTime + uint64(3 days); // UPGRADE_TIMELOCK_DURATION

        // Schedule the upgrade
        vm.prank(gnosisSafe);
        vm.expectEmit(true, true, true, true);
        emit UpgradeScheduled(gnosisSafe, address(newImplementation), currentTime, effectiveTime);
        assetsInstance.scheduleUpgrade(address(newImplementation));

        // Verify upgrade request was stored correctly
        (address impl, uint64 scheduledTime, bool exists) = assetsInstance.pendingUpgrade();
        assertEq(impl, address(newImplementation));
        assertEq(scheduledTime, currentTime);
        assertTrue(exists);
    }

    function testRevert_ScheduleUpgradeZeroAddress() public {
        // Schedule upgrade with zero address
        vm.prank(gnosisSafe);
        vm.expectRevert(ZeroAddressNotAllowed.selector);
        assetsInstance.scheduleUpgrade(address(0));
    }

    function testRevert_ScheduleUpgradeUnauthorized() public {
        LendefiAssets newImplementation = new LendefiAssets();

        // Try to schedule an upgrade without proper role
        address unauthorized = address(0x123);
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, UPGRADER_ROLE
            )
        );
        assetsInstance.scheduleUpgrade(address(newImplementation));
    }

    function test_CancelUpgrade() public {
        // Deploy a new implementation
        LendefiAssets newImplementation = new LendefiAssets();

        // Schedule an upgrade first
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(newImplementation));

        // Then cancel it
        vm.prank(gnosisSafe);
        vm.expectEmit(true, true, false, false);
        emit UpgradeCancelled(gnosisSafe, address(newImplementation));
        assetsInstance.cancelUpgrade();

        // Verify upgrade request was cleared
        (address impl, uint64 scheduledTime, bool exists) = assetsInstance.pendingUpgrade();
        assertEq(impl, address(0));
        assertEq(scheduledTime, 0);
        assertFalse(exists);
    }

    function testRevert_CancelUpgradeUnauthorized() public {
        // Deploy a new implementation
        LendefiAssets newImplementation = new LendefiAssets();

        // Schedule an upgrade first
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(newImplementation));

        // Attempt unauthorized cancellation
        address unauthorized = address(0x123);
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, UPGRADER_ROLE
            )
        );
        assetsInstance.cancelUpgrade();
    }

    function testRevert_CancelNonExistentUpgrade() public {
        // Try to cancel when no upgrade is scheduled
        vm.prank(gnosisSafe);
        vm.expectRevert(UpgradeNotScheduled.selector);
        assetsInstance.cancelUpgrade();
    }

    function test_UpgradeTimelockRemaining() public {
        // Deploy a new implementation
        LendefiAssets newImplementation = new LendefiAssets();

        // Before scheduling, should return 0
        assertEq(assetsInstance.upgradeTimelockRemaining(), 0);

        // Schedule an upgrade
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(newImplementation));

        // Should now return the full timelock duration (3 days)
        assertEq(assetsInstance.upgradeTimelockRemaining(), 3 days);

        // Fast forward 1 day
        vm.warp(block.timestamp + 1 days);

        // Should now return 2 days left
        assertEq(assetsInstance.upgradeTimelockRemaining(), 2 days);

        // Fast forward past the timelock
        vm.warp(block.timestamp + 2 days + 1);

        // Should return 0 again as timelock has expired
        assertEq(assetsInstance.upgradeTimelockRemaining(), 0);
    }

    function test_CompleteTimelockUpgradeProcess() public {
        // Deploy a new implementation
        LendefiAssets newImplementation = new LendefiAssets();

        // Schedule the upgrade
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(newImplementation));

        // Verify we can't upgrade yet due to timelock
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSelector(UpgradeTimelockActive.selector, 3 days));
        assetsInstance.upgradeToAndCall(address(newImplementation), "");

        // Fast forward past the timelock period
        vm.warp(block.timestamp + 3 days + 1);

        // Now the upgrade should succeed
        vm.prank(gnosisSafe);
        vm.expectEmit(true, true, false, false);
        emit Upgrade(gnosisSafe, address(newImplementation));
        assetsInstance.upgradeToAndCall(address(newImplementation), "");

        // Verify version was incremented
        assertEq(assetsInstance.version(), 2);

        // Verify the pending upgrade was cleared
        (,, bool exists) = assetsInstance.pendingUpgrade();
        assertFalse(exists);
    }

    function testRevert_UpgradeWithoutScheduling() public {
        // Deploy a new implementation
        LendefiAssets newImplementation = new LendefiAssets();

        // Try to upgrade without scheduling first
        vm.prank(gnosisSafe);
        vm.expectRevert(UpgradeNotScheduled.selector);
        assetsInstance.upgradeToAndCall(address(newImplementation), "");
    }

    function testRevert_UpgradeWithWrongImplementation() public {
        // Deploy two different implementations
        LendefiAssets scheduledImpl = new LendefiAssets();
        LendefiAssets attemptedImpl = new LendefiAssets();

        // Schedule the first implementation
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(scheduledImpl));

        // Fast forward past the timelock period
        vm.warp(block.timestamp + 3 days + 1);

        // Try to upgrade with the wrong implementation
        vm.prank(gnosisSafe);
        vm.expectRevert(
            abi.encodeWithSelector(ImplementationMismatch.selector, address(scheduledImpl), address(attemptedImpl))
        );
        assetsInstance.upgradeToAndCall(address(attemptedImpl), "");
    }

    function test_ScheduleNewUpgradeAfterCancellation() public {
        // Deploy implementations
        LendefiAssets firstImpl = new LendefiAssets();
        LendefiAssets secondImpl = new LendefiAssets();

        // Schedule first upgrade
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(firstImpl));

        // Cancel it
        vm.prank(gnosisSafe);
        assetsInstance.cancelUpgrade();

        // Schedule a different upgrade
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(secondImpl));

        // Verify the new upgrade was scheduled
        (address impl,, bool exists) = assetsInstance.pendingUpgrade();
        assertEq(impl, address(secondImpl));
        assertTrue(exists);
    }

    function test_RescheduleUpgrade() public {
        // Deploy implementations
        LendefiAssets firstImpl = new LendefiAssets();
        LendefiAssets secondImpl = new LendefiAssets();

        // Schedule first upgrade
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(firstImpl));

        // Schedule a new upgrade (implicitly cancels the first one)
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(secondImpl));

        // Verify the second upgrade was scheduled
        (address impl,, bool exists) = assetsInstance.pendingUpgrade();
        assertEq(impl, address(secondImpl));
        assertTrue(exists);
    }

    function test_UpgradeWhenPaused() public {
        // Deploy a new implementation
        LendefiAssets newImplementation = new LendefiAssets();

        // Schedule the upgrade
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(newImplementation));

        // Pause the contract
        vm.prank(gnosisSafe);
        assetsInstance.pause();

        // Fast forward past timelock
        vm.warp(block.timestamp + 3 days + 1);

        // Upgrade should still work even when paused
        vm.prank(gnosisSafe);
        assetsInstance.upgradeToAndCall(address(newImplementation), "");

        // Verify upgrade succeeded
        assertEq(assetsInstance.version(), 2);
    }

    function test_ScheduleUpgradeWhenPaused() public {
        // Pause the contract first
        vm.prank(gnosisSafe);
        assetsInstance.pause();

        // Try to schedule an upgrade while paused
        LendefiAssets newImplementation = new LendefiAssets();

        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(newImplementation));
    }

    function test_CancelUpgradeWhenPaused() public {
        // Deploy a new implementation
        LendefiAssets newImplementation = new LendefiAssets();

        // Schedule an upgrade
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(newImplementation));

        // Pause the contract
        vm.prank(gnosisSafe);
        assetsInstance.pause();

        // Try to cancel when paused
        vm.prank(gnosisSafe);
        assetsInstance.cancelUpgrade();
    }

    function test_UpgradeExactlyAtTimelock() public {
        // Deploy a new implementation
        LendefiAssets newImplementation = new LendefiAssets();

        // Schedule the upgrade
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(newImplementation));

        // Fast forward to 1 second BEFORE the timelock expiration
        vm.warp(block.timestamp + 3 days - 1);

        // Should revert since we're not yet past the timelock
        vm.prank(gnosisSafe);
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeTimelockActive.selector,
                1 // Since we're 1 second before timelock expiry, the remaining time is 1 second
            )
        );
        assetsInstance.upgradeToAndCall(address(newImplementation), "");

        // Now add just 1 more second to reach exactly the timelock expiration
        vm.warp(block.timestamp + 1);

        // At exactly 3 days, upgrade should succeed
        vm.prank(gnosisSafe);
        assetsInstance.upgradeToAndCall(address(newImplementation), "");

        // Verify upgrade succeeded
        assertEq(assetsInstance.version(), 2);
    }

    function test_MultipleConsecutiveUpgrades() public {
        // Deploy multiple implementation versions
        LendefiAssets implV2 = new LendefiAssets();
        LendefiAssets implV3 = new LendefiAssets();

        // Upgrade to V2
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(implV2));

        vm.warp(block.timestamp + 3 days + 1);

        vm.prank(gnosisSafe);
        assetsInstance.upgradeToAndCall(address(implV2), "");

        assertEq(assetsInstance.version(), 2, "First upgrade should set version to 2");

        // Upgrade to V3
        vm.prank(gnosisSafe);
        assetsInstance.scheduleUpgrade(address(implV3));

        vm.warp(block.timestamp + 3 days + 1);

        vm.prank(gnosisSafe);
        assetsInstance.upgradeToAndCall(address(implV3), "");

        assertEq(assetsInstance.version(), 3, "Second upgrade should set version to 3");
    }
}
