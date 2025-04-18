// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title LendefiYieldToken (for testing Upgrades)
 * @author alexei@nebula-labs(dot)xyz
 * @notice LP token representing shares in the Lendefi lending protocol's liquidity pool, using 6 decimals to match USDC
 * @dev This contract implements an ERC20 token that represents the lender's share of the Lendefi protocol's
 *      lending pool. It's designed to be controlled exclusively by the main Lendefi protocol.
 *      The token uses 6 decimals to maintain consistency with USDC.
 * @custom:security-contact security@nebula-labs.xyz
 */

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC20PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";

/// @custom:oz-upgrades-from contracts/lender/LendefiYieldToken.sol:LendefiYieldToken
contract LendefiYieldTokenV2 is
    Initializable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    /**
     * @notice Structure to store pending upgrade details
     * @param implementation Address of the new implementation contract
     * @param scheduledTime Timestamp when the upgrade was scheduled
     * @param exists Boolean flag indicating if an upgrade is currently scheduled
     */
    struct UpgradeRequest {
        address implementation;
        uint64 scheduledTime;
        bool exists;
    }
    // ========== CONSTANTS ==========

    /// @notice Role for pausing and unpausing token transfers in emergency situations
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role for the main Lendefi protocol to control token minting and burning
    bytes32 public constant PROTOCOL_ROLE = keccak256("PROTOCOL_ROLE");

    /// @notice Role for authorizing contract upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Duration of the timelock for upgrade operations (3 days)
    /// @dev Provides time for users to review and react to scheduled upgrades
    uint256 public constant UPGRADE_TIMELOCK_DURATION = 3 days;

    // ========== STATE VARIABLES ==========

    /// @notice Current version of the contract, incremented on each upgrade
    uint8 public version;

    /// @notice Information about the currently pending upgrade
    UpgradeRequest public pendingUpgrade;

    /// @dev Reserved storage slots for future upgrades
    uint256[25] private __gap;

    // ========== EVENTS ==========

    /// @notice Emitted when the contract is initialized
    /// @param admin Address of the initial admin
    event Initialized(address indexed admin);

    /// @notice Emitted when the contract is upgraded
    /// @param upgrader Address that triggered the upgrade
    /// @param implementation Address of the new implementation contract
    event Upgrade(address indexed upgrader, address indexed implementation);

    /// @notice Emitted when an upgrade is scheduled
    /// @param scheduler The address scheduling the upgrade
    /// @param implementation The new implementation contract address
    /// @param scheduledTime The timestamp when the upgrade was scheduled
    /// @param effectiveTime The timestamp when the upgrade can be executed
    event UpgradeScheduled(
        address indexed scheduler, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );

    /// @notice Emitted when a scheduled upgrade is cancelled
    /// @param canceller The address that cancelled the upgrade
    /// @param implementation The implementation address that was cancelled
    event UpgradeCancelled(address indexed canceller, address indexed implementation);

    // ========== ERRORS ==========

    /// @notice Thrown when attempting to set a critical address to the zero address
    error ZeroAddressNotAllowed();

    /// @notice Thrown when attempting to execute an upgrade before timelock expires
    /// @param timeRemaining The time remaining until the upgrade can be executed
    error UpgradeTimelockActive(uint256 timeRemaining);

    /// @notice Thrown when attempting to execute an upgrade that wasn't scheduled
    error UpgradeNotScheduled();

    /// @notice Thrown when implementation address doesn't match scheduled upgrade
    /// @param scheduledImpl The address that was scheduled for upgrade
    /// @param attemptedImpl The address that was attempted to be used
    error ImplementationMismatch(address scheduledImpl, address attemptedImpl);

    // ========== CONSTRUCTOR ==========

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ========== EXTERNAL FUNCTIONS ==========

    /**
     * @notice Initializes the token with name, symbol, and key roles
     * @dev Sets up token details and access control roles
     * @param protocol Address of the Lendefi protocol contract (receives PROTOCOL_ROLE)
     * @param timelock Address of the timelock contract (receives DEFAULT_ADMIN_ROLE)
     * @param multisig Address with upgrade capability (receives UPGRADER_ROLE)
     */
    function initialize(address protocol, address timelock, address multisig) external initializer {
        if (protocol == address(0) || timelock == address(0) || multisig == address(0)) {
            revert ZeroAddressNotAllowed();
        }

        __ERC20_init("Lendefi Yield Token", "LYT");
        __ERC20Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(PROTOCOL_ROLE, protocol);
        _grantRole(PAUSER_ROLE, timelock);
        _grantRole(PAUSER_ROLE, multisig);
        _grantRole(UPGRADER_ROLE, timelock);
        _grantRole(UPGRADER_ROLE, multisig);

        // Set initial version
        version = 1;

        emit Initialized(msg.sender);
    }

    /**
     * @notice Mints new tokens to a recipient
     * @dev Only callable by the protocol contract when not paused
     * @param to Address receiving the minted tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyRole(PROTOCOL_ROLE) whenNotPaused nonReentrant {
        _mint(to, amount);
    }

    /**
     * @notice Burns tokens from a holder
     * @dev Only callable by the protocol contract when not paused
     * @param from Address whose tokens are being burned
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external onlyRole(PROTOCOL_ROLE) whenNotPaused nonReentrant {
        _burn(from, amount);
    }

    /**
     * @notice Pauses all token transfers and minting
     * @dev Only callable by addresses with PAUSER_ROLE
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses token transfers and minting
     * @dev Only callable by addresses with PAUSER_ROLE
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Schedules an upgrade to a new implementation with timelock
     * @dev Only callable by addresses with UPGRADER_ROLE
     * @param newImplementation Address of the new implementation contract
     */
    function scheduleUpgrade(address newImplementation) external onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddressNotAllowed();

        uint64 currentTime = uint64(block.timestamp);
        uint64 effectiveTime = currentTime + uint64(UPGRADE_TIMELOCK_DURATION);

        pendingUpgrade = UpgradeRequest({implementation: newImplementation, scheduledTime: currentTime, exists: true});

        emit UpgradeScheduled(msg.sender, newImplementation, currentTime, effectiveTime);
    }

    /**
     * @notice Cancels a previously scheduled upgrade
     * @dev Only callable by addresses with UPGRADER_ROLE
     */
    function cancelUpgrade() external onlyRole(UPGRADER_ROLE) {
        if (!pendingUpgrade.exists) {
            revert UpgradeNotScheduled();
        }
        address implementation = pendingUpgrade.implementation;
        delete pendingUpgrade;
        emit UpgradeCancelled(msg.sender, implementation);
    }

    /**
     * @notice Returns the remaining time before a scheduled upgrade can be executed
     * @dev Returns 0 if no upgrade is scheduled or if the timelock has expired
     * @return timeRemaining The time remaining in seconds
     */
    function upgradeTimelockRemaining() external view returns (uint256) {
        return pendingUpgrade.exists && block.timestamp < pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION
            ? pendingUpgrade.scheduledTime + UPGRADE_TIMELOCK_DURATION - block.timestamp
            : 0;
    }

    // ========== PUBLIC FUNCTIONS ==========

    /**
     * @notice Returns the number of decimals used for token amounts
     * @dev Overrides the default ERC20 implementation to use 6 decimals to match USDC
     * @return The number of decimals (6)
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @notice Override to enforce pause state during transfers
     * @dev Reverts if the contract is paused
     * @param from Address sending tokens
     * @param to Address receiving tokens
     * @param value Token amount
     */
    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        super._update(from, to, value);
    }

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Implements the upgrade verification and authorization logic
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        if (!pendingUpgrade.exists) {
            revert UpgradeNotScheduled();
        }

        if (pendingUpgrade.implementation != newImplementation) {
            revert ImplementationMismatch(pendingUpgrade.implementation, newImplementation);
        }

        uint256 timeElapsed = block.timestamp - pendingUpgrade.scheduledTime;
        if (timeElapsed < UPGRADE_TIMELOCK_DURATION) {
            revert UpgradeTimelockActive(UPGRADE_TIMELOCK_DURATION - timeElapsed);
        }

        // Clear the scheduled upgrade
        delete pendingUpgrade;

        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
