// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {Lendefi} from "../../contracts/lender/Lendefi.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract LendefiUpgradeTest is BasicDeploy {
    // Events
    event UpgradeScheduled(
        address indexed scheduler, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );
    event UpgradeCancelled(address indexed canceller, address indexed implementation);

    // Custom errors
    error ZeroAddressNotAllowed();
    error UpgradeTimelockActive(uint256 timeRemaining);
    error UpgradeNotScheduled();
    error ImplementationMismatch(address scheduledImpl, address attemptedImpl);

    // New mock implementation for testing
    address mockImplementation = address(0x123456);
    address mockImplementation2 = address(0x654321);

    function setUp() public {
        // Use deployCompleteWithOracle() instead of deployComplete()
        deployCompleteWithOracle();
        assertEq(tokenInstance.totalSupply(), 0);
    }

    function test_UpgradeTimelockRemaining() public {
        // Initially should be zero since no upgrade is scheduled
        assertEq(LendefiInstance.upgradeTimelockRemaining(), 0);

        // Schedule an upgrade
        vm.prank(gnosisSafe);
        LendefiInstance.scheduleUpgrade(mockImplementation);

        // Should now return the full timelock duration (3 days)
        assertEq(LendefiInstance.upgradeTimelockRemaining(), 3 days);

        // Fast forward 1 day
        vm.warp(block.timestamp + 1 days);

        // Should now return 2 days
        assertEq(LendefiInstance.upgradeTimelockRemaining(), 2 days);

        // Fast forward past the timelock
        vm.warp(block.timestamp + 2 days + 1);

        // Should return 0 again as timelock has expired
        assertEq(LendefiInstance.upgradeTimelockRemaining(), 0);
    }

    function test_ScheduleUpgrade() public {
        // Get current time for event verification
        uint64 currentTime = uint64(block.timestamp);
        uint64 effectiveTime = currentTime + uint64(LendefiInstance.UPGRADE_TIMELOCK_DURATION());

        // Schedule upgrade
        vm.prank(gnosisSafe);
        vm.expectEmit(true, true, true, true);
        emit UpgradeScheduled(gnosisSafe, mockImplementation, currentTime, effectiveTime);
        LendefiInstance.scheduleUpgrade(mockImplementation);

        // Verify upgrade request was stored
        (address impl, uint64 scheduledTime, bool exists) = LendefiInstance.pendingUpgrade();
        assertEq(impl, mockImplementation);
        assertEq(scheduledTime, currentTime);
        assertTrue(exists);
    }

    function testRevert_ScheduleUpgradeZeroAddress() public {
        vm.prank(gnosisSafe);
        vm.expectRevert(ZeroAddressNotAllowed.selector);
        LendefiInstance.scheduleUpgrade(address(0));
    }

    function testRevert_ScheduleUpgradealice() public {
        vm.prank(alice);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, UPGRADER_ROLE)
        );
        LendefiInstance.scheduleUpgrade(mockImplementation);
    }

    function test_CancelUpgrade() public {
        // Schedule an upgrade first
        vm.prank(gnosisSafe);
        LendefiInstance.scheduleUpgrade(mockImplementation);

        // Then cancel it
        vm.prank(gnosisSafe);
        vm.expectEmit(true, true, false, false);
        emit UpgradeCancelled(gnosisSafe, mockImplementation);
        LendefiInstance.cancelUpgrade();

        // Verify upgrade request was cleared
        (address impl, uint64 scheduledTime, bool exists) = LendefiInstance.pendingUpgrade();
        assertEq(impl, address(0));
        assertEq(scheduledTime, 0);
        assertFalse(exists);
    }

    function testRevert_CancelUpgradeUnauthorized() public {
        // Schedule an upgrade first
        vm.prank(gnosisSafe);
        LendefiInstance.scheduleUpgrade(mockImplementation);

        // Attempt alice cancellation
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, UPGRADER_ROLE)
        );
        LendefiInstance.cancelUpgrade();
    }

    function testRevert_CancelNonExistentUpgrade() public {
        vm.prank(gnosisSafe);
        vm.expectRevert(UpgradeNotScheduled.selector);
        LendefiInstance.cancelUpgrade();
    }

    function test_CompleteTimelockUpgradeProcess() public {
        // Deploy a test implementation contract to upgrade to
        Lendefi newImplementation = new Lendefi();

        // Schedule the upgrade
        vm.prank(gnosisSafe);
        LendefiInstance.scheduleUpgrade(address(newImplementation));

        // Verify we can't upgrade yet due to timelock
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSelector(UpgradeTimelockActive.selector, 3 days));
        LendefiInstance.upgradeToAndCall(address(newImplementation), "");

        // Fast forward past the timelock period
        vm.warp(block.timestamp + 3 days + 1);

        // Now the upgrade should succeed
        vm.prank(gnosisSafe);
        vm.expectEmit(true, true, false, false);
        emit Upgrade(gnosisSafe, address(newImplementation));
        LendefiInstance.upgradeToAndCall(address(newImplementation), "");

        // Verify version was incremented (assuming initial version was 1)
        assertEq(LendefiInstance.version(), 2);

        // Verify the pending upgrade was cleared
        (,, bool exists) = LendefiInstance.pendingUpgrade();
        assertFalse(exists);
    }

    function testRevert_UpgradeWithoutScheduling() public {
        // Deploy a test implementation contract
        Lendefi newImplementation = new Lendefi();

        // Try to upgrade without scheduling first
        vm.prank(gnosisSafe);
        vm.expectRevert(UpgradeNotScheduled.selector);
        LendefiInstance.upgradeToAndCall(address(newImplementation), "");
    }

    function testRevert_UpgradeWithWrongImplementation() public {
        // Deploy two different implementations
        Lendefi scheduledImpl = new Lendefi();
        Lendefi attemptedImpl = new Lendefi();

        // Schedule the first implementation
        vm.prank(gnosisSafe);
        LendefiInstance.scheduleUpgrade(address(scheduledImpl));

        // Fast forward past the timelock period
        vm.warp(block.timestamp + 3 days + 1);

        // Try to upgrade with the wrong implementation
        vm.prank(gnosisSafe);
        vm.expectRevert(
            abi.encodeWithSelector(ImplementationMismatch.selector, address(scheduledImpl), address(attemptedImpl))
        );
        LendefiInstance.upgradeToAndCall(address(attemptedImpl), "");
    }

    function test_ScheduleNewUpgradeAfterCancellation() public {
        // Schedule first upgrade
        vm.prank(gnosisSafe);
        LendefiInstance.scheduleUpgrade(mockImplementation);

        // Cancel it
        vm.prank(gnosisSafe);
        LendefiInstance.cancelUpgrade();

        // Schedule a different upgrade
        vm.prank(gnosisSafe);
        LendefiInstance.scheduleUpgrade(mockImplementation2);

        // Verify the new upgrade was scheduled
        (address impl,, bool exists) = LendefiInstance.pendingUpgrade();
        assertEq(impl, mockImplementation2);
        assertTrue(exists);
    }

    function test_RescheduleUpgrade() public {
        // Schedule first upgrade
        vm.prank(gnosisSafe);
        LendefiInstance.scheduleUpgrade(mockImplementation);

        // Schedule a new upgrade (implicitly overwrites the first one)
        vm.prank(gnosisSafe);
        LendefiInstance.scheduleUpgrade(mockImplementation2);

        // Verify the second upgrade was scheduled
        (address impl,, bool exists) = LendefiInstance.pendingUpgrade();
        assertEq(impl, mockImplementation2);
        assertTrue(exists);
    }
}
