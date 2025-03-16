// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {LendefiYieldToken} from "../../contracts/lender/LendefiYieldToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LendefiYieldTokenTest is Test {
    LendefiYieldToken public implementation;
    LendefiYieldToken public yieldToken;

    address public guardian = address(0x1);
    address public protocol = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public unauthorized = address(0x5);
    address public timelock = address(0x6);
    address public multisig = address(0x7);

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant PROTOCOL_ROLE = keccak256("PROTOCOL_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Custom errors from the contract - importing directly to avoid shadowing
    error ZeroAddressNotAllowed();
    error UpgradeTimelockActive(uint256 timeRemaining);
    error UpgradeNotScheduled();
    error ImplementationMismatch(address scheduledImpl, address attemptedImpl);

    // Events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Paused(address account);
    event Unpaused(address account);
    event Initialized(address indexed admin);
    event Upgrade(address indexed upgrader, address indexed implementation);
    event UpgradeScheduled(
        address indexed scheduler, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );
    event UpgradeCancelled(address indexed canceller, address indexed implementation);

    function setUp() public {
        vm.label(guardian, "Guardian");
        vm.label(protocol, "Protocol");
        vm.label(user1, "User1");
        vm.label(user2, "User2");
        vm.label(unauthorized, "Unauthorized");
        vm.label(timelock, "Timelock");
        vm.label(multisig, "Multisig");

        // Deploy implementation
        implementation = new LendefiYieldToken();

        // Deploy proxy and initialize with all required parameters
        bytes memory initData =
            abi.encodeWithSelector(LendefiYieldToken.initialize.selector, protocol, timelock, guardian, multisig);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        yieldToken = LendefiYieldToken(address(proxy));
    }

    // ------ Initialization Tests ------

    function test_Initialization() public {
        assertEq(yieldToken.name(), "Lendefi Yield Token");
        assertEq(yieldToken.symbol(), "LYT");
        assertEq(yieldToken.decimals(), 6);
        assertEq(yieldToken.version(), 1);
        assertEq(yieldToken.totalSupply(), 0);

        // Check roles are assigned correctly
        assertTrue(yieldToken.hasRole(DEFAULT_ADMIN_ROLE, timelock));
        assertTrue(yieldToken.hasRole(PROTOCOL_ROLE, protocol));
        assertTrue(yieldToken.hasRole(PAUSER_ROLE, guardian));
        assertTrue(yieldToken.hasRole(UPGRADER_ROLE, multisig));
    }

    function testRevert_InitializeWithZeroAddress() public {
        // Create a new implementation
        LendefiYieldToken newImpl = new LendefiYieldToken();

        // Create a new proxy with the implementation but no initialization
        ERC1967Proxy proxy = new ERC1967Proxy(address(newImpl), "");
        LendefiYieldToken newToken = LendefiYieldToken(address(proxy));

        // Now try to initialize with zero address - should revert with ZeroAddressNotAllowed()
        vm.expectRevert(ZeroAddressNotAllowed.selector);
        newToken.initialize(address(0), timelock, guardian, multisig);
    }

    function testRevert_DoubleInitialization() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        yieldToken.initialize(protocol, timelock, guardian, multisig);
    }

    // ------ Role Management Tests ------

    function test_RoleAssignment() public {
        vm.startPrank(timelock);

        // Grant PROTOCOL_ROLE to user1
        yieldToken.grantRole(PROTOCOL_ROLE, user1);
        assertTrue(yieldToken.hasRole(PROTOCOL_ROLE, user1));

        // Revoke PROTOCOL_ROLE from user1
        yieldToken.revokeRole(PROTOCOL_ROLE, user1);
        assertFalse(yieldToken.hasRole(PROTOCOL_ROLE, user1));

        vm.stopPrank();
    }

    function testRevert_UnauthorizedRoleAssignment() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, DEFAULT_ADMIN_ROLE
            )
        );
        yieldToken.grantRole(PROTOCOL_ROLE, user1);
    }

    // ------ Minting Tests ------

    function test_Mint() public {
        uint256 mintAmount = 1000 * 10 ** 6; // 1000 tokens with 6 decimals

        vm.prank(protocol);
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), user1, mintAmount);
        yieldToken.mint(user1, mintAmount);

        assertEq(yieldToken.balanceOf(user1), mintAmount);
        assertEq(yieldToken.totalSupply(), mintAmount);
    }

    function testRevert_UnauthorizedMint() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, PROTOCOL_ROLE
            )
        );
        yieldToken.mint(user1, 1000 * 10 ** 6);
    }

    function testRevert_MintToZeroAddress() public {
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        yieldToken.mint(address(0), 1000 * 10 ** 6);
    }

    // ------ Burning Tests ------

    function test_Burn() public {
        uint256 mintAmount = 1000 * 10 ** 6;
        uint256 burnAmount = 400 * 10 ** 6;

        // First mint some tokens
        vm.prank(protocol);
        yieldToken.mint(user1, mintAmount);

        // Then burn part of them
        vm.prank(protocol);
        vm.expectEmit(true, true, false, true);
        emit Transfer(user1, address(0), burnAmount);
        yieldToken.burn(user1, burnAmount);

        assertEq(yieldToken.balanceOf(user1), mintAmount - burnAmount);
        assertEq(yieldToken.totalSupply(), mintAmount - burnAmount);
    }

    function testRevert_BurnMoreThanBalance() public {
        // Mint some tokens
        vm.prank(protocol);
        yieldToken.mint(user1, 100 * 10 ** 6);

        // Try to burn more than the balance
        vm.prank(protocol);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 100 * 10 ** 6, 200 * 10 ** 6)
        );
        yieldToken.burn(user1, 200 * 10 ** 6);
    }

    function testRevert_UnauthorizedBurn() public {
        // Mint some tokens
        vm.prank(protocol);
        yieldToken.mint(user1, 100 * 10 ** 6);

        // Try unauthorized burn
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, PROTOCOL_ROLE
            )
        );
        yieldToken.burn(user1, 50 * 10 ** 6);
    }

    // ------ Transfer Tests ------

    function test_Transfer() public {
        uint256 mintAmount = 1000 * 10 ** 6;
        uint256 transferAmount = 300 * 10 ** 6;

        // Mint tokens to user1
        vm.prank(protocol);
        yieldToken.mint(user1, mintAmount);

        // Transfer from user1 to user2
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit Transfer(user1, user2, transferAmount);
        yieldToken.transfer(user2, transferAmount);

        assertEq(yieldToken.balanceOf(user1), mintAmount - transferAmount);
        assertEq(yieldToken.balanceOf(user2), transferAmount);
    }

    function test_TransferFrom() public {
        uint256 mintAmount = 1000 * 10 ** 6;
        uint256 approveAmount = 500 * 10 ** 6;
        uint256 transferAmount = 300 * 10 ** 6;

        // Mint tokens to user1
        vm.prank(protocol);
        yieldToken.mint(user1, mintAmount);

        // User1 approves user2 to spend tokens
        vm.prank(user1);
        yieldToken.approve(user2, approveAmount);

        // User2 transfers tokens from user1 to himself
        vm.prank(user2);
        vm.expectEmit(true, true, false, true);
        emit Transfer(user1, user2, transferAmount);
        yieldToken.transferFrom(user1, user2, transferAmount);

        assertEq(yieldToken.balanceOf(user1), mintAmount - transferAmount);
        assertEq(yieldToken.balanceOf(user2), transferAmount);
        assertEq(yieldToken.allowance(user1, user2), approveAmount - transferAmount);
    }

    function testRevert_TransferExceedsBalance() public {
        // Mint tokens to user1
        vm.prank(protocol);
        yieldToken.mint(user1, 100 * 10 ** 6);

        // Try to transfer more than balance
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 100 * 10 ** 6, 200 * 10 ** 6)
        );
        yieldToken.transfer(user2, 200 * 10 ** 6);
    }

    function testRevert_TransferFromExceedsAllowance() public {
        // Mint tokens to user1
        vm.prank(protocol);
        yieldToken.mint(user1, 1000 * 10 ** 6);

        // User1 approves user2 to spend tokens
        vm.prank(user1);
        yieldToken.approve(user2, 200 * 10 ** 6);

        // Try to transfer more than allowance
        vm.prank(user2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, user2, 200 * 10 ** 6, 300 * 10 ** 6
            )
        );
        yieldToken.transferFrom(user1, user2, 300 * 10 ** 6);
    }

    // ------ Pause Functionality Tests ------

    function test_Pause() public {
        vm.prank(guardian);
        vm.expectEmit(false, false, false, true);
        emit Paused(guardian);
        yieldToken.pause();

        assertTrue(yieldToken.paused());
    }

    function test_Unpause() public {
        // First pause
        vm.prank(guardian);
        yieldToken.pause();

        // Then unpause
        vm.prank(guardian);
        vm.expectEmit(false, false, false, true);
        emit Unpaused(guardian);
        yieldToken.unpause();

        assertFalse(yieldToken.paused());
    }

    function testRevert_TransferWhenPaused() public {
        // Mint tokens to user1
        vm.prank(protocol);
        yieldToken.mint(user1, 1000 * 10 ** 6);

        // Pause the contract
        vm.prank(guardian);
        yieldToken.pause();

        // Try to transfer when paused
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        yieldToken.transfer(user2, 100 * 10 ** 6);
    }

    function testRevert_MintWhenPaused() public {
        // Pause the contract
        vm.prank(guardian);
        yieldToken.pause();

        // Try to mint when paused
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        yieldToken.mint(user1, 100 * 10 ** 6);
    }

    function testRevert_BurnWhenPaused() public {
        // First mint some tokens
        vm.prank(protocol);
        yieldToken.mint(user1, 1000 * 10 ** 6);

        // Pause the contract
        vm.prank(guardian);
        yieldToken.pause();

        // Try to burn when paused
        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        yieldToken.burn(user1, 100 * 10 ** 6);
    }

    function testRevert_UnauthorizedPause() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, PAUSER_ROLE)
        );
        yieldToken.pause();
    }

    function testRevert_UnauthorizedUnpause() public {
        // First pause
        vm.prank(guardian);
        yieldToken.pause();

        // Try unauthorized unpause
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, PAUSER_ROLE)
        );
        yieldToken.unpause();
    }

    // ------ Edge Cases and Validation Tests ------

    function test_ZeroAmountTransfer() public {
        // Mint some tokens to user1
        vm.prank(protocol);
        yieldToken.mint(user1, 1000 * 10 ** 6);

        // Transfer 0 tokens
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit Transfer(user1, user2, 0);
        yieldToken.transfer(user2, 0);

        // Balances should be unchanged
        assertEq(yieldToken.balanceOf(user1), 1000 * 10 ** 6);
        assertEq(yieldToken.balanceOf(user2), 0);
    }

    function test_MintZero() public {
        // Mint 0 tokens
        vm.prank(protocol);
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), user1, 0);
        yieldToken.mint(user1, 0);

        // Balance and supply should be 0
        assertEq(yieldToken.balanceOf(user1), 0);
        assertEq(yieldToken.totalSupply(), 0);
    }

    function test_BurnZero() public {
        // Mint some tokens to user1
        vm.prank(protocol);
        yieldToken.mint(user1, 1000 * 10 ** 6);

        // Burn 0 tokens
        vm.prank(protocol);
        vm.expectEmit(true, true, false, true);
        emit Transfer(user1, address(0), 0);
        yieldToken.burn(user1, 0);

        // Balance should be unchanged
        assertEq(yieldToken.balanceOf(user1), 1000 * 10 ** 6);
        assertEq(yieldToken.totalSupply(), 1000 * 10 ** 6);
    }

    function test_TransferToSelf() public {
        uint256 mintAmount = 1000 * 10 ** 6;

        // Mint tokens to user1
        vm.prank(protocol);
        yieldToken.mint(user1, mintAmount);

        // Transfer to self
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit Transfer(user1, user1, 500 * 10 ** 6);
        yieldToken.transfer(user1, 500 * 10 ** 6);

        // Balance should be unchanged
        assertEq(yieldToken.balanceOf(user1), mintAmount);
    }

    function test_ApproveMax() public {
        // Approve maximum possible amount
        vm.prank(user1);
        yieldToken.approve(user2, type(uint256).max);

        assertEq(yieldToken.allowance(user1, user2), type(uint256).max);
    }

    function test_DecimalsIsSix() public {
        assertEq(yieldToken.decimals(), 6, "Decimals should be 6 to match USDC");
    }

    function test_AccessBlockedAfterRoleRevocation() public {
        // First mint some tokens to demonstrate protocol access
        vm.prank(protocol);
        yieldToken.mint(user1, 1000 * 10 ** 6);

        // Admin revokes protocol role
        vm.prank(timelock);
        yieldToken.revokeRole(PROTOCOL_ROLE, protocol);

        // Protocol should no longer be able to mint
        vm.prank(protocol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, protocol, PROTOCOL_ROLE)
        );
        yieldToken.mint(user1, 1000 * 10 ** 6);
    }

    function test_RoleRenouncement() public {
        // Protocol renounces its role
        vm.prank(protocol);
        yieldToken.renounceRole(PROTOCOL_ROLE, protocol);

        // Protocol should no longer have the role
        assertFalse(yieldToken.hasRole(PROTOCOL_ROLE, protocol));

        // Protocol should no longer be able to mint
        vm.prank(protocol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, protocol, PROTOCOL_ROLE)
        );
        yieldToken.mint(user1, 1000 * 10 ** 6);
    }

    // ------ Timelocked Upgrade Tests ------

    function testRevert_UpgradeNotScheduled() public {
        // Deploy a new implementation
        LendefiYieldToken newImplementation = new LendefiYieldToken();

        vm.expectRevert(UpgradeNotScheduled.selector);
        vm.prank(multisig);
        yieldToken.upgradeToAndCall(address(newImplementation), "");

        assertEq(yieldToken.version(), 1);
    }

    function testRevert_UnauthorizedUpgrade() public {
        // Deploy a new implementation
        LendefiYieldToken newImplementation = new LendefiYieldToken();

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, UPGRADER_ROLE
            )
        );
        yieldToken.upgradeToAndCall(address(newImplementation), "");
    }

    function test_ScheduleUpgrade() public {
        address newImplementation = address(new LendefiYieldToken());

        // Get current time for event verification
        uint64 currentTime = uint64(block.timestamp);
        uint64 effectiveTime = currentTime + uint64(yieldToken.UPGRADE_TIMELOCK_DURATION());

        vm.prank(multisig); // Use multisig instead of guardian
        vm.expectEmit(true, true, true, true);
        emit UpgradeScheduled(multisig, newImplementation, currentTime, effectiveTime);
        yieldToken.scheduleUpgrade(newImplementation);

        // Verify upgrade request was stored correctly
        (address impl, uint64 scheduledTime, bool exists) = yieldToken.pendingUpgrade();
        assertEq(impl, newImplementation);
        assertEq(scheduledTime, currentTime);
        assertTrue(exists);
    }

    function testRevert_ScheduleUpgradeZeroAddress() public {
        vm.prank(multisig); // Use multisig instead of guardian
        vm.expectRevert(ZeroAddressNotAllowed.selector);
        yieldToken.scheduleUpgrade(address(0));
    }

    function testRevert_ScheduleUpgradeUnauthorized() public {
        address newImplementation = address(new LendefiYieldToken());

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, UPGRADER_ROLE
            )
        );
        yieldToken.scheduleUpgrade(newImplementation);
    }

    function test_CancelUpgrade() public {
        address newImplementation = address(new LendefiYieldToken());

        // Schedule an upgrade first
        vm.prank(multisig);
        yieldToken.scheduleUpgrade(newImplementation);

        // Then cancel it
        vm.prank(multisig);
        vm.expectEmit(true, true, false, false);
        emit UpgradeCancelled(multisig, newImplementation);
        yieldToken.cancelUpgrade();

        // Verify upgrade request was cleared
        (address impl, uint64 scheduledTime, bool exists) = yieldToken.pendingUpgrade();
        assertEq(impl, address(0));
        assertEq(scheduledTime, 0);
        assertFalse(exists);
    }

    function testRevert_CancelUpgradeUnauthorized() public {
        address newImplementation = address(new LendefiYieldToken());

        // Schedule an upgrade first
        vm.prank(multisig);
        yieldToken.scheduleUpgrade(newImplementation);

        // Attempt unauthorized cancellation
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, UPGRADER_ROLE
            )
        );
        yieldToken.cancelUpgrade();
    }

    function testRevert_CancelNonExistentUpgrade() public {
        vm.prank(multisig);
        vm.expectRevert(UpgradeNotScheduled.selector);
        yieldToken.cancelUpgrade();
    }

    function test_UpgradeTimelockRemaining() public {
        address newImplementation = address(new LendefiYieldToken());

        // Before scheduling, should return 0
        assertEq(yieldToken.upgradeTimelockRemaining(), 0);

        // Schedule an upgrade
        vm.prank(multisig);
        yieldToken.scheduleUpgrade(newImplementation);

        // Should now return the full timelock duration
        assertEq(yieldToken.upgradeTimelockRemaining(), yieldToken.UPGRADE_TIMELOCK_DURATION());

        // Fast forward 1 day
        vm.warp(block.timestamp + 1 days);

        // Should now return 2 days left
        assertEq(yieldToken.upgradeTimelockRemaining(), 2 days);

        // Fast forward past the timelock
        vm.warp(block.timestamp + 2 days + 1);

        // Should return 0 again as timelock has expired
        assertEq(yieldToken.upgradeTimelockRemaining(), 0);
    }

    function test_CompleteTimelockUpgradeProcess() public {
        // Deploy a new implementation
        LendefiYieldToken newImplementation = new LendefiYieldToken();

        // Schedule the upgrade
        vm.prank(multisig);
        yieldToken.scheduleUpgrade(address(newImplementation));

        // Verify we can't upgrade yet due to timelock
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(UpgradeTimelockActive.selector, 3 days));
        yieldToken.upgradeToAndCall(address(newImplementation), "");

        // Fast forward past the timelock period
        vm.warp(block.timestamp + 3 days + 1);

        // Now the upgrade should succeed
        vm.prank(multisig);
        vm.expectEmit(true, true, false, false);
        emit Upgrade(multisig, address(newImplementation));
        yieldToken.upgradeToAndCall(address(newImplementation), "");

        // Verify version was incremented
        assertEq(yieldToken.version(), 2);

        // Verify the pending upgrade was cleared
        (,, bool exists) = yieldToken.pendingUpgrade();
        assertFalse(exists);
    }

    function testRevert_UpgradeWithoutScheduling() public {
        // Deploy a new implementation
        LendefiYieldToken newImplementation = new LendefiYieldToken();

        // Try to upgrade without scheduling first
        vm.prank(multisig);
        vm.expectRevert(UpgradeNotScheduled.selector);
        yieldToken.upgradeToAndCall(address(newImplementation), "");
    }

    function testRevert_UpgradeWithWrongImplementation() public {
        // Deploy two different implementations
        LendefiYieldToken scheduledImpl = new LendefiYieldToken();
        LendefiYieldToken attemptedImpl = new LendefiYieldToken();

        // Schedule the first implementation
        vm.prank(multisig);
        yieldToken.scheduleUpgrade(address(scheduledImpl));

        // Fast forward past the timelock period
        vm.warp(block.timestamp + 3 days + 1);

        // Try to upgrade with the wrong implementation
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(ImplementationMismatch.selector, address(scheduledImpl), address(attemptedImpl))
        );
        yieldToken.upgradeToAndCall(address(attemptedImpl), "");
    }

    function test_ScheduleNewUpgradeAfterCancellation() public {
        // Deploy implementations
        LendefiYieldToken firstImpl = new LendefiYieldToken();
        LendefiYieldToken secondImpl = new LendefiYieldToken();

        // Schedule first upgrade
        vm.prank(multisig);
        yieldToken.scheduleUpgrade(address(firstImpl));

        // Cancel it
        vm.prank(multisig);
        yieldToken.cancelUpgrade();

        // Schedule a different upgrade
        vm.prank(multisig);
        yieldToken.scheduleUpgrade(address(secondImpl));

        // Verify the new upgrade was scheduled
        (address impl,, bool exists) = yieldToken.pendingUpgrade();
        assertEq(impl, address(secondImpl));
        assertTrue(exists);
    }

    function test_RescheduleUpgrade() public {
        // Deploy implementations
        LendefiYieldToken firstImpl = new LendefiYieldToken();
        LendefiYieldToken secondImpl = new LendefiYieldToken();

        // Schedule first upgrade
        vm.prank(multisig);
        yieldToken.scheduleUpgrade(address(firstImpl));

        // Schedule a new upgrade (implicitly cancels the first one)
        vm.prank(multisig);
        yieldToken.scheduleUpgrade(address(secondImpl));

        // Verify the second upgrade was scheduled
        (address impl,, bool exists) = yieldToken.pendingUpgrade();
        assertEq(impl, address(secondImpl));
        assertTrue(exists);
    }
}
